require "test_helper"

class QuestSeedFanoutTest < ActionDispatch::IntegrationTest
  test "seed fanout accepts a seed total snapshot without a fresh earned amount" do
    src = Rails.root.join("app/javascript/state_fanout.js").read

    assert_includes src, "const hasTotal = d.seeds_total !== undefined && d.seeds_total !== null;"
    assert_includes src, "Math.max(0, total - (cachedTotal === null ? total : cachedTotal))"
    refute_includes src, "reason: \"no seeds_earned\""
  end

  test "quest completion waits briefly for StateFanout after a fresh page navigation" do
    src = Rails.root.join("app/views/shared/_alpine_factories.html.erb").read

    assert_includes src, "window.applyStateFanoutWhenReady = function"
    assert_includes src, "window.seedFanoutPayloadPresent(payload)"
    assert_includes src, "window.applyStateFanoutWhenReady(\"seeds\", payload"
  end

  test "username saved fallback path uses the shared seed fanout retry helper" do
    # The engine leveling-modal adoption moved this beat into the
    # studio:username-saved listener in shared/_alpine_factories. Off the contest
    # page (/account) it must fan seeds out through the retry-aware helper, never a
    # raw StateFanout that would no-op before StateFanout loads.
    src = Rails.root.join("app/views/shared/_alpine_factories.html.erb").read

    assert_includes src, "window.applyStateFanoutWhenReady(\"seeds\", data, { source: \"quest-username\""
    refute_includes src, "data && data.seeds_earned && window.StateFanout"
  end
end
