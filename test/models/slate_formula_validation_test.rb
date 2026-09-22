require "test_helper"

# [unit] The validation message is rendered directly in both formula-save
# toasts. Its attribute name must match the field label the operator sees.
class SlateFormulaValidationTest < ActiveSupport::TestCase
  test "multiplier scale validation uses the admin field label" do
    slate = Slate.new(name: "NFL 2026 Week 4", formula_mult_scale: -0.1)

    assert_not slate.valid?
    assert_equal ["Scale must be greater than or equal to 0"], slate.errors.full_messages
  end
end
