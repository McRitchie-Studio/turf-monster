require "test_helper"
require "minitest/mock"

# [unit] Live production refuses to boot with ENABLE_TEST_SCAFFOLDING on unless
# TEST_SCAFFOLDING_OVERRIDE names why; QA (Rails production plus QA_ENV),
# development and test keep the flag.
#
# These tests execute the initializer for real rather than grepping its source:
# `config.after_initialize` runs its block immediately once the app is already
# initialized, which it is by the time a test runs, so `load` is the boot.
class TestScaffoldingGuardTest < ActiveSupport::TestCase
  GUARD = Rails.root.join("config/initializers/test_scaffolding_guard.rb")

  # Swap in a logger we can read back, and restore whatever was there. The
  # formatter prefixes the severity because the default one drops it, and the
  # severity is load-bearing here: a warning demoted to :debug is filtered out
  # of production logs entirely, which is the same as having no warning.
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

  # Boots with the real predicates: Rails.env, QA_ENV, ENABLE_TEST_SCAFFOLDING
  # and TEST_SCAFFOLDING_OVERRIDE are each set (nil deletes) and restored.
  def booting_as(env, scaffolding:, qa: false, override: nil, &block)
    vars = {
      "ENABLE_TEST_SCAFFOLDING" => (scaffolding ? "true" : nil),
      "QA_ENV" => (qa ? "true" : nil),
      "TEST_SCAFFOLDING_OVERRIDE" => override
    }
    originals = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(env), &block)
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "a live-production boot with the flag on and no override raises" do
    error = nil
    booting_as("production", scaffolding: true) do
      capturing_logs { error = assert_raises(AppFlags::TestScaffoldingRefused) { load GUARD } }
    end

    assert_match(/ENABLE_TEST_SCAFFOLDING is set on live production/, error.message)
    assert_match(/TEST_SCAFFOLDING_OVERRIDE/, error.message)
  end

  test "a blank override is no override" do
    booting_as("production", scaffolding: true, override: "   ") do
      capturing_logs { assert_raises(AppFlags::TestScaffoldingRefused) { load GUARD } }
    end
  end

  test "a live-production boot with the flag on and an override boots and logs the reason at error" do
    logs = booting_as("production", scaffolding: true, override: "micro rehearsal") do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_match(/^ERROR /, logs)
    assert_match(/TEST_SCAFFOLDING_OVERRIDE="micro rehearsal"/, logs)
    # The warning names what costs money, not just the flag.
    assert_match(/3-token pack/, logs)
    assert_match(/config:unset ENABLE_TEST_SCAFFOLDING TEST_SCAFFOLDING_OVERRIDE/, logs)
  end

  test "a QA boot (production plus QA_ENV) with the flag on boots and says nothing" do
    logs = booting_as("production", scaffolding: true, qa: true) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_TEST_SCAFFOLDING/, logs)
  end

  test "a live-production boot with the flag off boots and says nothing" do
    logs = booting_as("production", scaffolding: false) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_TEST_SCAFFOLDING/, logs)
  end

  test "a development boot with the flag on boots and says nothing" do
    logs = booting_as("development", scaffolding: true) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end

    assert_no_match(/ENABLE_TEST_SCAFFOLDING/, logs)
  end
end
