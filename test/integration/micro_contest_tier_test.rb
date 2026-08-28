require "test_helper"

# End-to-end proof that the $1 micro tier reaches the admin create UI when
# ENABLE_TEST_SCAFFOLDING is on — the whole point of the flag, and the half the
# old hard boot guard made unreachable on production.
#
# The model test pins the numbers; this pins that an admin can actually SEE and
# SUBMIT them. Contest#new is admin-only (require_admin), so the tier is never
# offered to a player either way.
class MicroContestTierTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_current!(1)
    @admin = users(:alex)
  end

  test "the micro card renders on the create form when scaffolding is on" do
    log_in_as(@admin)

    AppFlags.stub :test_scaffolding?, true do
      get new_contest_path
    end

    assert_response :success
    assert_select "span", text: "micro"
    # $1.00 entry, and the $5/$2/$2 split the operator asked for.
    assert_match "$1.00 entry", response.body
    assert_match "$9.00", response.body
    assert_match "2nd: $2.00", response.body
    assert_match "3rd: $2.00", response.body
  end

  test "the micro card is absent when scaffolding is off" do
    log_in_as(@admin)

    AppFlags.stub :test_scaffolding?, false do
      get new_contest_path
    end

    assert_response :success
    assert_select "span", text: "micro", count: 0
    assert_match "$19.00 entry", response.body
  end

  test "create refuses a micro contest while scaffolding is off" do
    log_in_as(@admin)

    AppFlags.stub :test_scaffolding?, false do
      assert_no_difference -> { Contest.count } do
        post contests_path, params: { contest: { contest_type: "micro", slate_id: slates(:one).id } }
      end
    end
  end
end
