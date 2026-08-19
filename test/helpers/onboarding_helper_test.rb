require "test_helper"

# The pool the first-name card samples its typed placeholder from.
class OnboardingHelperTest < ActionView::TestCase
  include OnboardingHelper

  test "every entry is a plain first name" do
    # FIRST names only — the field asks for one, so the worked example has to be
    # one. A full name slipping in ("Josh Allen") would type a two-word answer
    # into a field that then rejects the space, teaching the wrong thing.
    OnboardingHelper::QB_FIRST_NAMES.each do |name|
      assert_not_includes name, " ", "#{name.inspect} is not a single first name"
      assert name.present?, "blank entry in the list"
      assert name.length <= 40,
             "#{name.inspect} exceeds the field's maxlength, so it would type past what a user could enter"
    end
  end

  test "the pool is non-empty, because an empty one types nothing" do
    # The card falls back to 'Alex' on an empty pool rather than animating a
    # blank string, but an empty constant here would be a silent downgrade of
    # the whole feature — fail loudly instead.
    assert OnboardingHelper::QB_FIRST_NAMES.any?
    assert_equal OnboardingHelper::QB_FIRST_NAMES, first_name_placeholder_names
  end

  test "the list is frozen, so a sample can never mutate it" do
    assert OnboardingHelper::QB_FIRST_NAMES.frozen?
  end
end
