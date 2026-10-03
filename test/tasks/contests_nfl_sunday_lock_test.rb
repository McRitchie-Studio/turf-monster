require "test_helper"
require "rake"

# [integration] contests:nfl_sunday_lock / Contests::ApplyNflSundayLock — the
# one-off that moves open NFL contests from the old lock (first kickoff, a
# Thursday on a TNF week) to the opening-Sunday lock, chain first, then DB.
#
# The chain is a fake that keeps lock_timestamp per slug, so each test can say
# what the chain holds and read what was sent to it. Week 4, 2026: TNF Thursday
# 2026-10-02 00:15Z, Sunday lock 2026-10-04 17:00Z.
class ContestsNflSundayLockTaskTest < ActiveSupport::TestCase
  TNF    = Time.utc(2026, 10, 2, 0, 15)
  SUNDAY = Time.utc(2026, 10, 4, 17, 0)
  BEFORE_TNF = Time.utc(2026, 10, 1, 12, 0)

  class FakeChain
    attr_reader :locks, :sets
    attr_accessor :unreadable, :refuse_set, :ignore_set

    def initialize = (@locks = {}; @sets = [])

    def read_contest(slug)
      raise "rpc down" if unreadable

      @locks.key?(slug) ? { lock_timestamp: @locks[slug] } : nil
    end

    def set_contest_lock_time(slug, ts)
      raise Solana::Vault::ThresholdUnreachableError, "needs 2 vault signatures" if refuse_set

      @sets << [slug, ts]
      @locks[slug] = ts unless ignore_set
      { signature: "sig-#{@sets.size}" }
    end
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("contests:nfl_sunday_lock")
    @chain = FakeChain.new
    @slate = Slate.create!(name: "NFL 2026 Week 4 #{SecureRandom.hex(2)}", week: 4)
    { %w[team-a team-b] => TNF, %w[team-c team-d] => SUNDAY }.each do |(home, away), kickoff|
      game = Game.create!(home_team_slug: home, away_team_slug: away, kickoff_at: kickoff, status: "scheduled")
      [[home, away], [away, home]].each do |team, opponent|
        SlateMatchup.create!(slate: @slate, team_slug: team, opponent_team_slug: opponent, game_slug: game.slug,
                             rank: 1, turf_score: 1.0, status: "pending")
      end
    end
    @contest = onchain_contest!(starts_at: TNF) # created under the old default
  end

  teardown { %w[WRITE SLUGS].each { |key| ENV.delete(key) } }

  def onchain_contest!(starts_at:, chain_lock: starts_at, slate: @slate)
    contest = Contest.create!(name: "NFL #{SecureRandom.hex(3)}", slate: slate, rank: 8000 + rand(900),
                              contest_type: "standard", user: users(:alex), status: "open", max_entries: 29,
                              starts_at: starts_at, onchain_contest_id: "pda-#{SecureRandom.hex(3)}")
    @chain.locks[contest.slug] = chain_lock.to_i
    contest
  end

  def apply_lock(write: false, now: BEFORE_TNF, slugs: nil)
    rows = nil
    out = StringIO.new
    travel_to(now) do
      rows = Contests::ApplyNflSundayLock.new(write: write, slugs: slugs || [@contest.slug], vault: @chain, out: out).call
    end
    [rows, out.string]
  end

  def row_for(rows, contest) = rows.find { |row| row.slug == contest.slug }

  test "dry run by default: plans the move, writes nothing, prints the unix timestamp" do
    rows, out = apply_lock

    assert_equal :move, row_for(rows, @contest).action
    assert_match(/DRY RUN/, out)
    assert_includes out, SUNDAY.to_i.to_s
    assert_empty @chain.sets
    assert_equal TNF, @contest.reload.starts_at
  end

  test "write moves the chain first, then mirrors starts_at, and a second run is a noop" do
    rows, = apply_lock(write: true)

    assert_equal :moved, row_for(rows, @contest).action
    assert_equal [[@contest.slug, SUNDAY.to_i]], @chain.sets
    assert_equal SUNDAY, @contest.reload.starts_at
    assert_equal SUNDAY, @contest.locks_at

    rows, = apply_lock(write: true)
    assert_equal :noop, row_for(rows, @contest).action
    assert_equal 1, @chain.sets.size, "idempotent: no second chain write"
  end

  test "refuses a contest whose lock has already passed (the Weeks 4-6 case) — never reopens" do
    rows, = apply_lock(write: true, now: TNF + 1.hour)

    row = row_for(rows, @contest)
    assert_equal :refuse, row.action
    assert_match(/already passed/, row.reason)
    assert_empty @chain.sets
    assert_equal TNF, @contest.reload.starts_at
  end

  test "refuses when the CHAIN lock has passed even though the DB says it has not" do
    @chain.locks[@contest.slug] = (BEFORE_TNF - 1.hour).to_i

    rows, = apply_lock(write: true)

    assert_equal :refuse, row_for(rows, @contest).action
    assert_empty @chain.sets
  end

  test "refuses when the new lock would not be in the future" do
    # A slate whose Sunday lock already passed while its stored lock is later.
    late = onchain_contest!(starts_at: Time.utc(2026, 10, 5, 0, 20), chain_lock: Time.utc(2026, 10, 5, 0, 20))
    rows, = apply_lock(write: true, now: Time.utc(2026, 10, 4, 20, 0), slugs: [late.slug])

    assert_equal :refuse, row_for(rows, late).action
    assert_empty @chain.sets
  end

  test "skips a custom lock: only the old first-kickoff default is moved" do
    custom = onchain_contest!(starts_at: Time.utc(2026, 10, 3, 18, 0))

    rows, = apply_lock(write: true, slugs: [custom.slug])

    assert_equal :skip, row_for(rows, custom).action
    assert_match(/custom lock/, row_for(rows, custom).reason)
    assert_empty @chain.sets
  end

  test "fails closed when the chain cannot be read" do
    @chain.unreadable = true

    rows, = apply_lock(write: true)

    assert_equal :refuse, row_for(rows, @contest).action
    assert_match(/unreadable/, row_for(rows, @contest).reason)
    assert_equal TNF, @contest.reload.starts_at
  end

  test "a governance threshold refusal is reported and leaves the DB at the old lock" do
    @chain.refuse_set = true

    rows, = apply_lock(write: true)

    assert_equal :error, row_for(rows, @contest).action
    assert_match(/ThresholdUnreachable/, row_for(rows, @contest).reason)
    assert_equal TNF, @contest.reload.starts_at
  end

  test "a chain write that does not land leaves the DB at the old lock" do
    @chain.ignore_set = true

    rows, = apply_lock(write: true)

    assert_equal :error, row_for(rows, @contest).action
    assert_equal TNF, @contest.reload.starts_at
  end

  test "mirrors the DB when the chain already holds the new lock" do
    @chain.locks[@contest.slug] = SUNDAY.to_i

    rows, = apply_lock(write: true)

    assert_equal :mirrored, row_for(rows, @contest).action
    assert_empty @chain.sets
    assert_equal SUNDAY, @contest.reload.starts_at
  end

  test "ignores non-NFL contests" do
    wc = contests(:one)

    rows, = apply_lock(write: true, slugs: [wc.slug, @contest.slug])

    assert_nil row_for(rows, wc)
    assert row_for(rows, @contest)
  end

  test "the rake task is a dry run unless WRITE=1" do
    ENV["SLUGS"] = @contest.slug
    task = Rake::Task["contests:nfl_sunday_lock"]

    out = travel_to(BEFORE_TNF) do
      Solana::Vault.stub(:new, @chain) { task.reenable; capture_io { task.invoke }.first }
    end
    assert_match(/DRY RUN/, out)
    assert_empty @chain.sets

    ENV["WRITE"] = "1"
    travel_to(BEFORE_TNF) do
      Solana::Vault.stub(:new, @chain) { task.reenable; capture_io { task.invoke } }
    end
    assert_equal [[@contest.slug, SUNDAY.to_i]], @chain.sets
    assert_equal SUNDAY, @contest.reload.starts_at
  end
end
