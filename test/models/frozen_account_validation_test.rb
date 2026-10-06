require "test_helper"

# OPSEC-048 where a write LANDS (FrozenAccount::Validation). The controllers
# refuse first; this is the floor under a path that never passes one. Each case
# runs twice: frozen it is refused, and the identical write for the same user
# unfrozen goes through — the control that shows the freeze, not some other
# validation, is what refuses.
class FrozenAccountValidationTest < ActiveSupport::TestCase
  setup do
    @user    = users(:jordan)
    @contest = contests(:one)
  end

  def freeze!(user = @user)
    user.freeze!(reason: "test", source: "console")
    user.reload
  end

  def assert_frozen_refusal(record)
    assert_not record.valid?(record.new_record? ? :create : :update), "a frozen account's write must be refused"
    assert_includes record.errors[:base], FrozenAccount::MESSAGE
  end

  def assert_no_frozen_refusal(record)
    record.valid?(record.new_record? ? :create : :update)
    assert_not_includes record.errors[:base], FrozenAccount::MESSAGE
  end

  # ── Entry ────────────────────────────────────────────────────────────────

  test "an entry cannot be started by a frozen account" do
    entry = Entry.new(user: @user, contest: @contest, status: :cart)
    assert_no_frozen_refusal entry

    freeze!
    entry = Entry.new(user: @user, contest: @contest, status: :cart)
    assert_frozen_refusal entry
    assert_raises(ActiveRecord::RecordInvalid) { entry.save! }
  end

  test "a frozen account's cart cannot be made live, and its other updates still save" do
    entry = Entry.create!(user: users(:sam), contest: @contest, status: :cart)
    freeze!(users(:sam))
    entry.reload

    entry.status = :active
    assert_frozen_refusal entry

    entry.status = :abandoned
    assert_no_frozen_refusal entry
  end

  # ── Selection (a pick: the cart and edit_entry) ──────────────────────────

  test "no new pick lands on a frozen account's entry" do
    entry = Entry.create!(user: users(:sam), contest: @contest, status: :cart)
    pick = entry.selections.new(slate_matchup: slate_matchups(:m1))
    assert_no_frozen_refusal pick

    freeze!(users(:sam))
    pick = Selection.new(entry: entry.reload, slate_matchup: slate_matchups(:m1))
    assert_frozen_refusal pick
  end

  # ── Chat ─────────────────────────────────────────────────────────────────

  test "a frozen account cannot post or react in chat" do
    message = Message.new(contest: @contest, user: @user, body: "hello")
    assert_no_frozen_refusal message
    posted = Message.create!(contest: @contest, user: users(:alex), body: "hi")
    reaction = Reaction.new(message: posted, user: @user, emoji: Reaction::QUICK.first)
    assert_no_frozen_refusal reaction

    freeze!
    assert_frozen_refusal Message.new(contest: @contest, user: @user, body: "hello")
    assert_frozen_refusal Reaction.new(message: posted, user: @user, emoji: Reaction::QUICK.first)
  end

  # ── User: username and wallet ────────────────────────────────────────────

  test "a frozen account cannot change its username" do
    @user.username = "renamed_ok"
    assert_no_frozen_refusal @user
    @user.restore_attributes

    freeze!
    @user.username = "renamed_frozen"
    assert_frozen_refusal @user
    assert_not @user.save
    assert_equal "jordan_test", @user.reload.username
  end

  test "a frozen account cannot link or unlink a wallet" do
    address = Solana::Keypair.generate.to_base58
    @user.web3_solana_address = address
    assert_no_frozen_refusal @user
    @user.restore_attributes

    freeze!
    @user.web3_solana_address = address
    assert_frozen_refusal @user
    @user.restore_attributes
    @user.web2_solana_address = address
    assert_frozen_refusal @user
  end

  test "a frozen account's unrelated save still goes through" do
    freeze!
    @user.last_seen_at = Time.current
    assert @user.save, "only identity changes are held, not every save of the row"
  end

  # ── freeze! / unfreeze! and the audit trail ──────────────────────────────

  test "freeze! and unfreeze! each write one audit row naming the admin and the reason" do
    admin = users(:alex)

    assert_difference -> { AccountFreezeEvent.count }, 1 do
      assert @user.freeze!(reason: "chargeback on order 12", by: admin)
    end
    event = AccountFreezeEvent.recent.first
    assert_equal ["freeze", "admin", "chargeback on order 12", admin, @user],
                 [event.action, event.source, event.reason, event.admin, event.user]
    assert @user.reload.frozen?
    assert_equal "chargeback on order 12", @user.frozen_reason

    assert_difference -> { AccountFreezeEvent.count }, 1 do
      assert @user.unfreeze!(reason: "cleared with the bank", by: admin, source: "admin")
    end
    assert_equal "unfreeze", AccountFreezeEvent.recent.first.action
    assert_not @user.reload.frozen?
    assert_nil @user.frozen_reason
  end

  test "a second freeze or a stray unfreeze writes nothing" do
    @user.freeze!(reason: "first")
    assert_no_difference -> { AccountFreezeEvent.count } do
      assert_not @user.freeze!(reason: "second")
    end
    assert_equal "first", @user.reload.frozen_reason

    @user.unfreeze!
    assert_no_difference -> { AccountFreezeEvent.count } do
      assert_not @user.unfreeze!
    end
  end

  test "a freeze needs a reason" do
    assert_raises(ArgumentError) { @user.freeze!(reason: "  ") }
    assert_not @user.reload.frozen?
    assert_equal 0, AccountFreezeEvent.where(user: @user).count
  end

  test "the payment-risk webhooks' freeze records its own source" do
    @user.freeze_for_payment_risk!(reason: "stripe.dispute charge=ch_1")
    event = AccountFreezeEvent.where(user: @user).sole
    assert_equal ["freeze", "payment_risk", nil], [event.action, event.source, event.admin]
  end

  test "an audit row cannot be edited" do
    @user.freeze!(reason: "first")
    event = AccountFreezeEvent.where(user: @user).sole
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(reason: "rewritten") }
  end
end
