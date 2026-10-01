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

  def page
    Nokogiri::HTML5(response.body)
  end

  # What Turbo sends when a form inside the card's frame is submitted.
  FRAME = { "Turbo-Frame" => "api_keys_card" }.freeze

  def mint_for(user, name: "Claude")
    ApiKey.mint!(user: user, name: name, geo_country: "US", geo_state: "CO", age_result: "not_required")
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
    assert raw.present?, "the response to the mint is what shows the key"

    key = @user.api_keys.last
    assert_equal key, ApiKey.find_by_raw_token(raw)
    assert_equal "Claude", key.name
    assert_in_delta 90.days.from_now, key.expires_at, 5.seconds

    # Shown once: neither the card nor the account page ever renders it again.
    [account_api_keys_path, account_path].each do |path|
      get path
      assert_response :success
      assert_includes response.body, %(data-api-key-row="#{key.id}")
      assert_includes response.body, key.prefix
      assert_not_includes response.body, raw
    end

    # And it is a working credential, with no cookie involved.
    reset!
    get api_v1_me_path, headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
  end

  test "the mint stamps the geo it read from the player's own request" do
    in_state("CO") do
      without_age_gate do
        log_in_as(@user)
        post account_api_keys_path, params: { name: "Claude" }
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
    post account_api_keys_path, params: { name: "Claude" }
    raw = shown_key

    assert raw.present?
    assert_empty flash.to_h
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

  # --- the card updates in place -------------------------------------------------

  test "a mint from inside the card answers with the card alone, key included" do
    log_in_as(@user)

    post account_api_keys_path, params: { name: "Claude" }, headers: FRAME

    assert_response :created
    assert_equal 1, page.css("turbo-frame#api_keys_card").size
    assert page.at_css("turbo-frame#api_keys_card [data-api-key-created]")
    assert_equal shown_key, page.at_css("[data-api-key-secret] code").text
    assert_nil page.at_css("nav"), "a frame request must not carry the site layout"
    assert_nil page.at_css("form[data-api-key-form]"), "no second form while the key is on screen"
  end

  test "the card by itself is served to the frame and, with a layout, to a plain browser" do
    key = mint_for(@user)
    log_in_as(@user)

    get account_api_keys_path, headers: FRAME
    assert_response :success
    assert page.at_css(%(turbo-frame#api_keys_card [data-api-key-row="#{key.id}"]))
    assert_nil page.at_css("nav")

    get account_api_keys_path
    assert_response :success
    assert page.at_css(%(turbo-frame#api_keys_card [data-api-key-row="#{key.id}"]))
    assert page.at_css("nav")
  end

  test "the account page carries the same frame the card endpoints answer with" do
    log_in_as(@user)

    get account_path

    assert_equal 1, page.css("turbo-frame#api_keys_card").size
    assert page.at_css("turbo-frame#api_keys_card form[data-api-key-form]")
  end

  # --- mint: the name --------------------------------------------------------------

  test "a blank name is refused inline, keeps the form open, and writes no error log" do
    mint_for(@user, name: "Existing")
    log_in_as(@user)

    ["", "   ", nil].each do |blank|
      assert_no_difference [-> { ApiKey.count }, -> { ErrorLog.count }] do
        post account_api_keys_path, params: { name: blank }.compact, headers: FRAME
      end

      assert_response :unprocessable_entity
      assert_equal "Name can't be blank", page.at_css("[data-api-key-error]").text
      assert_equal "true", page.at_css('input[name="name"]')["aria-invalid"]
      # The form sits behind "Add another" when keys exist; a refusal reopens it.
      assert_match(/adding: true/, page.at_css("form[data-api-key-form]").parent["x-data"])
      assert_nil shown_key
    end
  end

  test "an over-long name is refused inline and what was typed is kept" do
    log_in_as(@user)
    long = "x" * (ApiKey::NAME_MAX_LENGTH + 1)

    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path, params: { name: long }, headers: FRAME
    end

    assert_response :unprocessable_entity
    assert_match(/too long/, page.at_css("[data-api-key-error]").text)
    assert_equal long, page.at_css('input[name="name"]')["value"]
  end

  # --- mint: the gates ---------------------------------------------------------

  def assert_mint_refused(reason)
    assert_response :forbidden
    assert page.at_css(%(turbo-frame#api_keys_card [data-api-key-blocked="#{reason}"])),
           "the refusal is the card, saying why"
    assert_nil page.at_css("form[data-api-key-form]")
    assert_nil shown_key
  end

  test "mint is refused in a blocked state and no key is created" do
    in_state("WA") do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path, params: { name: "Claude" }, headers: FRAME
      end
    end

    assert_mint_refused :geo
  end

  test "mint fails closed when the player's location cannot be resolved" do
    in_state(nil) do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path, params: { name: "Claude" }, headers: FRAME
      end
    end

    assert_mint_refused :geo
  end

  test "with the age gate on, an unverified player is refused" do
    @user.update_column(:age_attested_at, nil)

    with_age_gate do
      log_in_as(@user)

      assert_no_difference -> { ApiKey.count } do
        post account_api_keys_path, params: { name: "Claude" }, headers: FRAME
      end
    end

    assert_mint_refused :age
  end

  test "once the age gate is passed the card, re-fetched, offers the form" do
    @user.update_column(:age_attested_at, nil)

    with_age_gate do
      log_in_as(@user)
      get account_api_keys_path, headers: FRAME
      assert page.at_css('[data-api-key-blocked="age"]')
      assert_nil page.at_css("form[data-api-key-form]")

      # What the birthday card does on success, then the frame's re-fetch.
      @user.update_column(:age_attested_at, Time.current)
      get account_api_keys_path, headers: FRAME
    end

    assert_nil page.at_css("[data-api-key-blocked]")
    assert page.at_css("form[data-api-key-form]")
  end

  test "with the age gate on, a verified player mints a key stamped passed" do
    @user.update_column(:age_attested_at, 1.day.ago)

    with_age_gate do
      log_in_as(@user)
      post account_api_keys_path, params: { name: "Claude" }
    end

    assert_response :created
    assert_equal "passed", @user.api_keys.last.eligibility_age_result
  end

  test "a frozen account cannot mint" do
    log_in_as(@user)
    @user.freeze_for_payment_risk!(reason: "test")

    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path, params: { name: "Claude" }, headers: FRAME
    end

    assert_mint_refused :frozen
  end

  test "a signed-out visitor cannot mint" do
    assert_no_difference -> { ApiKey.count } do
      post account_api_keys_path, params: { name: "Claude" }
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
      post account_api_keys_path, params: { name: "Claude" }, headers: FRAME
    end

    assert_mint_refused :impersonating
  end

  test "the per-user cap is an inline refusal, not an error log" do
    ApiKey::MAX_ACTIVE_PER_USER.times { mint_for(@user) }
    log_in_as(@user)

    assert_no_difference [-> { ApiKey.count }, -> { ErrorLog.count }] do
      post account_api_keys_path, params: { name: "One too many" }, headers: FRAME
    end

    assert_response :unprocessable_entity
    assert page.at_css('[data-api-key-blocked="limit"]')
    assert_nil shown_key
  end

  # --- revoke ------------------------------------------------------------------

  test "a player revokes their key from inside the card and it stops authenticating" do
    key = mint_for(@user)
    other = mint_for(@user, name: "Keeper")
    log_in_as(@user)

    delete account_api_key_path(key), headers: FRAME

    # Back to the card, not the page: the frame follows this and swaps itself.
    assert_redirected_to account_api_keys_path
    assert_response :see_other
    assert key.reload.revoked?
    assert_empty flash.to_h, "a flash would sit unseen until the next full page load"

    get response.location, headers: FRAME
    assert_response :success
    assert_nil page.at_css(%([data-api-key-row="#{key.id}"]))
    assert page.at_css(%(turbo-frame#api_keys_card [data-api-key-row="#{other.id}"]))
    assert_nil page.at_css("nav")

    reset!
    get api_v1_me_path, headers: { "Authorization" => "Bearer #{key.raw_token}" }
    assert_response :unauthorized
    assert_equal "revoked_api_key", JSON.parse(response.body).dig("error", "code")
  end

  test "a player cannot revoke someone else's key" do
    other_key = mint_for(users(:sam))
    log_in_as(@user)

    delete account_api_key_path(other_key)

    assert_response :not_found
    assert_not other_key.reload.revoked?
  end

  test "a signed-out visitor cannot revoke" do
    key = mint_for(@user)

    delete account_api_key_path(key)

    assert_redirected_to signin_path
    assert_not key.reload.revoked?
  end
end
