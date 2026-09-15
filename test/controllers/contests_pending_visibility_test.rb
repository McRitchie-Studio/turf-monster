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
  #
  # THE GUARD STILL TURNS ON Contest#onchain_verified?, but since
  # route-time-changes-to-phantom it decides something else: not "broadcast or
  # stay quiet" but "save or refuse". A pending row has no initialized PDA and
  # therefore no on-chain lock to contradict, so its start time stays editable
  # here — which is what this test pins.
  test "editing a pending contest's start time is allowed and broadcasts nothing" do
    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(@pending), params: { contest: { starts_at: 2.days.from_now } }
    end

    # THE PERSIST IS THE LOAD-BEARING ASSERTION, and it is the one the verified
    # test below contradicts. The empty call list no longer distinguishes
    # anything on its own — no controller path signs a lock any more — so it is
    # kept only as a regression pin against wiring the server key back in.
    assert_equal 2.days.from_now.to_date, @pending.reload.starts_at.to_date,
      "an unverified row must stay editable, or this test proves nothing"
    assert_empty vault.set_lock_time_calls,
      "a pending row's PDA does not exist — this instruction would fail with AccountNotInitialized"
  end

  # THE CONTROL, INVERTED BY route-time-changes-to-phantom. Same edit, same code
  # path, on a VERIFIED contest. It used to assert the broadcast HAPPENED; the
  # server key no longer signs a lock change at all, so the verified side now
  # asserts the REFUSAL. Something must still differ between the two contests or
  # the test above is satisfied by code with no guard whatsoever — this is that
  # difference, and it is why this test was rewritten rather than deleted.
  test "editing a verified contest's start time is refused, not broadcast" do
    verified = Contest.new(
      name: "Strand Verified", slug: "strand-verified", slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin,
      onchain_contest_id: "cpda-strand-verified"
    )
    verified.skip_onchain_callback = true
    verified.save!
    original = verified.starts_at

    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(verified), params: { contest: { starts_at: 2.days.from_now } }
    end

    assert_response :unprocessable_entity
    assert_equal original.to_i, verified.reload.starts_at.to_i,
      "refusing AFTER the save would strand the DB ahead of the chain"
    assert_empty vault.set_lock_time_calls,
      "the admin key must not sign a lock-time change — that authority moved to Phantom"
  end

  # A verified contest is not frozen: only its LOCK TIME left this screen. An
  # edit that moves no deadline still saves, which is what keeps the refusal
  # above a routing rule rather than a read-only page.
  test "editing a verified contest's name is still allowed" do
    verified = Contest.new(
      name: "Strand Renameable", slug: "strand-renameable", slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin,
      onchain_contest_id: "cpda-strand-renameable"
    )
    verified.skip_onchain_callback = true
    verified.save!

    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(verified), params: { contest: { name: "Strand Renamed" } }
    end

    assert_equal "Strand Renamed", verified.reload.name,
      "the lock-time guard must not swallow an unrelated edit"
    assert_empty vault.set_lock_time_calls
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
