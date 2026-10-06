require "test_helper"

# [unit] The "notify me when the slate drops" list: one row per address per
# drop, normalized, validated with the app's own email predicate.
class DropSignupTest < ActiveSupport::TestCase
  KEY = NextSlateDrop::SLATE_KEY

  test "an address is stripped and lowercased before it is stored" do
    signup = DropSignup.register(email: "  Fan@Example.COM ", slate_key: KEY)

    assert signup.persisted?
    assert_equal "fan@example.com", signup.reload.email
  end

  test "a malformed address is refused with an error and no row" do
    ["", "not-an-email", "fan@localhost", "fan@example.c"].each do |bad|
      signup = DropSignup.register(email: bad, slate_key: KEY)
      refute signup.persisted?, "#{bad.inspect} must not be stored"
      assert signup.errors[:email].any?, "#{bad.inspect} must carry an email error"
    end
    assert_equal 0, DropSignup.count
  end

  test "a slate key is required" do
    signup = DropSignup.new(email: "fan@example.com", slate_key: nil)
    refute signup.valid?
    assert signup.errors[:slate_key].any?
  end

  test "registering the same address twice is idempotent: same row, no second row" do
    first = DropSignup.register(email: "fan@example.com", slate_key: KEY, source: "tiktok")
    second = DropSignup.register(email: "FAN@example.com ", slate_key: KEY, source: "other")

    assert_equal first.id, second.id
    assert_equal 1, DropSignup.count
    assert_equal "tiktok", second.source, "the first source sticks; a resubmit changes nothing"
  end

  test "the same address may sign up for a different drop" do
    DropSignup.register(email: "fan@example.com", slate_key: KEY)
    later = DropSignup.register(email: "fan@example.com", slate_key: "nfl-2026-weeks-10-12")

    assert later.persisted?
    assert_equal 2, DropSignup.count
  end

  test "the model refuses a duplicate even when .register is bypassed" do
    DropSignup.create!(email: "fan@example.com", slate_key: KEY)
    dup = DropSignup.new(email: "Fan@Example.com", slate_key: KEY)

    refute dup.valid?
    assert dup.errors[:email].any?
  end

  test "the unique index answers a race with the existing row, not an exception" do
    winner = DropSignup.create!(email: "fan@example.com", slate_key: KEY)
    # The race: the twin's insert lands between this call's lookup and its own
    # insert. So the FIRST lookup misses, and the save collides on the index.
    calls = 0
    real_find_by = DropSignup.method(:find_by)
    first_miss = ->(*args, **kw) { (calls += 1) == 1 ? nil : real_find_by.call(*args, **kw) }
    raced = DropSignup.stub(:find_by, first_miss) do
      DropSignup.stub(:new, ->(**) { raise ActiveRecord::RecordNotUnique }) do
        DropSignup.register(email: "fan@example.com", slate_key: KEY)
      end
    end

    assert_equal winner.id, raced.id
    assert_equal 1, DropSignup.count
  end

  test "request metadata is trimmed to its column budget" do
    signup = DropSignup.register(email: "fan@example.com", slate_key: KEY,
                                 user_agent: "x" * 2_000, source: "  " + "y" * 300)

    assert_equal DropSignup::USER_AGENT_LIMIT, signup.user_agent.length
    assert_equal DropSignup::SOURCE_LIMIT, signup.source.length
  end

  test "a signed-in visitor's row carries the user; an anonymous one does not" do
    mine = DropSignup.register(email: "alex-drop@example.com", slate_key: KEY, user: users(:alex))
    anon = DropSignup.register(email: "anon@example.com", slate_key: KEY)

    assert_equal users(:alex), mine.user
    assert_nil anon.user
  end

  # The foreign key is ON DELETE SET NULL, so the database keeps the address
  # when the account goes (a raw DELETE, so no Rails callback can help it).
  test "deleting the account keeps the signup and clears its user" do
    signup = DropSignup.register(email: "casey-drop@example.com", slate_key: KEY, user: users(:casey))
    User.connection.execute("DELETE FROM users WHERE id = #{users(:casey).id}")

    assert_nil signup.reload.user_id
  end

  test "recent lists newest first" do
    old = DropSignup.create!(email: "old@example.com", slate_key: KEY, created_at: 2.days.ago)
    new_one = DropSignup.create!(email: "new@example.com", slate_key: KEY)

    assert_equal [new_one, old], DropSignup.recent.to_a
  end
end
