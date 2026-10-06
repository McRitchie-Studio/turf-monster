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

  PAID = ContestsController::TEST_ACTION_REFUSALS.fetch(:paid)
  ONCHAIN = ContestsController::TEST_ACTION_REFUSALS.fetch(:onchain)
  SHARED = ContestsController::TEST_ACTION_REFUSALS.fetch(:shared_games)
  GAME_ACTIONS = %i[jump simulate_game simulate_batch reset].freeze

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
      assert_not_includes ContestsController::TEST_ACTION_REFUSALS.values, flash[:alert]
    end

    # A Phantom entry between broadcast and verification: the signature sits on
    # its PendingTransaction, and the Entry's own columns are still empty.
    test "#{action} is refused on a contest with an in-flight entry whose signature is only on its pending transaction" do
      entry = entries(:one)
      assert_nil entry.onchain_tx_signature
      assert_nil entry.onchain_entry_id
      PendingTransaction.create!(
        tx_type: "enter_contest", serialized_tx: "WIRE-#{SecureRandom.hex(4)}", status: "submitted",
        target: entry, tx_signature: "in-flight-sig-#{action}", initiator_address: "init", metadata: {}.to_json
      )

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, PAID
      end
    end

    test "#{action} is refused on an on-chain contest, even with no entries and the flag on" do
      @contest.entries.delete_all
      @contest.update_columns(onchain_contest_id: "ContestPda#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, ONCHAIN
      end
    end

    test "#{action} is refused on a contest with an entry paid on chain, even with the flag on" do
      entries(:one).update_columns(onchain_tx_signature: "paid-sig-#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, PAID
      end
    end

    test "#{action} is refused on a contest with an on-chain entry PDA, even with the flag on" do
      entries(:two).update_columns(onchain_entry_id: "EntryPda#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, PAID
      end
    end
  end

  # A sibling on the same slate reads the same matchups and games rows.
  GAME_ACTIONS.each do |action|
    test "#{action} is refused on a free contest sharing its slate with a paid contest" do
      sibling = Contest.create!(name: "Paid sibling #{action.to_s.tr("_", " ")}", slate: @contest.slate, status: :open, starts_at: 2.days.from_now)
      paid = sibling.entries.create!(user: users(:jordan))
      paid.update_columns(status: "active", onchain_tx_signature: "sibling-paid-#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, SHARED
      end
    end

    test "#{action} is refused on a free contest sharing a game with a paid contest on another slate" do
      game = games(:future_game)
      slate_matchups(:m1).update_columns(game_slug: game.slug)
      other_slate = Slate.create!(name: "Other Slate #{action.to_s.tr("_", " ")}", sport: "fifa", starts_at: 30.days.from_now)
      SlateMatchup.create!(slate: other_slate, team_slug: game.home_team_slug, opponent_team_slug: game.away_team_slug,
                           game_slug: game.slug, rank: 1, status: "pending")
      sibling = Contest.create!(name: "Cross-slate sibling #{action.to_s.tr("_", " ")}", slate: other_slate, status: :open, starts_at: 2.days.from_now)
      paid = sibling.entries.create!(user: users(:jordan))
      paid.update_columns(status: "active", onchain_entry_id: "SiblingPda#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, SHARED
      end
    end

    test "#{action} is refused on a free contest sharing its slate with an on-chain contest" do
      Contest.create!(name: "On-chain sibling #{action.to_s.tr("_", " ")}", slate: @contest.slate, status: :open, starts_at: 2.days.from_now)
             .update_columns(onchain_contest_id: "SiblingContestPda#{action}")

      AppFlags.stub :test_scaffolding?, true do
        assert_refused action, SHARED
      end
    end
  end

  # fill writes only its own contest's entries, so a paid sibling does not stop it.
  test "fill passes the gate on a free contest whose slate sibling is paid" do
    sibling = Contest.create!(name: "Paid sibling fill", slate: @contest.slate, status: :open, starts_at: 2.days.from_now)
    sibling.entries.create!(user: users(:jordan)).update_columns(status: "active", onchain_tx_signature: "sibling-fill")

    AppFlags.stub :test_scaffolding?, true do
      post fill_contest_path(@contest)
    end
    assert_not_includes ContestsController::TEST_ACTION_REFUSALS.values, flash[:alert]
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
      assert_refused :reset, PAID
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
