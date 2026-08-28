require "test_helper"

# The guard used to `raise` on a production boot carrying ENABLE_TEST_SCAFFOLDING,
# which made the $1 micro tier unreachable on production. The operator's call
# (2026-08-27) is that production must BOOT with the flag on — and still say so.
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

  def booting_as(env, scaffolding:, &block)
    Rails.stub :env, ActiveSupport::StringInquirer.new(env) do
      AppFlags.stub :test_scaffolding?, scaffolding, &block
    end
  end

  test "a production boot with the flag on succeeds instead of raising" do
    booting_as("production", scaffolding: true) do
      capturing_logs { assert_nothing_raised { load GUARD } }
    end
  end

  test "a production boot with the flag on logs the token-price exposure at error" do
    logs = booting_as("production", scaffolding: true) do
      capturing_logs { load GUARD }
    end

    assert_match(/ERROR/, logs)
    assert_match(/ENABLE_TEST_SCAFFOLDING is enabled in production/, logs)
    # The warning has to name the thing that actually costs money, not just the
    # flag: the $5 / 3-token pack prices an entry token at $1.67 against a $19 one.
    assert_match(/3-token pack/, logs)
    assert_match(/config:unset ENABLE_TEST_SCAFFOLDING/, logs)
  end

  test "a production boot with the flag off says nothing" do
    logs = booting_as("production", scaffolding: false) do
      capturing_logs { load GUARD }
    end

    assert_no_match(/ENABLE_TEST_SCAFFOLDING/, logs)
  end

  test "a non-production boot with the flag on says nothing" do
    logs = booting_as("development", scaffolding: true) do
      capturing_logs { load GUARD }
    end

    assert_no_match(/ENABLE_TEST_SCAFFOLDING/, logs)
  end
end
