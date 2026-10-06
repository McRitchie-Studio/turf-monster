require "test_helper"

# [unit] The drop list's mail state on DropSignup: the atomic claims that make
# each email go out at most once, the signed unsubscribe token, and the account
# lookup the mailer's new/existing variant reads.
class DropSignupEmailStateTest < ActiveSupport::TestCase
  KEY = NextSlateDrop::SLATE_KEY

  def signup(email = "fan@example.com", **attrs)
    DropSignup.create!(email: email, slate_key: KEY, **attrs)
  end

  def confirmations_for(row)
    EmailDelivery.where(email_key: "DropSignupMailer#confirmation", to: row.email).count
  end

  # --- confirmation -----------------------------------------------------------

  test "the confirmation queues once and stamps confirmation_sent_at" do
    row = signup
    assert row.deliver_confirmation!
    assert row.reload.confirmation_sent_at.present?
    assert_equal 1, confirmations_for(row)
  end

  test "a second ask for the confirmation is a no-op" do
    row = signup
    row.deliver_confirmation!
    refute row.deliver_confirmation!
    refute DropSignup.find(row.id).deliver_confirmation!, "a fresh load of the row agrees"
    assert_equal 1, confirmations_for(row)
  end

  test "an unsubscribed row is never sent a confirmation" do
    row = signup(unsubscribed_at: Time.current)
    refute row.deliver_confirmation!
    assert_equal 0, confirmations_for(row)
  end

  test "a failed queue releases the claim so a later ask can retry" do
    row = signup
    Studio::Email.stub(:deliver, ->(*, **) { raise "outbox down" }) do
      assert_raises(RuntimeError) { row.deliver_confirmation! }
    end
    assert_nil row.reload.confirmation_sent_at
    assert row.deliver_confirmation!
  end

  # --- announcement claim -----------------------------------------------------

  # Two holders of the SAME row, both loaded before either claimed: what a
  # double-click, two admins or two jobs look like. The database decides, not
  # the in-memory copy, so exactly one wins.
  test "two concurrent announcement claims on one row send once" do
    row = signup
    a = DropSignup.find(row.id)
    b = DropSignup.find(row.id)

    results = [a.deliver_announcement!, b.deliver_announcement!]

    assert_equal [true, false], results
    assert_equal 1, EmailDelivery.where(email_key: "DropSignupMailer#announcement", to: row.email).count
    assert_equal EmailDelivery.last.id, row.reload.announcement_delivery_id, "the claim records its outbox receipt"
  end

  test "announceable skips notified and unsubscribed rows and other drops" do
    owed = signup("owed@example.com")
    signup("done@example.com", notified_at: 1.hour.ago)
    signup("gone@example.com", unsubscribed_at: 1.hour.ago)
    DropSignup.create!(email: "next@example.com", slate_key: "nfl-2026-weeks-10-12")

    assert_equal [owed.id], DropSignup.announceable(KEY).pluck(:id)
  end

  test "an unsubscribed or already-notified row cannot be claimed" do
    refute signup("gone@example.com", unsubscribed_at: Time.current).deliver_announcement!
    refute signup("done@example.com", notified_at: Time.current).deliver_announcement!
    assert_equal 0, EmailDelivery.where(email_key: "DropSignupMailer#announcement").count
  end

  # --- unsubscribe token ------------------------------------------------------

  test "the unsubscribe token resolves to its own row" do
    row = signup
    assert_equal row, DropSignup.find_by_unsubscribe_token(row.unsubscribe_token)
  end

  test "a tampered, foreign-purpose or junk token resolves to nothing" do
    row = signup
    token = row.unsubscribe_token
    tampered = token.sub(/.\z/) { |c| c == "A" ? "B" : "A" }

    assert_nil DropSignup.find_by_unsubscribe_token(tampered)
    assert_nil DropSignup.find_by_unsubscribe_token(row.signed_id(purpose: :something_else))
    assert_nil DropSignup.find_by_unsubscribe_token("preview")
    assert_nil DropSignup.find_by_unsubscribe_token(nil)
  end

  test "another row's id cannot be forged into a token" do
    row = signup
    other = signup("other@example.com")
    payload, digest = row.unsubscribe_token.split("--")
    forged = "#{payload.tr('A-Za-z', 'B-ZAb-za')}--#{digest}"
    assert_nil DropSignup.find_by_unsubscribe_token(forged)
    refute_equal other, DropSignup.find_by_unsubscribe_token(row.unsubscribe_token)
  end

  test "unsubscribe is idempotent and keeps the first time" do
    row = signup
    row.unsubscribe!
    first = row.reload.unsubscribed_at
    travel 1.hour do
      row.unsubscribe!
    end
    assert_equal first.to_i, row.reload.unsubscribed_at.to_i
  end

  # --- account lookup ---------------------------------------------------------

  test "account is the signed-in visitor's user" do
    row = signup("someone-else@example.com", user: users(:jordan))
    assert_equal users(:jordan), row.account
  end

  test "account matches an existing user's address case-insensitively" do
    users(:sam).update_columns(email: "Sam.Player@Example.com")
    row = signup("sam.player@example.com")
    assert_equal users(:sam), row.account
    assert row.existing_account?
  end

  test "an address no account holds has no account" do
    refute signup("stranger@example.com").existing_account?
  end
end

# [unit] The same claim under REAL concurrency: no transactional fixture
# wrapper, so each thread holds its own database connection and the two
# UPDATEs genuinely race in Postgres. Whatever the interleaving, one wins.
class DropSignupClaimRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    rows = DropSignup.where(email: "race@example.com")
    delivery_ids = rows.pluck(:announcement_delivery_id).compact
    rows.delete_all
    EmailDelivery.where(id: delivery_ids).or(EmailDelivery.where(to: "race@example.com")).delete_all
  end

  test "two connections racing on one row produce exactly one send" do
    row = DropSignup.create!(email: "race@example.com", slate_key: NextSlateDrop::SLATE_KEY)
    # Both racers load the row BEFORE either claims (`loaded`), then are
    # released together (`gate`): each holds a copy that says "unclaimed".
    loaded = Concurrent::CountDownLatch.new(2)
    gate = Concurrent::CountDownLatch.new(1)
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          racer = DropSignup.find(row.id)
          loaded.count_down
          gate.wait(5)
          results << racer.deliver_announcement!
        end
      end
    end
    assert loaded.wait(5), "both racers loaded the row"
    gate.count_down
    threads.each(&:join)

    outcomes = Array.new(2) { results.pop }
    assert_equal 1, outcomes.count(true), "exactly one racer wins: #{outcomes.inspect}"
    assert_equal 1, EmailDelivery.where(email_key: "DropSignupMailer#announcement", to: "race@example.com").count
  end
end
