# frozen_string_literal: true

require "test_helper"

# THE SWEEP THAT MAKES A WRITE-AHEAD ROW SURVIVABLE.
#
# ContestsController#finalize saves the Contest row as `pending` BEFORE it
# broadcasts create_contest (PR #551). That inverted the failure mode — a crash
# now leaves a row with no money instead of money with no row — but a row with
# no money is only an improvement if something clears it. Nothing did. This is
# that something, and these are the four verdicts it can reach.
#
# THE ASYMMETRY THAT DRIVES EVERY TEST BELOW: promoting the wrong row costs a
# contest that shows up early. DELETING the wrong row destroys the only Rails
# record of a funded on-chain contest and re-creates, by hand, the exact
# unreachable strand PR #551 removed. So every test here is really asking one
# question — under what evidence is a delete allowed? — and the answer is: an
# on-chain read that positively returned "no account", and nothing else.
class Contests::PendingReconcilerTest < ActiveSupport::TestCase
  setup do
    @slate = slates(:one)
    @creator = User.create!(
      name: "Strand Creator", username: "strand_creator", role: :user,
      email: "strand_creator@mcritchie.studio"
    )
  end

  # FakeVault#contest_pda returns ["cpda-<slug>", 254] and the production code
  # base58-encodes it, so the identity stub below makes the derived value
  # "cpda-<slug>" — the same shape FakeVault's other contest helpers use.
  def with_pda_encoding
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      yield
    end
  end

  def pending_contest(slug:, created_at: 30.minutes.ago, pda: nil, signature: nil, flagged_at: nil)
    Contest.create!(
      name: slug.titleize, slug: slug, slate: @slate, contest_type: "tiny",
      status: :pending, entry_fee_cents: 100, max_entries: 10, user: @creator,
      onchain_contest_id: pda.nil? ? "cpda-#{slug}" : pda,
      onchain_tx_signature: signature,
      onchain_reconcile_flagged_at: flagged_at,
      created_at: created_at
    ).tap { |c| c.update_column(:created_at, created_at) }
  end

  # A vault whose chain HAS the contest account at the derived PDA.
  def vault_with_pda(slug)
    FakeVault.new(account_infos: { "cpda-#{slug}" => { "value" => { "data" => ["", "base64"] } } })
  end

  # A vault whose chain has nothing anywhere — get_account_info returns nil.
  def vault_without_pda
    FakeVault.new(account_infos: {})
  end

  # ───────────────────────────────────────────────────────────────────────────
  # PROMOTE — the PDA exists, so the money moved
  # ───────────────────────────────────────────────────────────────────────────

  test "an aged pending row whose PDA EXISTS is promoted to open" do
    contest = pending_contest(slug: "strand-promoted", signature: "BroadcastSig")

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_with_pda("strand-promoted"))
    end

    assert_equal "open", contest.reload.status
    assert_equal 1, stats[:promoted]
  end

  # The load-bearing distinction from a balance check. turf-vault's
  # create_contest validation #5 accepts `any_fee_set || prize_pool > 0`, so a
  # fee-charging contest with a ZERO prize pool is legal on chain. A reconciler
  # that required a positive pool would DELETE it — destroying the row for a
  # real, funded, entry-taking contest. FakeVault#read_contest returns no
  # prize-pool key at all, which stands in for both "zero pool" and "pool
  # unreadable"; neither may change the verdict.
  test "a PDA that exists is promoted even when no prize pool can be read" do
    contest = pending_contest(slug: "strand-zero-pool")

    with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_with_pda("strand-zero-pool"))
    end

    assert_equal "open", contest.reload.status,
      "existence is the funding proof — create_contest inits the account and transfers " \
      "the pool in ONE atomic instruction, and a zero pool is legal"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # DELETE — no PDA, no signature: nothing ever happened
  # ───────────────────────────────────────────────────────────────────────────

  test "an aged pending row whose PDA is ABSENT is deleted, releasing the slug" do
    pending_contest(slug: "strand-deleted")

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert_nil Contest.find_by(slug: "strand-deleted"),
      "no PDA means no broadcast landed, so the row is pure slug squat"
    assert_equal 1, stats[:deleted]
  end

  test "the deleted row's slug is free for a fresh create" do
    pending_contest(slug: "strand-reusable")

    with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    # The user-visible point of the whole sweep: the retry that was refused with
    # "already exists" can now proceed. `slug` is uniquely indexed, so this save
    # is itself the proof the lockout is gone.
    reused = Contest.new(
      name: "Strand Reusable", slug: "strand-reusable", slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @creator
    )
    reused.skip_onchain_callback = true
    assert reused.save, reused.errors.full_messages.join(", ")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # NEVER DELETE — the cases where absence is not enough
  # ───────────────────────────────────────────────────────────────────────────

  # THE TEST THIS FILE EXISTS FOR. An RPC fault and an empty account both look
  # like "I could not find it", and one of them must never delete. If
  # get_account_info's exception were folded into "absent" — the way
  # Entries::OnchainReconciler folds it, safely, because its consequence is a
  # skip — then a mainnet rate limit would destroy every pending row in one
  # sweep, including funded ones.
  test "an RPC FAULT never deletes — it is not evidence of absence" do
    contest = pending_contest(slug: "strand-rpc-down")
    vault = FakeVault.new(account_info_raises: true)

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault)
    end

    assert Contest.exists?(slug: "strand-rpc-down"), "an unreadable chain must never delete a row"
    assert_equal "pending", contest.reload.status
    assert_nil contest.onchain_reconcile_flagged_at, "a transient fault is not an anomaly to page a human about"
    assert_equal 1, stats[:skipped]
  end

  test "an absent PDA on a row carrying a broadcast signature is FLAGGED, never deleted" do
    contest = pending_contest(slug: "strand-has-sig", signature: "SigThatClaimsItLanded")

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-has-sig")
    assert_equal 1, stats[:flagged]
    assert_not_nil contest.reload.onchain_reconcile_flagged_at
    log = ErrorLog.where(target_type: "Contest", target_id: contest.id).last
    assert_not_nil log, "a flagged strand must be findable by the query an operator runs"
    assert_match(/SigThatClaimsItLanded/, log.message)
  end

  test "a stored PDA that does not match the slug is FLAGGED, never deleted" do
    contest = pending_contest(slug: "strand-mismatch", pda: "cpda-some-other-contest")

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-mismatch"),
      "when the identity is broken, 'absent' describes an address we cannot attribute to this row"
    assert_equal 1, stats[:flagged]
    assert_not_nil contest.reload.onchain_reconcile_flagged_at
  end

  test "a pending row with NO pda at all is flagged rather than guessed about" do
    contest = pending_contest(slug: "strand-no-pda", pda: "")
    contest.update_column(:onchain_contest_id, nil)

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-no-pda")
    assert_equal 1, stats[:flagged]
  end

  # Both associations are `dependent: :destroy`, so a delete would take real
  # rows with it. A pending contest should have neither — which is exactly why
  # having one means a human should look before anything is removed.
  test "an absent PDA on a row with dependent entries is FLAGGED, never deleted" do
    contest = pending_contest(slug: "strand-has-entry")
    Entry.create!(contest: contest, user: @creator, status: :cart)

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-has-entry")
    assert_equal 1, stats[:flagged]
  end

  # landing_pages.contest_id is `on_delete: :nullify`, so a delete here would NOT
  # fail — it would quietly leave the landing page pointing at nothing. That
  # quietness is the reason to check it: an admin can attach one to a pending
  # contest today (Admin::LandingPagesController#load_contests lists every
  # status), and an automatic delete should not silently undo that.
  test "an absent PDA on a row with a landing page is FLAGGED, never deleted" do
    contest = pending_contest(slug: "strand-has-landing")
    LandingPage.create!(name: "Strand Funnel", slug: "strand-funnel", contest: contest)

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-has-landing")
    assert_equal 1, stats[:flagged]
    log = ErrorLog.where(target_type: "Contest", target_id: contest.id).last
    assert_match(/1 landing pages/, log.message, "the alert must name what would have been orphaned")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE AGE GATE — an in-flight finalize is not a strand
  # ───────────────────────────────────────────────────────────────────────────

  # A finalize sitting between its write-ahead save and its promote is
  # indistinguishable by inspection from a strand. Deleting a live one would
  # make the running request broadcast against a row that no longer exists —
  # precisely the failure PR #551 removed.
  test "a row younger than the threshold is left completely alone" do
    contest = pending_contest(slug: "strand-in-flight", created_at: 30.seconds.ago)

    stats = with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(slug: "strand-in-flight")
    assert_equal "pending", contest.reload.status
    assert_equal 0, stats.values.sum, "a young row must not even be examined"
  end

  # The age gate is re-checked inside #reconcile, not only in the sweep scope,
  # so calling the service directly on one contest cannot bypass it.
  test "reconciling a young row DIRECTLY still refuses" do
    contest = pending_contest(slug: "strand-direct-young", created_at: 10.seconds.ago)

    result = with_pda_encoding { Contests::PendingReconciler.reconcile(contest, vault: vault_without_pda) }

    assert_equal :skipped, result
    assert Contest.exists?(slug: "strand-direct-young")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # SCOPE + IDEMPOTENCY
  # ───────────────────────────────────────────────────────────────────────────

  test "open and settled contests are never touched" do
    open_contest = contests(:one)
    open_status = open_contest.status

    with_pda_encoding do
      Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
    end

    assert Contest.exists?(open_contest.id)
    assert_equal open_status, open_contest.reload.status
  end

  # Without this the flagged row re-files an identical ErrorLog every 15 minutes
  # until the alert that matters is buried in its own repeats.
  test "an already-flagged row is skipped and does not re-alert" do
    contest = pending_contest(slug: "strand-already-flagged", signature: "Sig", flagged_at: 1.hour.ago)
    # Read the stored value rather than recomputing `1.hour.ago` at assert time —
    # the two differ by however long the sweep took.
    stamped_at = contest.reload.onchain_reconcile_flagged_at

    assert_no_difference -> { ErrorLog.count } do
      with_pda_encoding do
        Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault_without_pda)
      end
    end

    assert Contest.exists?(slug: "strand-already-flagged")
    assert_equal stamped_at.to_i, contest.reload.onchain_reconcile_flagged_at.to_i,
      "an already-flagged row must not be re-stamped"
  end

  test "a second sweep after a promote is a no-op" do
    pending_contest(slug: "strand-twice")
    vault = vault_with_pda("strand-twice")

    with_pda_encoding { Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault) }
    stats = with_pda_encoding { Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault) }

    assert_equal 0, stats.values.sum
    assert_equal "open", Contest.find_by(slug: "strand-twice").status
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE GUARDRAIL — read-only on chain
  # ───────────────────────────────────────────────────────────────────────────

  test "the sweep never signs, broadcasts, or transfers" do
    pending_contest(slug: "strand-readonly-a")
    pending_contest(slug: "strand-readonly-b", signature: "Sig")
    vault = vault_with_pda("strand-readonly-a")

    with_pda_encoding { Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault) }

    assert_empty vault.create_cosign_broadcast_calls, "the reconciler must never broadcast create_contest"
    assert_empty vault.transfer_calls, "the reconciler must never move money"
    assert_empty vault.mint_calls, "the reconciler must never mint"
    assert_empty vault.client.sent_transactions, "the reconciler must never send a transaction"
  end

  # A fault inside one contest must not abort the sweep or escape unlogged.
  test "a fault on one row is logged and the sweep continues" do
    pending_contest(slug: "strand-faulty")
    pending_contest(slug: "strand-healthy")

    # Raise from the PDA derivation for exactly one slug — a fault INSIDE
    # #reconcile, which is where the per-row rescue has to hold.
    vault = Class.new(FakeVault) do
      def contest_pda(contest_slug)
        raise StandardError, "simulated derivation fault" if contest_slug == "strand-faulty"

        super
      end
    end.new(account_infos: { "cpda-strand-healthy" => { "value" => { "data" => ["", "base64"] } } })

    stats = with_pda_encoding { Contests::PendingReconciler.run(older_than: 10.minutes, vault: vault) }

    assert_equal 1, stats[:error]
    assert_equal "open", Contest.find_by(slug: "strand-healthy").status,
      "the sweep must not abort on one bad row"
    faulty = Contest.find_by(slug: "strand-faulty")
    assert_not_nil faulty, "a row that errored must be left for the next sweep, not deleted"
    assert ErrorLog.where(target_type: "Contest", target_id: faulty.id).exists?,
      "a swallowed fault must still be findable against the row it happened on"
  end
end
