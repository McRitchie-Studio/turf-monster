require "test_helper"

# Entries::OnchainReconciler heals on-chain-paid entries that were stranded in
# `cart` by a post-broadcast Entry#confirm! failure (incident 2026-06-08,
# entry #133). FakeVault is shared — see test/support/fake_vault.rb.
class Entries::OnchainReconcilerTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one) # paid ($19), open, standard
    # On-chain + a configured season + a FUTURE lock time (not locked).
    @contest.update!(onchain_contest_id: "onchain-reconcile", season_id: 1, starts_at: 1.day.from_now)
    SeasonConfig.set_current!(1)

    @user = users(:sam)
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedReconcile#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )

    @matchups = %i[m1 m2 m3 m4 m5 m6].map { |k| slate_matchups(k) }
  end

  def cart_entry_with_picks(**attrs)
    entry = @contest.entries.create!(user: @user, status: :cart, **attrs)
    @matchups.each { |m| entry.selections.create!(slate_matchup: m) }
    entry
  end

  # Build the strand ContestsController#confirm_onchain_entry leaves when the
  # broadcast lands and verify_and_confirm_onchain_entry! then raises: the
  # signature is stamped on the PendingTransaction, NEVER on the entry.
  def broadcast_pending_transaction(entry, signature: "ptx-broadcast-sig-#{SecureRandom.hex(4)}")
    PendingTransaction.create!(
      target: entry,
      tx_type: "enter_contest",
      serialized_tx: "wire",
      status: "submitted",
      tx_signature: signature,
      initiator_address: entry.user.solana_address
    )
  end

  # Abandon it the way the app does. clear_picks is the ONLY writer of
  # `abandoned` and it only ever finds a `cart` row, so going through
  # Entry#update! here reproduces the real transition — including
  # release_slot_if_abandoned, which nulls entry_number because the SIGNATURE IS
  # NOT ON THE ENTRY. Asserted rather than assumed: the null is what sends the
  # row down the all-slots probe, so a future change that kept the number would
  # silently retarget every test below onto the single-slot path.
  def abandon!(entry)
    entry.update!(status: :abandoned)
    entry.reload
    assert entry.abandoned?
    assert_nil entry.entry_number,
               "the strand's signature lives on the PendingTransaction, so abandoning must release the slot"
    entry
  end

  # FAST path: the durable-capture write already stamped the consume signature
  # on the cart entry. The reconciler just re-runs confirm! — no RPC needed.
  test "reconciles a cart entry that already carries a consume signature" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-fast",
      onchain_entry_id: "epda-fast",
      entry_number: 0
    )

    outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)

    assert_equal :reconciled, outcome
    assert entry.reload.active?, "entry should converge to active"
    assert_equal "consume-sig-fast", entry.onchain_tx_signature, "the consume proof must be preserved (token not lost)"
  end

  # Idempotency: re-running must never double-enter or double-charge.
  test "is idempotent — a second run is a no-op once the entry is active" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-idem",
      onchain_entry_id: "epda-idem",
      entry_number: 0
    )

    assert_equal :reconciled, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    fee_logs_after_first = TransactionLog.where(source: @contest, transaction_type: "entry_fee").count

    # Re-run: already active → skipped, no new fee log, still exactly one entry.
    assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    assert entry.reload.active?
    assert_equal fee_logs_after_first,
                 TransactionLog.where(source: @contest, transaction_type: "entry_fee").count,
                 "re-running must not double-charge"
    assert_equal 1, @contest.entries.where(user: @user, status: [:active, :complete]).count
  end

  # PROBE path: a LEGACY strand (e.g. #133) has no proof on the Rails row. The
  # reconciler derives the Entry PDA, confirms it exists on-chain, and recovers
  # the consume signature from getSignaturesForAddress.
  test "probes the chain for the Entry PDA + recovers the consume signature when the row has no proof" do
    entry = cart_entry_with_picks(entry_number: nil)

    wallet = @user.solana_address
    # FakeVault#entry_pda returns ["epda-<slug>-<wallet[0,4]>-<n>", 255]; with
    # encode_base58 stubbed to identity the b58 PDA IS that string.
    pda0 = "epda-#{@contest.slug}-#{wallet[0, 4]}-0"
    vault = FakeVault.new(
      account_infos: { pda0 => { "value" => { "owner" => "prog" } } },
      signatures:    { pda0 => [{ "signature" => "recovered-consume-sig", "err" => nil }] }
    )

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :reconciled, outcome
    entry.reload
    assert entry.active?
    assert_equal "recovered-consume-sig", entry.onchain_tx_signature
    assert_equal pda0, entry.onchain_entry_id
  end

  # N1 (PR #115 review): a heal failure must record an ErrorLog that names WHICH
  # entry/contest failed to converge — not a context-free backtrace.
  test "a heal failure records an ErrorLog with entry + contest context" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-err",
      onchain_entry_id: "epda-err",
      entry_number: 0
    )

    outcome = nil
    entry.stub :confirm!, ->(*, **) { raise StandardError, "simulated heal failure" } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    end

    assert_equal :error, outcome
    log = ErrorLog.where(target: entry).order(:id).last
    assert log, "a heal failure must create an ErrorLog"
    assert_equal entry.slug, log.target_name
    assert_equal @contest, log.parent
    assert_equal @contest.slug, log.parent_name
    assert_match "simulated heal failure", log.message
  end

  test "skips an entry that is already active" do
    entry = cart_entry_with_picks(onchain_tx_signature: "sig-x", entry_number: 0)
    entry.update!(status: :active)

    assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
  end

  test "skips when no on-chain Entry PDA exists for the wallet" do
    entry = cart_entry_with_picks(entry_number: nil)

    # FakeVault with empty account_infos → every probed PDA reads absent.
    vault = FakeVault.new
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end
    assert entry.reload.cart?
  end

  test "never credits a probed signature already bound to another entry" do
    wallet = @user.solana_address
    pda0 = "epda-#{@contest.slug}-#{wallet[0, 4]}-0"

    # An already-healed active entry owns the consume signature (onchain_entry_id
    # left nil so the per-slot claim check can't catch it — exercises the
    # signature-uniqueness backstop specifically).
    existing = cart_entry_with_picks(onchain_tx_signature: "dup-consume-sig", entry_number: 0)
    existing.update!(status: :active)

    # A stray cart entry with no proof on the row that would probe the SAME PDA.
    stray = cart_entry_with_picks(entry_number: nil)

    vault = FakeVault.new(
      account_infos: { pda0 => { "value" => { "owner" => "prog" } } },
      signatures:    { pda0 => [{ "signature" => "dup-consume-sig", "err" => nil }] }
    )

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(stray, vault: vault)
    end

    assert_equal :skipped, outcome
    assert stray.reload.cart?, "must not credit a signature already bound to another entry"
  end

  # --- Abandoned strands ------------------------------------------------
  #
  # PR 530 made QaRehearsal::EntryFlow clear the cart at the START of every run,
  # so the operator's next re-run abandons whatever the last one stranded. The
  # row is still paid on-chain; only its status moved. These pin that an
  # abandoned row is reachable ON PROOF and unreachable without it.

  # Set up the exact post-PR-530 shape: broadcast landed (signature on the
  # PendingTransaction, not the entry), verification raised, the re-run cleared.
  def abandoned_strand(signature: "abandoned-strand-sig")
    entry = cart_entry_with_picks(entry_number: 0)
    broadcast_pending_transaction(entry, signature: signature)
    abandon!(entry)
  end

  def probing_vault(pda:, signature:)
    FakeVault.new(
      account_infos: { pda => { "value" => { "owner" => "prog" } } },
      signatures:    { pda => [{ "signature" => signature, "err" => nil }] }
    )
  end

  def wallet_pda(slot)
    "epda-#{@contest.slug}-#{@user.solana_address[0, 4]}-#{slot}"
  end

  test "reconciles an abandoned strand whose PendingTransaction carries a broadcast signature" do
    entry = abandoned_strand
    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "recovered-abandoned-sig")

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :reconciled, outcome
    entry.reload
    assert entry.active?, "an abandoned strand with broadcast proof must converge to active"
    # Credited from the CHAIN, not from the PendingTransaction. The PT signature
    # only bought the row a look; had the service credited it directly this would
    # read "abandoned-strand-sig".
    assert_equal "recovered-abandoned-sig", entry.onchain_tx_signature
    assert_equal pda0, entry.onchain_entry_id
  end

  # THE GUARD THAT MAKES THE WIDENING SAFE. clear_picks abandons a row every time
  # anyone changes their mind. Promoting those would enter people who asked not
  # to be entered — so the status alone must never be enough, even when the chain
  # would happily hand back a PDA and a signature.
  test "skips an abandoned entry with no PendingTransaction, even when the chain offers a PDA" do
    entry = cart_entry_with_picks(entry_number: 0)
    abandon!(entry)
    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "should-never-be-credited")

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :skipped, outcome
    entry.reload
    assert entry.abandoned?, "an ordinary cleared cart must stay abandoned"
    assert_nil entry.onchain_tx_signature
  end

  # It is the SIGNATURE that admits the row, not the PendingTransaction's
  # existence. prepare_entry writes an unsigned PT before any broadcast, so every
  # cleared cart that ever reached the Phantom prompt has one.
  test "skips an abandoned entry whose PendingTransaction was never broadcast" do
    entry = cart_entry_with_picks(entry_number: 0)
    PendingTransaction.create!(target: entry, tx_type: "enter_contest", serialized_tx: "wire",
                               status: "pending", tx_signature: nil,
                               initiator_address: @user.solana_address)
    abandon!(entry)
    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "should-never-be-credited")

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :skipped, outcome
    assert entry.reload.abandoned?
  end

  # THE CEILING, PINNED. Healing runs through Entry#confirm! → assert_enterable!,
  # whose first gate is "Contest is not open". So a strand survives only while the
  # contest does — the rehearsal's Step 4 locks and settles it — and this is the
  # property the clear_cart comment in QaRehearsal::EntryFlow tells operators
  # about. Reaching the row and converging it are different things.
  test "does not converge an abandoned strand once the contest is no longer open" do
    entry = abandoned_strand(signature: "settled-strand-sig")
    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "recovered-settled-sig")
    @contest.update!(status: :settled)

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :error, outcome
    assert entry.reload.abandoned?, "a settled contest's strand must not be activated"
    log = ErrorLog.where(target: entry).order(:id).last
    assert log, "an unconvergeable strand must leave an ErrorLog — there is money on-chain for it"
    assert_match "Contest is not open", log.message
  end

  # The comment in QaRehearsal::EntryFlow#clear_cart tells the operator to run the
  # reconcile by hand because nothing schedules it. That is a claim about
  # config/schedule.yml, so pin it here: scheduling the job later turns this red
  # and sends the next agent to the paragraph that would have gone stale.
  test "no cron entry schedules the entry reconciler" do
    schedule = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))
    classes = schedule.values.map { |config| config["class"] }

    assert_not_includes classes, "Entries::OnchainReconcileJob",
                        "config/schedule.yml now schedules the entry reconciler — update the " \
                        "clear_cart comment in lib/turf_monster/qa_rehearsal/entry_flow.rb, " \
                        "which tells operators to run it by hand."
  end

  # --- The MANAGED-wallet abandoned strand ------------------------------
  #
  # The other abandoned shape, and the one the PendingTransaction admission test
  # could not see. ContestsController#enter (web2 / managed wallet, server-signed)
  # stamps the consume signature + Entry PDA on the still-`cart` ENTRY and writes
  # NO PendingTransaction at all — those are the Phantom path only (prepare_entry).
  # A post-broadcast confirm! failure strands it as `cart` + signature; clear_picks
  # then abandons it with no signature guard, and release_slot_if_abandoned SPARES
  # the slot precisely because the signature is on the entry.
  #
  # So the row carries the STRONGEST proof available — the consume signature
  # itself — and would take the FAST path, yet a PendingTransaction-only admission
  # test refused it. Managed wallets are the default onboarding population
  # (#enter refuses onchain_session? / self_custodied? users), so this is a
  # production money path, not a rehearsal artifact.

  # Build that exact shape, and ASSERT the two facts that define it — the absent
  # PendingTransaction and the spared slot. Asserted, not assumed: a fixture that
  # quietly grew a PendingTransaction would be testing the Phantom path and would
  # pass against the unfixed service, and a fixture whose slot got released would
  # be exercising the all-slots probe instead of the fast path.
  def managed_abandoned_strand(signature: "managed-consume-sig", pda: "epda-managed")
    entry = cart_entry_with_picks(
      onchain_tx_signature: signature,
      onchain_entry_id: pda,
      entry_number: 0
    )
    entry.update!(status: :abandoned)
    entry.reload

    assert entry.abandoned?
    assert_equal 0, PendingTransaction.where(target: entry).count,
                 "the managed path writes NO PendingTransaction — creating one here would " \
                 "install the very precondition this shape is defined by lacking"
    assert_equal 0, entry.entry_number,
                 "the signature is on the ENTRY, so release_slot_if_abandoned must SPARE the slot"
    assert_equal signature, entry.onchain_tx_signature
    entry
  end

  # [unit] The single-entry admission test.
  test "reconciles an abandoned managed-wallet strand carrying the consume signature on the entry" do
    entry = managed_abandoned_strand

    # FakeVault with no account_infos: every probe reads absent. If the service
    # ever fell back to probing instead of crediting the stored proof, this is
    # the vault that would make it skip — so passing proves the FAST path ran.
    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    end

    assert_equal :reconciled, outcome
    entry.reload
    assert entry.active?, "a managed strand with the consume signature on the row must converge to active"
    assert_equal "managed-consume-sig", entry.onchain_tx_signature, "the consume proof must be preserved"
    assert_equal "epda-managed", entry.onchain_entry_id
  end

  # The signature is the proof, and it is the ONLY proof. A comped
  # EnterContestWithToken stamps onchain_entry_id and moves no USDC, so a PDA on
  # the row says an Entry account exists — never that anybody paid for it.
  test "an abandoned entry carrying only an onchain_entry_id is still refused" do
    entry = cart_entry_with_picks(onchain_entry_id: "epda-comped-no-payment", entry_number: 0)
    abandon!(entry)

    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "should-never-be-credited")

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :skipped, outcome
    assert entry.reload.abandoned?, "a PDA is not proof of payment — only the consume signature is"
    assert_nil entry.onchain_tx_signature
  end

  # The rake desc is what an operator reads BEFORE running a sweep over money, so
  # it has to name the candidate set truthfully. It said "cart entries" and stayed
  # that way through PR 560's abandoned widening — stale prose about which rows a
  # money job touches, which is how this guard earned its place.
  test "the reconcile rake desc names the widened candidate set" do
    rake = Rails.root.join("lib/tasks/entries.rake").read
    desc = rake[/desc\s+(.+?)\n\s*task :reconcile_onchain/m]
    assert desc, "could not find the desc for entries:reconcile_onchain — did the task move or get renamed?"

    assert_match(/cart/i, desc, "the desc must still name the cart rows")
    assert_match(/abandoned/i, desc,
                 "the desc must name the abandoned rows this sweep also touches")
    assert_match(/signature/i, desc,
                 "the desc must say what admits an abandoned row: proof of a broadcast, not the status")
  end

  # --- Sweep ------------------------------------------------------------

  # [integration] run(contest:) is the operator's documented door
  # (`bin/rails entries:reconcile_onchain[<slug>]`), and it must see the abandoned
  # strand too — widening reconcile_entry alone would leave the sweep's candidate
  # query walking `cart` rows only and reporting a clean zero over live strands.
  test "the sweep picks up an abandoned strand alongside cart entries" do
    strand = abandoned_strand(signature: "sweep-strand-sig")
    ordinary = cart_entry_with_picks(entry_number: 1)
    abandon!(ordinary)

    pda0 = wallet_pda(0)
    vault = probing_vault(pda: pda0, signature: "sweep-recovered-sig")

    stats = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      stats = Entries::OnchainReconciler.run(contest: @contest, vault: vault)
    end

    assert_equal 1, stats[:reconciled], "the sweep must heal the broadcast-proven strand"
    assert strand.reload.active?
    assert ordinary.reload.abandoned?, "the sweep must leave an unproven abandoned row alone"
  end

  # [integration] The sweep's candidate QUERY is a second, independent admission
  # test — `reconcilable_entries` never calls `#reconcilable?`, it re-states the
  # rule in SQL. So widening the guard alone leaves `bin/rails
  # entries:reconcile_onchain` walking a candidate set that never contains this
  # row and printing `reconciled=0` over a live, paid-for strand. That silent
  # clean zero over money is the failure this test exists to prevent.
  #
  # Driven through run(contest:) — the operator's documented door — with a vault
  # that resolves NOTHING, so the only way a heal can happen is the stored
  # signature taken off the row the query returned.
  test "the sweep query admits the managed abandoned strand with no PendingTransaction" do
    strand = managed_abandoned_strand(signature: "sweep-managed-sig", pda: "epda-sweep-managed")
    cleared = cart_entry_with_picks(entry_number: 1)
    abandon!(cleared)

    assert_equal 0, PendingTransaction.count,
                 "no PendingTransaction may exist in this sweep — the query must reach the row on its own signature"

    stats = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      stats = Entries::OnchainReconciler.run(contest: @contest, vault: FakeVault.new)
    end

    assert_equal 1, stats[:reconciled],
                 "the sweep must reach the managed strand — a clean zero here is money left uncredited"
    assert strand.reload.active?
    assert_equal "sweep-managed-sig", strand.onchain_tx_signature
    assert cleared.reload.abandoned?, "the sweep must still leave an ordinary cleared cart alone"
  end
end
