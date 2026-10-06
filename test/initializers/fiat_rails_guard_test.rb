require "test_helper"
require "minitest/mock"

# [unit] Live production refuses to boot with ENABLE_FIAT_RAILS on unless
# FIAT_RAILS_OVERRIDE names why; QA (Rails production plus QA_ENV),
# development and test may run the flag.
#
# These tests execute the initializer for real: `config.after_initialize` runs
# its block at once when the app is already initialized, so `load` is the boot.
class FiatRailsGuardTest < ActiveSupport::TestCase
  GUARD = Rails.root.join("config/initializers/fiat_rails_guard.rb")

  def capturing_logs
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    Rails.logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
    yield
    buffer.string
  ensure
    Rails.logger = original
  end

  # Boots with the real predicates: Rails.env, QA_ENV, ENABLE_FIAT_RAILS and
  # FIAT_RAILS_OVERRIDE are each set (nil deletes) and restored.
  def booting_as(env, fiat:, qa: false, override: nil, &block)
    vars = {
      "ENABLE_FIAT_RAILS" => (fiat ? "true" : nil),
      "QA_ENV" => (qa ? "true" : nil),
      "FIAT_RAILS_OVERRIDE" => override
    }
    originals = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(env), &block)
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "unit a live-production boot with the flag on and no override raises" do
    error = nil
    booting_as("production", fiat: true) do
      capturing_logs { error = assert_raises(AppFlags::FiatRailsRefused) { load GUARD } }
    end

    assert_match(/ENABLE_FIAT_RAILS is set on live production/, error.message)
    assert_match(/FIAT_RAILS_OVERRIDE/, error.message)
  end

  test "unit a blank override is no override" do
    booting_as("production", fiat: true, override: "   ") do
      capturing_logs { assert_raises(AppFlags::FiatRailsRefused) { load GUARD } }
    end
  end

  test "unit a live-production boot with the flag on and an override boots and logs the reason at error" do
    logs = booting_as("production", fiat: true, override: "Coinflow relaunch, season 2") do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_match(/^ERROR /, logs)
    assert_match(/FIAT_RAILS_OVERRIDE="Coinflow relaunch, season 2"/, logs)
  end

  test "unit control: a live-production boot with the flag off boots and says nothing" do
    logs = booting_as("production", fiat: false) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_FIAT_RAILS/, logs)
  end

  test "unit a QA boot (production plus QA_ENV) with the flag on boots and says nothing" do
    logs = booting_as("production", fiat: true, qa: true) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_FIAT_RAILS/, logs)
  end

  test "unit a development boot with the flag on boots and says nothing" do
    logs = booting_as("development", fiat: true) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_FIAT_RAILS/, logs)
  end
end
