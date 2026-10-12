# frozen_string_literal: true

require "test_helper"

# [unit] The signer-eviction form's two address lists stay out of the request
# log. Admin::AuthoritiesController#arm takes `signers[]` and `authorizers[]`.
# They are public keys, so this is tidy-up rather than a leak, but they are
# typed or pasted by an operator, and a secret pasted into the wrong box would
# otherwise be written to the log verbatim.
#
# CONTROL: drop `:signers` and `:authorizers` from
# config/initializers/filter_parameter_logging.rb and the first test fails with
# the raw keys in the filtered hash.
class FilterParameterLoggingTest < ActiveSupport::TestCase
  def filtered(params)
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
  end

  test "the eviction form's signers and authorizers are filtered" do
    keys = %w[9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin 4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T]
    out = filtered("signers" => keys, "authorizers" => keys.first(1), "commit" => "Arm")

    assert_equal "[FILTERED]", out["signers"]
    assert_equal "[FILTERED]", out["authorizers"]
    assert_equal "Arm", out["commit"], "an unrelated param still logs"
  end

  test "a param that only names a signer is not swept up" do
    out = filtered("lead_signer_row" => "2", "tx_type" => "update_signers")

    assert_equal "2", out["lead_signer_row"]
    assert_equal "update_signers", out["tx_type"], "a VALUE that says signers is not a key that does"
  end
end
