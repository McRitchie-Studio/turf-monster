require "test_helper"

# Rails mirror of turf-vault's on-chain reserved-username validation
# (programs/turf_vault/src/instructions/set_username.rs RESERVED_PREFIXES,
# v0.15.1 audit C2) + the User.turf stable-identity lookup. Without the
# mirror, users can hold Rails usernames that later fail on-chain with an
# opaque 0x1784 (6020 UsernameReserved).
class UserReservedUsernameTest < ActiveSupport::TestCase
  test "RESERVED_USERNAME_PREFIXES mirrors the 11 on-chain entries" do
    assert_equal %w[admin system turf vault turfmonster support mod official staff team root],
                 User::RESERVED_USERNAME_PREFIXES
  end

  test "reserved_username? is a case-insensitive starts-with check" do
    assert User.reserved_username?("turf")
    assert User.reserved_username?("Turfzilla")
    assert User.reserved_username?("ADMINistrator")
    assert User.reserved_username?("mod-squad")
    assert User.reserved_username?("VaultBoy")
    refute User.reserved_username?("nomad")     # contains "mod", doesn't start with it
    refute User.reserved_username?("commodore") # ditto
    refute User.reserved_username?("breezy-otter")
    refute User.reserved_username?(nil)
  end

  test "non-admin cannot change to a reserved-prefix username" do
    user = users(:jordan)
    user.username = "turfking"
    refute user.valid?
    assert_match(/reserved word "turf"/, user.errors[:username].first)
    assert_match(/on-chain/, user.errors[:username].first)
  end

  test "reserved check is case-insensitive at validation time" do
    user = users(:jordan)
    user.username = "OfficialJordan"
    refute user.valid?
  end

  test "admin is exempt from the reserved-prefix check (on-chain admin path)" do
    admin = users(:alex)
    admin.username = "turf-house"
    assert admin.valid?, admin.errors.full_messages.join(", ")
  end

  test "a grandfathered reserved username does not block unrelated updates" do
    user = users(:jordan)
    user.update_column(:username, "turfster") # bypass validations, simulate legacy row
    user.reload
    assert user.update(name: "Renamed Jordan"), user.errors.full_messages.join(", ")
  end

  test "explicitly provided reserved username is rejected at signup" do
    user = User.new(email: "squatter@mcritchie.studio", username: "support_bob")
    refute user.valid?
    assert user.errors[:username].any? { |e| e.include?("reserved word") }
  end

  test "ensure_username rejects reserved-prefix generator draws" do
    draws = ["turf-otter", "modest-mango", "clean-otter"]
    Studio::UsernameGenerator.stub(:generate, -> { draws.shift || "backstop-name" }) do
      user = User.create!(email: "generated@mcritchie.studio")
      assert_equal "clean-otter", user.username
    end
  end

  test "ensure_username keeps the 30-char truncate backstop for over-long draws" do
    long = "very-long-but-unreserved-#{"x" * 30}"
    Studio::UsernameGenerator.stub(:generate, long) do
      user = User.create!(email: "longname@mcritchie.studio")
      assert_equal 30, user.username.length
      refute User.reserved_username?(user.username)
    end
  end

  # --- User.turf stable-identity lookup ---

  test "User.turf finds the house account by TURF_HOUSE_EMAIL" do
    house = User.create!(email: User::TURF_HOUSE_EMAIL, name: "Turf Monster", role: "admin", username: "turf", seeding_parked_identity: true)
    assert_equal house, User.turf
  end

  test "User.turf survives a username rename (email is the stable key)" do
    house = User.create!(email: User::TURF_HOUSE_EMAIL, role: "admin", username: "turf", seeding_parked_identity: true)
    house.update!(username: "turf-monster") # admin-exempt from the reserved check
    assert_equal house, User.turf
  end

  test "User.turf falls back to the turf username for legacy rows without the seeded email" do
    legacy = User.create!(email: "legacy-house@mcritchie.studio", role: "admin", username: "turf")
    assert_equal legacy, User.turf
  end

  test "User.turf returns nil in an unseeded DB" do
    assert_nil User.turf
  end
end
