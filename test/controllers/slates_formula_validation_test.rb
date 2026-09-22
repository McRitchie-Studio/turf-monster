require "test_helper"

# [integration] REGRESSION — an out-of-range Scale is operator input, not an
# application fault. Both formula save actions used update!, so Slate's bound
# raised ActiveRecord::RecordInvalid inside rescue_and_log. The admin still saw
# a redirect, but the exception wrapper also wrote an ErrorLog row and exposed
# the model's internal attribute name as "Formula mult scale" in the toast.
class SlatesFormulaValidationTest < ActionDispatch::IntegrationTest
  setup do
    @slate = slates(:one)
    @default_slate = Slate.create!(name: "Default")
    log_in_as(users(:alex))
  end

  test "a slate scale typo is refused without an application-fault row" do
    assert_no_difference "ErrorLog.count" do
      patch update_formula_slate_path(@slate), params: { formula_mult_scale: -0.1 }
    end

    assert_redirected_to slate_path(@slate)
    assert_equal "Scale must be greater than or equal to 0", flash[:alert]
    assert_nil @slate.reload.formula_mult_scale
  end

  test "a default scale typo is refused without an application-fault row" do
    assert_no_difference "ErrorLog.count" do
      patch update_admin_formula_slates_path, params: { formula_mult_scale: 10.1 }
    end

    assert_redirected_to admin_formula_slates_path
    assert_equal "Scale must be less than or equal to 10.0", flash[:alert]
    assert_nil @default_slate.reload.formula_mult_scale
  end
end
