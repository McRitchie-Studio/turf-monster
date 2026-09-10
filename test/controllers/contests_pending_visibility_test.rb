# frozen_string_literal: true

require "test_helper"

# WHAT A `pending` CONTEST IS ALLOWED TO REACH.
#
# The write-ahead reordering (PR #551) made `pending` a routine state on the
# PRIMARY contest-creation path rather than a theoretical one: every Phantom
# create passes through it, and a crash leaves one behind. `pending` is not a
# draft — it means "this contest's create_contest broadcast has not been
# verified", and the row may name a PDA that was never initialized.
#
# That matters because `pending` was ALREADY the contests table's column default
# (db/migrate/20260524000009_create_contests.rb) long before #551, so the risk is
# not that the value is new — it is that rows now sit in it, unattended, at a
# guessable URL, for as long as it takes a sweep to clear them. This file pins
# the two consequences: a pending contest is not served to players, and nothing
# aims an on-chain instruction at its unverified PDA.
class ContestsPendingVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @slate = slates(:one)
    @admin = users(:alex)
    @player = users(:jordan)
    @pending = Contest.new(
      name: "Strand Visible", slug: "strand-visible", slate: @slate, contest_type: "tiny",
      status: :pending, entry_fee_cents: 100, max_entries: 10, user: @admin,
      onchain_contest_id: "cpda-strand-visible"
    )
    @pending.skip_onchain_callback = true
    @pending.save!
  end

  # ───────────────────────────────────────────────────────────────────────────
  # VISIBILITY — set_contest is the choke point, so this is where it is proved
  # ───────────────────────────────────────────────────────────────────────────

  # #show skips authentication entirely, so this is the fully public case: a
  # signed-out visitor with the slug (which is derived from the contest name,
  # and therefore guessable).
  test "a signed-out visitor cannot open a pending contest" do
    get contest_path(@pending)

    assert_response :redirect
  end

  test "a signed-in player cannot open a pending contest" do
    log_in_as(@player)

    get contest_path(@pending)

    assert_response :redirect
  end

  # The counterpart, and the reason this is a visibility rule and not an
  # existence rule: a stranded row is precisely what an operator has to open in
  # order to repair it, and Contests::PendingReconciler deliberately leaves its
  # unresolvable rows for a human.
  test "an admin CAN still open a pending contest, because repairing one requires seeing it" do
    log_in_as(@admin)

    get contest_path(@pending)

    assert_response :success
  end

  test "an open contest is unaffected for every viewer" do
    get contest_path(contests(:one))
    assert_response :success

    log_in_as(@player)
    get contest_path(contests(:one))
    assert_response :success
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE CHAIN WRITE — Contest#onchain_verified?, not Contest#onchain?
  # ───────────────────────────────────────────────────────────────────────────

  # Editing a stranded contest's lock time used to broadcast set_contest_lock_time
  # against a PDA that was never initialized, because the guard asked `onchain?`
  # — true the instant #finalize stamps the derived PDA on the write-ahead row —
  # and never asked whether the create had been verified.
  test "editing a pending contest's start time does NOT broadcast a lock-time instruction" do
    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(@pending), params: { contest: { starts_at: 2.days.from_now } }
    end

    # PROVE THE INPUT REACHED THE GUARD. An empty call list also describes an
    # update that never happened at all (a validation refusal, a redirect), in
    # which case this test would pass against unguarded code. Assert the DB edit
    # landed, so the only remaining explanation for the silence is the guard.
    assert_equal 2.days.from_now.to_date, @pending.reload.starts_at.to_date,
      "the starts_at edit must actually persist, or this test proves nothing"
    assert_empty vault.set_lock_time_calls,
      "a pending row's PDA does not exist — this instruction would fail with AccountNotInitialized"
  end

  # The control. Same edit, same code path, on a VERIFIED contest: the broadcast
  # must still happen, or the guard above would be indistinguishable from having
  # broken the feature.
  test "editing a verified contest's start time DOES broadcast a lock-time instruction" do
    verified = Contest.new(
      name: "Strand Verified", slug: "strand-verified", slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin,
      onchain_contest_id: "cpda-strand-verified"
    )
    verified.skip_onchain_callback = true
    verified.save!

    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(verified), params: { contest: { starts_at: 2.days.from_now } }
    end

    assert_equal 1, vault.set_lock_time_calls.size
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE PREDICATE ITSELF
  # ───────────────────────────────────────────────────────────────────────────

  test "onchain_verified? separates a stamped PDA from a verified one" do
    assert @pending.onchain?, "the write-ahead row carries a derived PDA, so `onchain?` is true"
    assert_not @pending.onchain_verified?, "but nothing has verified that the PDA was ever created"

    @pending.update!(status: :open)
    assert @pending.onchain_verified?
  end

  # `onchain?` must keep its old meaning: it is one of the three guards against
  # the after_create server-funded callback firing a SECOND create_contest paid
  # from the house wallet. Narrowing it would trade a double spend for a loud,
  # money-free, admin-only failure.
  test "onchain? still answers true for a pending row, which is what the double-spend guard needs" do
    assert @pending.onchain?
    assert @pending.skip_onchain_callback_active?,
      "the callback guard must still refuse to re-broadcast for a row that already names a PDA"
  end
end
