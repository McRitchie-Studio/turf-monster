require "test_helper"

# [integration] Minting and revoking agent API keys from /account — and the
# eligibility gates that run, server-side, on the mint.
class ApiKeysControllerTest < ActionDispatch::IntegrationTest
  GeoResult = Struct.new(:country_code, :state_code, :region_code, :region, keyword_init: true)

  setup do
    @user = users(:jordan)
  end

  # Geo is resolved once per session and cached, so the lookup has to be
  # stubbed around the LOGIN as well as the request under test.
  def in_state(state_code, &block)
    Studio::GeoSetting.current.update!(enabled: true, banned_subdivisions: %w[WA ID MT])
    results = state_code ? [GeoResult.new(country_code: "US", state_code: state_code)] : []
    Geocoder.stub(:search, results, &block)
  end

  def with_age_gate
    prior = ENV["ENABLE_AGE_GATE"]
    ENV["ENABLE_AGE_GATE"] = "true"
    yield
  ensure
    prior.nil? ? ENV.delete("ENABLE_AGE_GATE") : ENV["ENABLE_AGE_GATE"] = prior
  end

  def without_age_gate
    prior = ENV.delete("ENABLE_AGE_GATE")
    yield
  ensure
    ENV["ENABLE_AGE_GATE"] = prior unless prior.nil?
  end

  def shown_key
    response.body[/tmk_[A-Za-z0-9]{#{ApiKey::TOKEN_LENGTH}}/]
  end

  # --- mint --------------------------------------------------------------------

  test "an eligible player mints a key that is shown once and works as a bearer credential" do
    in_state("CO") do
      without_age_gate do
        log_in_as(@user)

        assert_difference -> { @user.api_keys.count }, 1 do
          post account_api_keys_path, params: { name: "Claude" }
        end
      end
    end

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    raw = shown_key
    assert raw.present?, "the response to the mint is the page that shows the key"

    key = @user.api_keys.last
    assert_equal key, ApiKey.find_by_raw_token(raw)
    assert_equal "Claude", key.name
    assert_in_delta 90.days.from_now, key.expires_at, 5.seconds

    # Shown once: the account page lists the key by prefix and never the key.
    get account_path
    assert_response :success
    assert_includes response.body, %(data-api-key-row="#{key.id}")
    assert_includes response.body, key.prefix
    assert_not_includes response.body, raw

    # And it is a working credential, with no cookie involved.
    reset!
    get api_v1_me_path, headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
  end

  test "the mint stamps the geo it read from the player's own request" do
    in_state("CO") do
      without_age_gate do
        log_in_as(@user)
        post account_api_keys_path
      end
    end

    assert_equal(
      { result: "allowed", country: "US", state: "CO" },
      @user.api_keys.last.eligibility[:geo]
    )
    assert_equal "not_required", @user.api_keys.last.eligibility_age_result
  end

  test "the raw key is not written to the session cookie or the flash" do
    log_in_as(@user)
    post account_api_keys_path
    raw = shown_key

    assert_nil flash[:notice]
    assert_not session.to_h.to_s.include?(raw)
  end

  test "neither the mint nor a bearer request writes the raw key to the log" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    logger.level = Logger::DEBUG
    Rails.logger.broadcast_to(logger)
    prior_level = Rails.logger.level
    Rails.logger.level = Logger::DEBUG

    log_in_as(@user)
    post account_api_keys_path, params: { name: "Logged" }
    raw = shown_key
    get api_v1_me_path, headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success

    assert_includes log.string, "ApiKeysController#create", "the capture must have seen these requests"
    assert_includes log.string, "Api::V1::MeController#show"
    assert_not_includes log.string, raw
    assert_not_includes log.string, raw[ApiKey::PREFIX_LENGTH..]
  ensure
    Rails.logger.stop_broadcasting_to(logger)
    Rails.logger.level = prior_level
  end

  test "request parameters that could carry a key are filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("api_key" => "tmk_secret", "token" => "tmk_secret", "access_token" => "tmk_secret")

    assert_equal %w[[FILTERED]], filtered.values.uniq
  end

  # --- mint: the gates ---------------------------------------------------------

  test "mint is refused in a blocked state and no key is created" do
    in_state("WA") do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path
      end
    end

    assert_response :redirect
    assert_match(/not available in your state/i, flash[:alert])
    assert_nil shown_key
  end

  test "mint fails closed when the player's location cannot be resolved" do
    in_state(nil) do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path
      end
    end

    assert_response :redirect
    assert_match(/not available in your state/i, flash[:alert])
  end

  test "with the age gate on, an unverified player is refused" do
    @user.update_column(:age_attested_at, nil)

    with_age_gate do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path
      end
    end

    assert_redirected_to account_path
    assert_equal ApiKeysController::AGE_PENDING_MESSAGE, flash[:alert]
  end

  test "with the age gate on, a verified player mints a key stamped passed" do
    @user.update_column(:age_attested_at, 1.day.ago)

    with_age_gate do
      log_in_as(@user)
      post account_api_keys_path
    end

    assert_response :created
    assert_equal "passed", @user.api_keys.last.eligibility_age_result
  end

  test "a frozen account cannot mint" do
    log_in_as(@user)
    @user.freeze_for_payment_risk!(reason: "test")

    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path
    end

    assert_redirected_to account_path
    assert_match(/on hold/i, flash[:alert])
  end

  test "a signed-out visitor cannot mint" do
    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path
    end

    assert_redirected_to signin_path
  end

  test "an impersonating admin cannot mint a key for the target" do
    admin = users(:alex)
    # Fixtures bypass Sluggable's before_save, and the impersonation route keys
    # on the slug.
    [admin, @user].each { |u| u.update_column(:slug, u.send(:name_slug)) }
    log_in_as(admin)
    post admin_impersonate_path(@user.slug)
    assert_equal @user.id, session[:impersonated_user_id]

    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path
    end

    assert_redirected_to account_path
    assert_equal ApiKeysController::IMPERSONATION_MESSAGE, flash[:alert]
  end

  test "the per-user cap is a friendly refusal, not an error log" do
    ApiKey::MAX_ACTIVE_PER_USER.times do
      ApiKey.mint!(user: @user, geo_country: "US", geo_state: "CO", age_result: "not_required")
    end
    log_in_as(@user)

    assert_no_difference [-> { ApiKey.count }, -> { ErrorLog.count }] do
      post account_api_keys_path
    end

    assert_redirected_to account_path
    assert_match(/up to #{ApiKey::MAX_ACTIVE_PER_USER} active keys/, flash[:alert])
  end

  # --- revoke ------------------------------------------------------------------

  test "a player revokes their key and it stops authenticating" do
    key = ApiKey.mint!(user: @user, geo_country: "US", geo_state: "CO", age_result: "not_required")
    log_in_as(@user)

    delete account_api_key_path(key)

    assert_redirected_to account_path
    assert_match(/revoked/i, flash[:notice])
    assert key.reload.revoked?

    # Gone from the list (the prefix survives only in the flash that names it).
    follow_redirect!
    assert_not_includes response.body, %(data-api-key-row="#{key.id}")

    reset!
    get api_v1_me_path, headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :unauthorized
    assert_equal "revoked_api_key", JSON.parse(response.body).dig("error", "code")
  end

  test "a player cannot revoke someone else's key" do
    other_key = ApiKey.mint!(user: users(:sam), geo_country: "US", geo_state: "CO", age_result: "not_required")
    log_in_as(@user)

    delete account_api_key_path(other_key)

    assert_response :not_found
    assert_not other_key.reload.revoked?
  end

  test "a signed-out visitor cannot revoke" do
    key = ApiKey.mint!(user: @user, geo_country: "US", geo_state: "CO", age_result: "not_required")

    delete account_api_key_path(key)

    assert_redirected_to signin_path
    assert_not key.reload.revoked?
  end
end
