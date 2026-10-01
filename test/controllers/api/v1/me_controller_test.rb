require "test_helper"

# [integration] The agent API's front door: bearer-key authentication on
# GET /api/v1/me, every 401 path, and what the endpoint reports.
class Api::V1::MeControllerTest < ActionDispatch::IntegrationTest
  AGENT_UA = "python-httpx/0.27.0".freeze
  # A user agent `allow_browser versions: :modern` REFUSES. Rails only 406s a
  # user agent it can identify as an out-of-date browser — an unrecognised one
  # (curl, httpx) is let through — so this is the string that proves the API is
  # outside that guard: an agent runtime built on an old embedded WebKit (Safari 14 here).
  STALE_BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " \
                     "(KHTML, like Gecko) Version/14.0 Safari/605.1.15".freeze

  FakeVault = Struct.new(:tokens, :error) do
    def list_entry_tokens(_address)
      raise error if error

      tokens
    end
  end

  setup do
    @user = users(:jordan)
    @key = mint_key(@user)
  end

  def mint_key(user, **attrs)
    ApiKey.mint!(user: user, name: "Claude", geo_country: "US", geo_state: "CO", age_result: "not_required", **attrs)
  end

  def get_me(token: @key.raw_token, authorization: nil, headers: {})
    authorization ||= "Bearer #{token}" if token
    get api_v1_me_path, headers: { "User-Agent" => AGENT_UA }.merge(headers)
                                   .merge(authorization ? { "Authorization" => authorization } : {})
  end

  def json
    JSON.parse(response.body)
  end

  def assert_api_error(status, code)
    assert_response status
    assert_equal "application/json", response.media_type
    assert_equal %w[error], json.keys
    assert_equal %w[code message], json["error"].keys.sort
    assert_equal code, json["error"]["code"]
    assert json["error"]["message"].present?
  end

  # --- success -----------------------------------------------------------------

  test "a valid bearer key authenticates with no cookie, no CSRF token and a non-browser user agent" do
    get_me

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal @user.display_name, json.dig("user", "display_name")
    assert_nil response.headers["Set-Cookie"], "a bearer request must not be handed a session"
  end

  test "a user agent the browser stack refuses with 406 is served by the API" do
    get "/faucet", headers: { "User-Agent" => STALE_BROWSER_UA }
    assert_response :not_acceptable

    get_me(headers: { "User-Agent" => STALE_BROWSER_UA })
    assert_response :success
  end

  test "me reports the key's expiry and its eligibility stamp" do
    get_me

    api_key = json["api_key"]
    assert_equal @key.prefix, api_key["prefix"]
    assert_equal @key.expires_at.iso8601, api_key["expires_at"]
    assert_equal(
      { "geo" => { "result" => "allowed", "country" => "US", "state" => "CO" },
        "age_gate" => "not_required",
        "attested_at" => @key.eligibility_attested_at.iso8601 },
      api_key["eligibility"]
    )
  end

  test "me never echoes the key or its digest" do
    get_me

    assert_not_includes response.body, @key.raw_token
    assert_not_includes response.body, @key.token_digest
  end

  test "a successful call stamps last_used_at" do
    assert_nil @key.reload.last_used_at

    get_me

    assert_in_delta Time.current, @key.reload.last_used_at, 5.seconds
  end

  # --- wallet kind and free entry balance ---------------------------------------

  test "a player with no wallet reports kind none and zero free entries without touching the chain" do
    Solana::Vault.stub :new, -> { flunk "no wallet means no RPC" } do
      get_me
    end

    assert_equal({ "kind" => "none", "address" => nil }, json["wallet"])
    assert_equal 0, json["free_entry_tokens"]
  end

  test "a managed wallet reports kind managed and counts only unconsumed tokens" do
    @user.update_columns(web2_solana_address: "Managed#{SecureRandom.hex(4)}")
    tokens = [{ consumed: false }, { consumed: true }, { consumed: false }]

    Solana::Vault.stub :new, FakeVault.new(tokens) do
      get_me
    end

    assert_equal({ "kind" => "managed", "address" => @user.web2_solana_address }, json["wallet"])
    assert_equal 2, json["free_entry_tokens"]
  end

  test "an exported managed wallet and a linked wallet both report self_custodied" do
    @user.update_columns(web2_solana_address: "Managed#{SecureRandom.hex(4)}", self_custodied_at: Time.current)
    Solana::Vault.stub(:new, FakeVault.new([])) { get_me }
    assert_equal "self_custodied", json.dig("wallet", "kind")

    sam_key = mint_key(users(:sam))
    Solana::Vault.stub(:new, FakeVault.new([])) { get_me(token: sam_key.raw_token) }
    assert_equal "self_custodied", json.dig("wallet", "kind")
    assert_equal users(:sam).web3_solana_address, json.dig("wallet", "address")
  end

  test "an unreadable chain reports free_entry_tokens null, never zero" do
    @user.update_columns(web2_solana_address: "Managed#{SecureRandom.hex(4)}")

    Solana::Vault.stub :new, FakeVault.new(nil, RuntimeError.new("rpc down")) do
      get_me
    end

    assert_response :success
    assert json.key?("free_entry_tokens")
    assert_nil json["free_entry_tokens"]
  end

  # --- 401 paths ---------------------------------------------------------------

  test "no Authorization header is 401 missing_api_key with a Bearer challenge" do
    get_me(token: nil)

    assert_api_error :unauthorized, "missing_api_key"
    assert_match(/\ABearer /, response.headers["WWW-Authenticate"])
  end

  test "a non-Bearer Authorization header is 401 missing_api_key" do
    get_me(authorization: "Basic #{Base64.strict_encode64("a:b")}")

    assert_api_error :unauthorized, "missing_api_key"
  end

  test "an unknown key is 401 invalid_api_key" do
    get_me(token: "tmk_" + "z" * ApiKey::TOKEN_LENGTH)

    assert_api_error :unauthorized, "invalid_api_key"
  end

  test "a malformed key is 401 invalid_api_key" do
    get_me(token: "definitely-not-a-key")

    assert_api_error :unauthorized, "invalid_api_key"
  end

  test "a revoked key is 401 revoked_api_key" do
    @key.revoke!

    get_me

    assert_api_error :unauthorized, "revoked_api_key"
  end

  test "an expired key is 401 expired_api_key" do
    @key.update_column(:expires_at, 1.second.ago)

    get_me

    assert_api_error :unauthorized, "expired_api_key"
  end

  test "a refused key is not stamped as used" do
    @key.revoke!

    get_me

    assert_nil @key.reload.last_used_at
  end

  test "the key in a query string or a cookie session is not accepted" do
    log_in_as(@user)

    get api_v1_me_path(api_key: @key.raw_token), headers: { "User-Agent" => AGENT_UA }

    assert_api_error :unauthorized, "missing_api_key"
  end

  # --- what the browser stack would have done ------------------------------------

  test "an incomplete profile is answered, not redirected to the profile form" do
    @user.update_column(:username, nil)

    get_me

    assert_response :success
    assert_nil json.dig("user", "username")
  end

  test "a rotated session token does not disturb a key" do
    @user.regenerate_session_token!

    get_me

    assert_response :success
  end

  test "the request IP's geo is never looked up" do
    Studio::GeoSetting.current.update!(enabled: true, banned_subdivisions: %w[WA])

    Geocoder.stub :search, ->(*) { flunk "the API must not geocode the caller" } do
      get_me
    end

    assert_response :success
  end

  # --- frozen account ------------------------------------------------------------

  test "me stays readable for a frozen account and says so" do
    @user.freeze_for_payment_risk!(reason: "test")

    get_me

    assert_response :success
    assert_equal true, json.dig("account", "frozen")
  end

  # --- unknown routes ------------------------------------------------------------

  test "me is JSON only" do
    get "/api/v1/me.html", headers: { "Authorization" => "Bearer #{@key.raw_token}", "User-Agent" => AGENT_UA }

    assert_response :not_found
  end
end
