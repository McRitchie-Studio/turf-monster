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
  #
  # THIS TEST IS ONLY HONEST BECAUSE OF THE VIEW TEST BELOW IT. On its own,
  # patching `name` with no starts_at proves nothing about the real screen — the
  # form used to ALWAYS submit contest[starts_at], so the interesting request was
  # the one this test was not sending. The view test pins that the on-chain edit
  # page really does omit the field, which is what makes this params shape the
  # one an operator's browser actually produces.
  test "editing a verified contest's name is still allowed" do
    verified = onchain_contest("Strand Renameable", "strand-renameable")

    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(verified), params: { contest: { name: "Strand Renamed" } }
    end

    assert_equal "Strand Renamed", verified.reload.name,
      "the lock-time guard must not swallow an unrelated edit"
    assert_empty vault.set_lock_time_calls
  end

  # THE SOURCE OF THE RENAME BUG, pinned where it actually lived.
  #
  # The contestLockPicker factory (shared/_alpine_factories) has a sync() that
  # writes `toISOString().substring(0, 16)` — no
  # seconds — and init() writes it on PAGE LOAD with no operator input. While the
  # edit form emitted contest[starts_at], opening this page on a contest locked
  # at 12:34:56 by confirm_lock_time (or the QA driver) and saving a NEW NAME
  # resubmitted 12:34:00. #update read the 56-second difference as a lock move
  # and refused — defeating the very flow this change steers operators toward.
  #
  # Fixed at the source rather than by loosening the comparison to whole
  # minutes, which would have handed back 59 seconds of lock movement that no
  # Phantom ever signed. The field is simply not rendered for an on-chain
  # contest, so the form cannot express a lock move on one.
  test "the edit form does not submit a lock time for an on-chain contest" do
    verified = onchain_contest("Strand Onchain Form", "strand-onchain-form")
    verified.update!(starts_at: Time.at(Time.current.to_i).change(sec: 37))

    log_in_as(@admin)
    get edit_contest_path(verified)

    assert_response :success
    assert_select "input[name=?]", "contest[starts_at]", false,
      "an on-chain contest's lock must not ride the form — the picker truncates seconds " \
      "and writes on load, so any hidden field here resubmits a lock move on a plain rename"
    assert_select "input[name=?]", "contest[locks_at_time_selected]", false
  end

  # THE CONTROL for the view test above. An off-chain contest has no chain row to
  # disagree with, so saving starts_at IS its whole lock and the field must stay.
  # Without this, deleting the field unconditionally would also pass.
  test "the edit form still submits a lock time for an off-chain contest" do
    offchain = Contest.new(
      name: "Strand Offchain Form", slug: "strand-offchain-form", slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin
    )
    offchain.skip_onchain_callback = true
    offchain.save!
    assert_not offchain.onchain_verified?, "premise: this contest is not on chain"

    log_in_as(@admin)
    get edit_contest_path(offchain)

    assert_response :success
    assert_select "input[name=?]", "contest[starts_at]", true,
      "the off-chain lock still travels with the form"
  end

  # RESUBMITTING THE PERSISTED VALUE IS NOT A MOVE. A stale tab or a direct API
  # call that echoes the stored timestamp back must not 422 — the guard refuses
  # a CHANGE of deadline, not the mention of one.
  test "re-submitting a verified contest's existing start time is not a lock move" do
    verified = onchain_contest("Strand Echo", "strand-echo")
    verified.update!(starts_at: Time.at(Time.current.to_i + 3600))
    original = verified.reload.starts_at

    log_in_as(@admin)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      patch contest_path(verified),
        params: { contest: { name: "Strand Echoed", starts_at: original.iso8601 } }
    end

    assert_equal "Strand Echoed", verified.reload.name,
      "echoing the stored deadline back is not a move and must not block the edit"
    assert_equal original.to_i, verified.starts_at.to_i
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

  private

  def onchain_contest(name, slug)
    contest = Contest.new(
      name: name, slug: slug, slate: @slate, contest_type: "tiny",
      status: :open, entry_fee_cents: 100, max_entries: 10, user: @admin,
      onchain_contest_id: "cpda-#{slug}"
    )
    contest.skip_onchain_callback = true
    contest.save!
    contest
  end
end
