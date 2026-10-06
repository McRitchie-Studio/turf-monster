require "test_helper"
require "minitest/mock"

# [integration] The five contest test actions (jump, simulate_game,
# simulate_batch, fill, reset) rewrite shared game scores, settle, mint comped
# entries or destroy entries. They answer only while ENABLE_TEST_SCAFFOLDING is
# on, and never on a contest holding an entry someone paid for on chain, whatever
# the flag says. A refusal is a flash and a redirect, never a 500.
class ContestTestActionsGateTest < ActionDispatch::IntegrationTest
  ACTIONS = {
    jump: ->(c) { Rails.application.routes.url_helpers.jump_contest_path(c) },
    simulate_game: ->(c) { Rails.application.routes.url_helpers.simulate_game_contest_path(c) },
    simulate_batch: ->(c) { Rails.application.routes.url_helpers.simulate_batch_contest_path(c, count: 5) },
    fill: ->(c) { Rails.application.routes.url_helpers.fill_contest_path(c) },
    reset: ->(c) { Rails.application.routes.url_helpers.reset_contest_path(c) }
  }.freeze

  setup do
    @contest = contests(:one)
    log_in_as(users(:alex)) # admin
  end

  # Everything a test action can change: the contest, its entries, its games.
  def snapshot
    @contest.reload
    [
      @contest.status,
      @contest.entries.order(:id).pluck(:id, :status, :score, :onchain_tx_signature),
      @contest.matchups.order(:id).pluck(:id, :goals, :status),
      Game.order(:id).pluck(:id, :home_score, :away_score, :status)
    ]
  end

  def assert_refused(action, message)
    before = snapshot
    post ACTIONS.fetch(action).call(@contest)

    assert_redirected_to contest_path(@contest), "#{action} must redirect, not render or raise"
    assert_equal message, flash[:alert], "#{action} must say why it refused"
    assert_equal before, snapshot, "#{action} must change nothing when it refuses"
  end

  ACTIONS.each_key do |action|
    test "#{action} is refused while test scaffolding is off" do
      AppFlags.stub :test_scaffolding?, false do
        assert_refused action, ContestsController::TEST_ACTIONS_OFF_MESSAGE
      end
    end

    test "#{action} passes the gate while test scaffolding is on and no entry is paid" do
      AppFlags.stub :test_scaffolding?, true do
        post ACTIONS.fetch(action).call(@contest)
      end

      assert_response :redirect
      assert_not_equal ContestsController::TEST_ACTIONS_OFF_MESSAGE, flash[:alert]
      assert_not_equal ContestsController::TEST_ACTIONS_PAID_MESSAGE, flash[:alert]
    end

    test "#{action} is refused on a contest with an entry paid on chain, even with the flag on" do
      entries(:one).update_columns(onchain_tx_signature: "paid-sig-#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, ContestsController::TEST_ACTIONS_PAID_MESSAGE
      end
    end

    test "#{action} is refused on a contest with an on-chain entry PDA, even with the flag on" do
      entries(:two).update_columns(onchain_entry_id: "EntryPda#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, ContestsController::TEST_ACTIONS_PAID_MESSAGE
      end
    end
  end

  # The allowed path really runs: jump settles, reset clears the entries.
  test "with the flag on, jump settles a free contest and reset clears it" do
    AppFlags.stub :test_scaffolding?, true do
      post jump_contest_path(@contest)
      assert_equal "settled", @contest.reload.status

      post reset_contest_path(@contest)
      assert_equal "open", @contest.reload.status
      assert_equal 0, @contest.entries.count
    end
  end

  # A paid entry that is no longer active (abandoned after its payment landed)
  # still holds real money; reset would destroy the only record of it.
  test "reset is refused when the only paid entry is abandoned" do
    entries(:one).update_columns(status: "abandoned", onchain_tx_signature: "stranded-paid-sig")

    AppFlags.stub :test_scaffolding?, true do
      assert_refused :reset, ContestsController::TEST_ACTIONS_PAID_MESSAGE
    end
  end

  test "a non-admin is still turned away before the flag is read" do
    log_in_as(users(:sam))

    AppFlags.stub :test_scaffolding?, true do
      assert_no_changes -> { snapshot } do
        post jump_contest_path(@contest)
      end
    end
    assert_response :redirect
    assert_not_equal ContestsController::TEST_ACTIONS_OFF_MESSAGE, flash[:alert]
  end
end
