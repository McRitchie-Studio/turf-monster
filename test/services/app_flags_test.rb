require "test_helper"

class AppFlagsTest < ActiveSupport::TestCase
  # AppFlags reads ENV directly — save/restore the var around each case.
  def with_env(value, var: "ENABLE_TEST_SCAFFOLDING")
    original = ENV[var]
    set_env(value, var)
    yield
  ensure
    set_env(original, var)
  end

  def set_env(value, var = "ENABLE_TEST_SCAFFOLDING")
    if value.nil?
      ENV.delete(var)
    else
      ENV[var] = value
    end
  end

  test "test_scaffolding? is false when the env var is unset" do
    with_env(nil) { assert_not AppFlags.test_scaffolding? }
  end

  test "test_scaffolding? is true only for a 'true' value" do
    with_env("true")   { assert AppFlags.test_scaffolding? }
    with_env("TRUE")   { assert AppFlags.test_scaffolding? }
    with_env(" true ") { assert AppFlags.test_scaffolding? }
    with_env("false")  { assert_not AppFlags.test_scaffolding? }
    with_env("1")      { assert_not AppFlags.test_scaffolding? }
    with_env("")       { assert_not AppFlags.test_scaffolding? }
  end

  test "cdp_ramp? is false when the env var is unset (kill-switch default)" do
    with_env(nil, var: "ENABLE_CDP_RAMP") { assert_not AppFlags.cdp_ramp? }
  end

  test "cdp_ramp? is true only for a 'true' value" do
    with_env("true", var: "ENABLE_CDP_RAMP")   { assert AppFlags.cdp_ramp? }
    with_env("TRUE", var: "ENABLE_CDP_RAMP")   { assert AppFlags.cdp_ramp? }
    with_env(" true ", var: "ENABLE_CDP_RAMP") { assert AppFlags.cdp_ramp? }
    with_env("false", var: "ENABLE_CDP_RAMP")  { assert_not AppFlags.cdp_ramp? }
    with_env("1", var: "ENABLE_CDP_RAMP")      { assert_not AppFlags.cdp_ramp? }
    with_env("", var: "ENABLE_CDP_RAMP")       { assert_not AppFlags.cdp_ramp? }
  end

  # qa_environment? delegates to the engine (Studio.qa_environment? →
  # EnvironmentBanner's allow-list), so every QA_ENV reader in the ecosystem
  # shares ONE truthiness — this used to pin a third, stricter vocabulary
  # ("true" only), which left '1' meaning QA to storage.yml and not-QA here.
  test "qa_environment? shares the engine's allow-list truthiness" do
    %w[1 true yes on TRUE].each do |value|
      with_env(value, var: "QA_ENV") { assert AppFlags.qa_environment?, "#{value.inspect} is allow-listed" }
    end
    with_env(" true ", var: "QA_ENV") { assert AppFlags.qa_environment? }
    [ nil, "", "false", "0", "no", "off", "banana" ].each do |value|
      with_env(value, var: "QA_ENV") { assert_not AppFlags.qa_environment?, "#{value.inspect} must fail safe to production" }
    end
  end

  # live_production? = Rails.env.production? AND NOT a QA app.
  #
  # The bug it fixes: a QA Heroku app sets no RAILS_ENV, so it boots as Rails
  # production, and the OPSEC-020 kill-switches asking Rails.env.production?
  # directly disarmed every dev-funding tool on QA — the faucet answered
  # "Faucet is production-disabled" to a devnet review app. QA_ENV is what
  # separates the two.
  def with_rails_env(name)
    Rails.stub(:env, ActiveSupport::StringInquirer.new(name)) { yield }
  end

  test "live_production? is false in the test environment regardless of QA_ENV" do
    with_env(nil, var: "QA_ENV")    { assert_not AppFlags.live_production? }
    with_env("true", var: "QA_ENV") { assert_not AppFlags.live_production? }
  end

  test "live_production? is TRUE on real production (QA_ENV unset)" do
    with_rails_env("production") do
      with_env(nil, var: "QA_ENV")     { assert AppFlags.live_production? }
      with_env("false", var: "QA_ENV") { assert AppFlags.live_production? }
      with_env("", var: "QA_ENV")      { assert AppFlags.live_production? }
    end
  end

  test "live_production? is FALSE on a QA app even though Rails.env is production" do
    with_rails_env("production") do
      with_env("true", var: "QA_ENV")   { assert_not AppFlags.live_production? }
      with_env("TRUE", var: "QA_ENV")   { assert_not AppFlags.live_production? }
      with_env(" true ", var: "QA_ENV") { assert_not AppFlags.live_production? }
    end
  end

  test "live_production? is false in development whatever QA_ENV says" do
    with_rails_env("development") do
      with_env(nil, var: "QA_ENV")    { assert_not AppFlags.live_production? }
      with_env("true", var: "QA_ENV") { assert_not AppFlags.live_production? }
    end
  end

  # ENABLE_WEB2_USDC_ENTRY is a KILL-SWITCH: ON unless explicitly "false".
  # Opposite default of the opt-in flags above.
  test "web2_usdc_entry? defaults ON when unset (kill-switch)" do
    with_env(nil, var: "ENABLE_WEB2_USDC_ENTRY") { assert AppFlags.web2_usdc_entry? }
  end

  test "web2_usdc_entry? is on for everything except a 'false' value" do
    with_env("false", var: "ENABLE_WEB2_USDC_ENTRY") { assert_not AppFlags.web2_usdc_entry? }
    with_env("FALSE", var: "ENABLE_WEB2_USDC_ENTRY") { assert_not AppFlags.web2_usdc_entry? }
    with_env(" false ", var: "ENABLE_WEB2_USDC_ENTRY") { assert_not AppFlags.web2_usdc_entry? }
    with_env("true", var: "ENABLE_WEB2_USDC_ENTRY")  { assert AppFlags.web2_usdc_entry? }
    with_env("1", var: "ENABLE_WEB2_USDC_ENTRY")     { assert AppFlags.web2_usdc_entry? }
    with_env("", var: "ENABLE_WEB2_USDC_ENTRY")      { assert AppFlags.web2_usdc_entry? }
  end

  # ENABLE_WEB3_ONLY_ONBOARDING became a KILL-SWITCH on 2026-08-15 (NFL 2026 is
  # web3-only), joining ENABLE_WEB2_USDC_ENTRY above. It was an opt-in through
  # the build-out, which is why a new signup still landed on the web2 entry-token
  # modal: the wallet step was written and dark. Read these two together — the
  # default is the season's behavior, and "false" is the one way back.
  test "web3_only_onboarding? defaults ON when unset (kill-switch)" do
    with_env(nil, var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert AppFlags.web3_only_onboarding? }
  end

  test "web3_only_onboarding? is on for everything except a 'false' value" do
    with_env("false",  var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert_not AppFlags.web3_only_onboarding? }
    with_env("FALSE",  var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert_not AppFlags.web3_only_onboarding? }
    with_env(" false ", var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert_not AppFlags.web3_only_onboarding? }
    with_env("true",   var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert AppFlags.web3_only_onboarding? }
    with_env("1",      var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert AppFlags.web3_only_onboarding? }
    with_env("",       var: "ENABLE_WEB3_ONLY_ONBOARDING") { assert AppFlags.web3_only_onboarding? }
  end
end
