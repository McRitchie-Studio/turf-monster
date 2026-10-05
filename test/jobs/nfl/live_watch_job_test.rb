# frozen_string_literal: true

require "test_helper"

# [integration] The tight loop: when it starts, that only one runs, that it
# keeps itself going while a game is on, and that it lets go when none is.
#
# What a cycle DOES is PollCycle's business and is stubbed here. The cache is a
# real MemoryStore, because the lease is the whole mechanism and the test
# environment's null store would answer every question about it with nil.
class NflLiveWatchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    teams(:team_b).update!(league: "nfl", sport: "football")
    @cycles = 0
  end

  def with_loop(env: {})
    quiet = Nfl::LiveScores::PollCycle::Result.new(slot: nil, games_seen: 0, changes: [], anomalies: [])
    saved = env.keys.to_h { |key| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }

    Rails.stub(:cache, @cache) do
      Nfl::LiveScores::PollCycle.stub(:call, -> { @cycles += 1; quiet }) { yield }
    end
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  def game(status:, kickoff_at:)
    Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", status: status, kickoff_at: kickoff_at)
  end

  def lease = @cache.read(Nfl::LiveWatchJob::LEASE_KEY)

  test "nothing to watch starts nothing" do
    game(status: "scheduled", kickoff_at: 3.days.from_now)

    with_loop do
      assert_no_enqueued_jobs { assert_not Nfl::LiveWatchJob.ensure_running }
    end
    assert_nil lease
  end

  test "a game in progress starts one chain, twenty seconds out" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop do
      assert_enqueued_with(job: Nfl::LiveWatchJob) { assert Nfl::LiveWatchJob.ensure_running }
      assert_equal 20.seconds, Nfl::LiveWatchJob.interval
    end
    assert_predicate lease, :present?
  end

  test "a kickoff ten minutes away is worth watching; one an hour away is not" do
    with_loop do
      soon = game(status: "scheduled", kickoff_at: 9.minutes.from_now)
      assert Nfl::LiveWatchJob.watching?

      soon.update!(kickoff_at: 1.hour.from_now)
      assert_not Nfl::LiveWatchJob.watching?
    end
  end

  # A postponed game sits at "scheduled" with a kickoff in the past for good.
  test "a game long past its kickoff and never started does not hold the loop open" do
    with_loop do
      late = game(status: "scheduled", kickoff_at: 30.minutes.ago)
      assert Nfl::LiveWatchJob.watching?, "between a kickoff and the poll that sees it, the game is still ours to watch"

      late.update!(kickoff_at: 5.hours.ago)
      assert_not Nfl::LiveWatchJob.watching?
    end
  end

  test "a second start while a chain is running does nothing" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop do
      assert Nfl::LiveWatchJob.ensure_running
      held = lease

      assert_no_enqueued_jobs { assert_not Nfl::LiveWatchJob.ensure_running }
      assert_equal held, lease
    end
  end

  test "a tick polls once, keeps the lease and enqueues the next" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop do
      Nfl::LiveWatchJob.ensure_running
      token = lease

      assert_enqueued_with(job: Nfl::LiveWatchJob, args: [token]) do
        Nfl::LiveWatchJob.perform_now(token)
      end
      assert_equal token, lease
    end
    assert_equal 1, @cycles
  end

  test "the last whistle ends the chain and frees the lease" do
    live = game(status: "in_progress", kickoff_at: 3.hours.ago)

    with_loop do
      Nfl::LiveWatchJob.ensure_running
      token = lease
      live.update!(status: "completed")

      assert_no_enqueued_jobs(only: Nfl::LiveWatchJob) { Nfl::LiveWatchJob.perform_now(token) }
    end
    assert_equal 1, @cycles, "the tick that sees the final still polls — that is how the final arrives"
    assert_nil lease
  end

  # A chain that lapsed and was replaced must not come back as a second one.
  test "a tick holding a stale token neither polls nor continues" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop do
      Nfl::LiveWatchJob.ensure_running

      assert_no_enqueued_jobs(only: Nfl::LiveWatchJob) { Nfl::LiveWatchJob.perform_now("not-the-token") }
    end
    assert_equal 0, @cycles
    assert_predicate lease, :present?
  end

  test "a bad minute at the feed does not break the chain" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    Rails.stub(:cache, @cache) do
      Nfl::LiveWatchJob.ensure_running
      token = lease

      Nfl::LiveScores::PollCycle.stub(:call, -> { raise Nfl::Espn::Client::Error, "503 from ESPN" }) do
        assert_enqueued_with(job: Nfl::LiveWatchJob, args: [token]) { Nfl::LiveWatchJob.perform_now(token) }
      end
    end
  end

  test "the switch stops new chains and ends a running one" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop { Nfl::LiveWatchJob.ensure_running }
    token = lease

    with_loop(env: { "NFL_LIVE_WATCH" => "off" }) do
      assert_not Nfl::LiveWatchJob.ensure_running
      assert_no_enqueued_jobs(only: Nfl::LiveWatchJob) { Nfl::LiveWatchJob.perform_now(token) }
    end
    assert_equal 0, @cycles
    assert_nil lease
  end

  test "the interval can be set, but never below ten seconds" do
    with_loop(env: { "NFL_LIVE_WATCH_SECONDS" => "45" }) { assert_equal 45.seconds, Nfl::LiveWatchJob.interval }
    with_loop(env: { "NFL_LIVE_WATCH_SECONDS" => "1" })  { assert_equal 10.seconds, Nfl::LiveWatchJob.interval }
    with_loop(env: { "NFL_LIVE_WATCH_SECONDS" => "x" })  { assert_equal 20.seconds, Nfl::LiveWatchJob.interval }
  end

  # ── the handover from the five-minute floor ──────────────────────────────

  test "the floor starts the tight loop after its own cycle" do
    game(status: "in_progress", kickoff_at: 1.hour.ago)

    with_loop do
      assert_enqueued_with(job: Nfl::LiveWatchJob) { Nfl::LivePollJob.perform_now }
    end
    assert_equal 1, @cycles
  end

  test "a tight loop that cannot start does not fail the floor" do
    quiet = Nfl::LiveScores::PollCycle::Result.new(slot: nil, games_seen: 0, changes: [], anomalies: [])

    Nfl::LiveScores::PollCycle.stub(:call, -> { quiet }) do
      Nfl::LiveWatchJob.stub(:ensure_running, -> { raise "redis is down" }) do
        assert_equal quiet, Nfl::LivePollJob.perform_now
      end
    end
  end
end
