require "test_helper"

# Quest-flow HARDENING — the server-side gates ("things you can't do").
#
# The on-chain SeedGrant PDA is the hard once-ever guard (can't unit-test
# without devnet); these pin the Ruby flags + the derived quest ladder that gate
# the contest-card UI and the controller seed payloads. See User#first_username_change?,
# #first_chat_message?, #first_newsletter_join?, #subscribed_to_newsletter?,
# #quest_step, #next_quest, #can_change_username?.
class UserQuestTest < ActiveSupport::TestCase
  # These predicates are pure column reads — an UNSAVED User exercises them
  # without firing create callbacks (managed-wallet generation, on-chain account
  # job). The gate-flip test below uses a persisted user (it needs update!).
  def quester(**attrs)
    User.new({ email: "quester@example.com" }.merge(attrs))
  end

  # --- once-ever quest flags: flip false on first completion, then STAY false ---

  test "first_username_change? is true until username_changed_at is stamped" do
    u = quester
    assert u.first_username_change?, "a brand-new account has never renamed"
    u.username_changed_at = Time.current
    refute u.first_username_change?, "stamping username_changed_at closes the bonus window"
  end

  test "first_chat_message? is true until first_chat_message_at is stamped" do
    u = quester
    assert u.first_chat_message?, "a brand-new account has never chatted"
    u.first_chat_message_at = Time.current
    refute u.first_chat_message?, "stamping first_chat_message_at closes the bonus window"
  end

  test "first_newsletter_join? is true only until the first-ever join and never resets" do
    u = quester
    assert u.first_newsletter_join?, "never joined yet"

    # First-ever join.
    u.joined_email_list_at = Time.current
    u.left_email_list_at   = nil
    refute u.first_newsletter_join?, "joining closes the first-join window"

    # Unsubscribe.
    u.left_email_list_at = Time.current
    refute u.first_newsletter_join?, "leaving must not reopen the bonus"

    # Rejoin — joined_email_list_at is never nil'd, so still not a first join.
    u.joined_email_list_at = Time.current
    u.left_email_list_at   = nil
    refute u.first_newsletter_join?, "a rejoin must never re-pay the quest bonus"
  end

  # --- subscribed_to_newsletter? — drives the quest_step :newsletter/:invite branch ---

  test "subscribed_to_newsletter? tracks join then leave then rejoin" do
    u = quester
    refute u.subscribed_to_newsletter?, "never joined"

    u.joined_email_list_at = Time.current
    assert u.subscribed_to_newsletter?, "joined, not since left"

    u.left_email_list_at = u.joined_email_list_at + 1.second
    refute u.subscribed_to_newsletter?, "left after joining"

    u.joined_email_list_at = u.left_email_list_at + 1.second
    assert u.subscribed_to_newsletter?, "rejoined (joined newer than left)"
  end

  # --- quest_step: the FIRST incomplete of username -> chat -> newsletter -> invite ---

  test "quest_step is :username for a brand-new account" do
    assert_equal :username, quester.quest_step
  end

  test "quest_step advances to :chat once the username has been changed" do
    assert_equal :chat, quester(username_changed_at: Time.current).quest_step
  end

  test "quest_step advances to :newsletter once username + chat are done and not subscribed" do
    u = quester(username_changed_at: Time.current, first_chat_message_at: Time.current)
    assert_equal :newsletter, u.quest_step
  end

  test "quest_step is :invite (terminal) once username + chat are done and subscribed" do
    u = quester(username_changed_at:   Time.current,
                first_chat_message_at: Time.current,
                joined_email_list_at:  Time.current)
    assert_equal :invite, u.quest_step
  end

  test "quest_step skips completed steps: username + newsletter done but no chat -> :chat" do
    # chat is checked BEFORE newsletter, so an out-of-order completion still
    # surfaces the first INCOMPLETE rung rather than jumping past it.
    u = quester(username_changed_at: Time.current, joined_email_list_at: Time.current)
    assert_nil u.first_chat_message_at, "precondition: chat not yet done"
    assert_equal :chat, u.quest_step
  end

  # --- next_quest: prepends :join until a contest is entered ---

  test "next_quest is :join until a contest is entered, regardless of quest flags" do
    u = quester(contest_entered:       false,
                username_changed_at:   Time.current,
                first_chat_message_at: Time.current,
                joined_email_list_at:  Time.current)
    assert_equal :join, u.next_quest, "the quest ladder is gated behind entering a contest"
  end

  test "next_quest delegates to quest_step once a contest is entered" do
    assert_equal :username, quester(contest_entered: true).next_quest

    done = quester(contest_entered:       true,
                   username_changed_at:   Time.current,
                   first_chat_message_at: Time.current,
                   joined_email_list_at:  Time.current)
    assert_equal :invite, done.next_quest
  end

  # --- can_change_username? unlocks when the user enters a contest ---

  test "mark_entered! flips contest_entered and unlocks can_change_username?" do
    # Entry#after_commit calls ReferralProgress.mark_entered! on the user's first
    # active/complete entry. Exercised here directly so the assertion never
    # depends on after_commit timing under transactional tests.
    #
    # can_change_username? is `solana_connected? && contest_entered?`, so the
    # wallet is a PRECONDITION here, not the subject — and it has to be linked
    # explicitly: signup stopped minting one when web3-only onboarding became the
    # default (2026-08-15), and this test used to inherit its wallet from that
    # mint. A linked Phantom address is what a 2026 player actually arrives with.
    user = User.create!(email: "gateflip@mcritchie.studio")
    user.update_columns(web3_solana_address: "PhantomGateFlip#{user.id}")
    assert user.solana_connected?, "precondition: the rename gate needs a linked wallet"
    refute user.contest_entered?
    refute user.can_change_username?, "rename is locked until a contest is entered"

    ReferralProgress.mark_entered!(user)

    assert user.reload.contest_entered?
    assert user.can_change_username?, "entering a contest unlocks the on-chain rename"
  end

  # mark_entered! is a one-way ratchet — a second call is a no-op (idempotent),
  # so contest_entered (and therefore the unlock) can't be toggled back off.
  test "mark_entered! is idempotent (contest_entered is a one-way ratchet)" do
    user = User.create!(email: "ratchet@mcritchie.studio")
    ReferralProgress.mark_entered!(user)
    assert user.reload.contest_entered?
    assert_nothing_raised { ReferralProgress.mark_entered!(user) }
    assert user.reload.contest_entered?
  end
end
