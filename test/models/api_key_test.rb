require "test_helper"

# [unit] ApiKey — mint, digest lookup, revoke, expiry.
class ApiKeyTest < ActiveSupport::TestCase
  setup { @user = users(:jordan) }

  def mint(user: @user, name: "Claude", **attrs)
    ApiKey.mint!(user: user, name: name, geo_country: "US", geo_state: "CO", age_result: "not_required", **attrs)
  end

  # --- mint --------------------------------------------------------------------

  test "mint returns a key-shaped raw token and stores only its digest and prefix" do
    key = mint

    assert_match ApiKey::TOKEN_FORMAT, key.raw_token
    assert_equal Digest::SHA256.hexdigest(key.raw_token), key.token_digest
    assert_equal key.raw_token[0, ApiKey::PREFIX_LENGTH], key.prefix
    assert_equal 10, key.prefix.length

    # No column holds the raw key, in whole or beyond the display prefix.
    stored = ApiKey.find(key.id).attributes.values.map(&:to_s)
    assert_not stored.any? { |value| value.include?(key.raw_token) }
    assert_not stored.any? { |value| value.include?(key.raw_token[ApiKey::PREFIX_LENGTH..]) }
  end

  test "the raw token exists only on the instance mint returned" do
    key = mint

    assert key.raw_token.present?
    assert_nil ApiKey.find(key.id).raw_token
  end

  test "inspect shows neither the raw token nor the digest" do
    key = mint

    assert_not_includes key.inspect, key.raw_token
    assert_not_includes key.inspect, key.token_digest
  end

  test "every mint is a different key" do
    assert_not_equal mint.raw_token, mint.raw_token
  end

  test "a key expires ninety days after mint" do
    now = Time.utc(2026, 10, 1, 12)
    key = mint(now: now)

    assert_equal now + 90.days, key.expires_at
  end

  test "mint stamps the eligibility it was given" do
    now = Time.utc(2026, 10, 1, 12)
    key = ApiKey.mint!(user: @user, name: "Claude", geo_country: "US", geo_state: "CO", age_result: "passed", now: now)

    assert_equal(
      { geo: { result: "allowed", country: "US", state: "CO" }, age_gate: "passed", attested_at: now.iso8601 },
      key.eligibility
    )
  end

  test "mint refuses an age verdict outside the known vocabulary" do
    assert_raises(ActiveRecord::RecordInvalid) do
      ApiKey.mint!(user: @user, name: "Claude", geo_country: "US", geo_state: "CO", age_result: "pending")
    end
    assert_equal 0, @user.api_keys.count
  end

  test "a name is required: blank, whitespace and nil are all refused and mint nothing" do
    ["", "   ", nil].each do |blank|
      error = assert_raises(ActiveRecord::RecordInvalid) { mint(name: blank) }
      assert_equal ["Name can't be blank"], error.record.errors.full_messages
    end
    assert_equal 0, @user.api_keys.count
  end

  test "a name is trimmed, and an over-long one is refused" do
    assert_equal "Claude", mint(name: " Claude ").name
    assert_nothing_raised { mint(name: "x" * ApiKey::NAME_MAX_LENGTH) }
    assert_raises(ActiveRecord::RecordInvalid) { mint(name: "x" * (ApiKey::NAME_MAX_LENGTH + 1)) }
  end

  test "mint stops at the per-user cap, counting only active keys" do
    ApiKey::MAX_ACTIVE_PER_USER.times { mint }

    assert_raises(ApiKey::LimitReached) { mint }
    assert_equal ApiKey::MAX_ACTIVE_PER_USER, @user.api_keys.count

    # A revoked key frees a slot, and so does an expired one.
    @user.api_keys.first.revoke!
    assert_nothing_raised { mint }
    @user.api_keys.active.first.update_column(:expires_at, 1.minute.ago)
    assert_nothing_raised { mint }

    # Another player's cap is their own.
    assert_nothing_raised { mint(user: users(:sam)) }
  end

  # --- digest lookup -----------------------------------------------------------

  test "find_by_raw_token resolves the minted key" do
    key = mint

    assert_equal key, ApiKey.find_by_raw_token(key.raw_token)
  end

  test "find_by_raw_token is nil for an unknown, malformed, blank or digest value" do
    key = mint

    assert_nil ApiKey.find_by_raw_token("tmk_" + "a" * ApiKey::TOKEN_LENGTH)
    assert_nil ApiKey.find_by_raw_token(key.raw_token + "x")
    assert_nil ApiKey.find_by_raw_token(key.raw_token.upcase)
    assert_nil ApiKey.find_by_raw_token("")
    assert_nil ApiKey.find_by_raw_token(nil)
    # The stored digest is not itself a credential.
    assert_nil ApiKey.find_by_raw_token(key.token_digest)
  end

  test "a malformed value never reaches the database" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      ApiKey.find_by_raw_token("not-a-key")
    end

    assert_empty queries
  end

  test "find_by_raw_token still returns a revoked or expired key, for the caller to judge" do
    key = mint
    key.revoke!

    assert_equal key, ApiKey.find_by_raw_token(key.raw_token)
  end

  # --- revoke ------------------------------------------------------------------

  test "revoke stamps revoked_at, leaves the active scope, and is idempotent" do
    key = mint
    first = Time.utc(2026, 10, 2)

    key.revoke!(now: first)
    assert key.revoked?
    assert_not key.active?
    assert_equal "revoked", key.status
    assert_not_includes @user.api_keys.active, key

    key.revoke!(now: first + 1.day)
    assert_equal first, key.reload.revoked_at
  end

  # --- expiry ------------------------------------------------------------------

  test "a key is active up to its expiry and expired from that instant" do
    now = Time.utc(2026, 10, 1, 12)
    key = mint(now: now)

    assert key.active?(key.expires_at - 1.second)
    assert_equal "active", key.status(key.expires_at - 1.second)
    assert key.expired?(key.expires_at)
    assert_not key.active?(key.expires_at)
    assert_equal "expired", key.status(key.expires_at)
  end

  test "the active scope excludes an expired key" do
    key = mint
    key.update_column(:expires_at, 1.second.ago)

    assert_not_includes ApiKey.active, key
  end

  # --- last used ---------------------------------------------------------------

  test "touch_last_used writes at most once per resolution window" do
    key = mint
    now = Time.utc(2026, 10, 1, 12)

    key.touch_last_used!(now: now)
    assert_equal now, key.reload.last_used_at

    key.touch_last_used!(now: now + 30.seconds)
    assert_equal now, key.reload.last_used_at

    key.touch_last_used!(now: now + 61.seconds)
    assert_equal now + 61.seconds, key.reload.last_used_at
  end

  # --- the name, in the table as well as the model ------------------------------

  test "the table itself refuses a key with no name" do
    key = mint

    assert_not ApiKey.columns_hash.fetch("name").null, "api_keys.name must be NOT NULL in the schema"
    # update_column skips the validation, so this is the database answering.
    # In a savepoint: the violation aborts the transaction it happens in.
    assert_raises(ActiveRecord::NotNullViolation) do
      ApiKey.transaction(requires_new: true) { key.update_column(:name, nil) }
    end
    assert_equal "Claude", key.reload.name
  end

  # --- ownership ---------------------------------------------------------------

  test "destroying the user destroys their keys" do
    user = User.create!(name: "Key Owner", username: "key_owner_#{SecureRandom.hex(3)}",
                        email: "key-owner-#{SecureRandom.hex(3)}@example.com")
    mint(user: user)

    assert_difference -> { ApiKey.count }, -1 do
      user.destroy!
    end
  end
end
