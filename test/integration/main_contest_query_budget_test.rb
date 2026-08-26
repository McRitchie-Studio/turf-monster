require "test_helper"

# [integration] What one authenticated page render costs in SeasonConfig lookups.
#
# THE CLAIM ONLY A REAL REQUEST CAN MAKE. The memo itself is a property of the
# method and is measured at the method (test/helpers/main_contest_target_test.rb).
# What that test cannot see is HOW MANY CARDS the layout actually renders on one
# page — and that is the whole defect: layouts/application registers the modal
# cards inside `<template x-if>` blocks, and ERB inside a `<template>` renders
# SERVER-SIDE unconditionally. The gate never runs on the server. So every card
# that resolved SeasonConfig.main_contest inline resolved it on EVERY
# authenticated page, whether or not its modal was ever opened.
#
# WHY IT COUNTS SQL RATHER THAN METHOD CALLS. SeasonConfig.main_contest reaches
# SeasonConfig.current, a `find_or_create_by` — normally a SELECT on
# season_configs, but a code path that can INSERT, and a view render is the wrong
# place to have one at all. The season_configs round-trip IS the cost, so it is
# what gets counted; counting method calls instead would miss a future caller
# that reached SeasonConfig.current by another name.
class MainContestQueryBudgetTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
    # The layout's cards only resolve a target when there IS one to resolve, and
    # a page that resolves nothing cannot prove a budget.
    @contest = Contest.where(status: :open).order(created_at: :desc).first
    assert @contest, "fixtures must carry an open contest for this budget to mean anything"
    SeasonConfig.set_main_contest!(@contest)
  end

  def season_config_queries
    queries = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].to_s.include?("season_configs")
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # ONE RENDER, ONE LOOKUP. /account is the page to measure it on: its controller
  # resolves no contest of its own any more (the @referral_share_contest ivar was
  # retired when the referral card started resolving its own default), so every
  # SeasonConfig lookup on this request is a VIEW lookup — the referral card, the
  # age gate, the username card, the quest card, the gear sidebar. They share a
  # view context, so they share the memo's ivar, so they share one query.
  #
  # Revert any one caller to a raw SeasonConfig.main_contest and this counts 2.
  test "an authenticated page render resolves the main contest exactly once" do
    log_in_as(@user)

    queries = season_config_queries { get account_path }
    assert_response :success

    assert_equal 1, queries.size,
                 "one page render made #{queries.size} season_configs queries — a card is " \
                 "calling SeasonConfig.main_contest inline instead of main_contest_target:\n" \
                 "#{queries.join("\n")}"
  end

  # THE INSERT IS THE REASON THE BUDGET IS ONE AND NOT "A FEW". SeasonConfig.current
  # is find_or_create_by, so the first caller on a fresh deploy WRITES. A render
  # is the wrong place for that at any count, and the memo is what keeps it to
  # the one it cannot avoid.
  test "the render never writes a SeasonConfig row" do
    SeasonConfig.set_main_contest!(@contest) # the row exists before the request
    log_in_as(@user)

    queries = season_config_queries { get account_path }
    assert_response :success

    writes = queries.grep(/INSERT|UPDATE/i)
    assert_empty writes, "a view render wrote to season_configs: #{writes.join("\n")}"
  end
end
