require "test_helper"

# [unit] Api::V1::ContestFacts answers slate questions for a page of contests in
# two grouped queries instead of asking each Contest. That is only safe while it
# gives the model's answers, so every test here asks both and compares.
class Api::V1::ContestFactsTest < ActiveSupport::TestCase
  include SpanContestBuilder
  include AgentApiTestSupport

  setup { @contest = contests(:one) }

  def facts_for(contest)
    Api::V1::ContestFacts.for([Contest.includes(:slate).find(contest.id)])
  end

  def assert_agrees_with_model(contest, label)
    contest = Contest.find(contest.id)
    facts = facts_for(contest)

    assert_equal contest.picks_required, facts.picks_required(contest), "#{label}: picks_required"
    assert_equal contest.multi_week?, facts.multi_week?(contest), "#{label}: multi_week?"
    assert_equal contest.weeks_count, facts.games_per_team(contest), "#{label}: games per team"
    assert_equal contest.locks_at.to_i, facts.locks_at(contest).to_i, "#{label}: locks_at"
    assert_equal contest.locks_at.nil?, facts.locks_at(contest).nil?, "#{label}: locks_at presence"
    assert_equal contest.locked?, facts.locked?(contest), "#{label}: locked?"
    assert_equal contest.live?, facts.live?(contest), "#{label}: live?"
  end

  test "agrees with the model on a single-week slate" do
    assert_agrees_with_model(@contest, "single week")
    assert_equal 6, facts_for(@contest).picks_required(@contest)
    assert_equal "open", facts_for(@contest).phase(@contest)
  end

  test "agrees with the model on a span slate, and still asks for six picks" do
    build_span_contest!(@contest)

    assert_agrees_with_model(@contest, "span")
    assert facts_for(@contest).multi_week?(@contest)
    assert_equal 2, facts_for(@contest).games_per_team(@contest)
    assert_equal 6, facts_for(@contest).picks_required(@contest)
  end

  test "agrees with the model on a span slate where one team has a bye" do
    build_span_contest!(@contest)
    span_row(@contest, "team-a", week: 2).destroy!

    assert_agrees_with_model(@contest, "span with a bye")
  end

  test "agrees with the model on a slate smaller than six and on an empty one" do
    small = Slate.create!(name: "Small #{SecureRandom.hex(3)}")
    %w[team-a team-b team-c].each { |team| SlateMatchup.create!(slate: small, team_slug: team, status: "pending") }
    @contest.update!(slate: small)
    assert_agrees_with_model(@contest, "three-row slate")
    assert_equal 3, facts_for(@contest).picks_required(@contest)

    @contest.update!(slate: Slate.create!(name: "Empty #{SecureRandom.hex(3)}"))
    assert_agrees_with_model(@contest, "empty slate")
    assert_equal 6, facts_for(@contest).picks_required(@contest)
  end

  # A pick is a TEAM. A span slate with fewer than six teams has more ROWS than
  # teams, and counting rows asked for picks nobody could make.
  test "agrees with the model on a span slate with fewer than six teams: one pick per team" do
    build_span_contest!(@contest)
    @contest.slate.slate_matchups.where(team_slug: %w[team-e team-f]).destroy_all
    assert_equal [8, 4], [@contest.matchups.count, @contest.pickable_matchup_ids.size]

    assert_agrees_with_model(@contest, "four-team span")
    assert_equal 4, Contest.find(@contest.id).picks_required
    assert_equal 4, facts_for(@contest).picks_required(@contest)
  end

  # No shape that exists today changes its number: rows and teams differ only
  # on a span, and a span of six or more teams is capped at six either way.
  test "picks_required is unchanged for every shape counted by rows before" do
    assert_equal 6, Contest.find(@contest.id).picks_required, "single week, six teams"

    extra_matchups
    assert_equal 6, Contest.find(@contest.id).picks_required, "single week, eight teams"

    build_span_contest!(@contest)
    assert_equal 6, Contest.find(@contest.id).picks_required, "span, six teams"
    span_row(@contest, "team-a", week: 2).destroy!
    assert_equal 6, Contest.find(@contest.id).picks_required, "span with a bye"
  end

  # The clock is pinned in both lock tests below. The NFL lock is a weekday rule
  # (Contest::LockRule), so a kickoff placed relative to the real clock lands on
  # a different side of the opening Sunday depending on when the suite runs: a
  # "2.days.from_now" kickoff read on a Saturday night is a Monday game, whose
  # opening Sunday is six days later.
  test "with no starts_at a non-NFL slate locks at its first kickoff, as the model says" do
    travel_to Time.utc(2026, 9, 30, 18, 0) # Wednesday
    kickoff = Time.utc(2026, 10, 2, 18, 0) # Friday
    build_span_contest!(@contest, week_one_kickoff: kickoff)
    @contest.slate.update!(sport: "fifa")
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "no starts_at, future kickoff, non-NFL")
    assert_equal kickoff, facts_for(@contest).locks_at(@contest)
    assert_equal "open", facts_for(@contest).phase(@contest)
  end

  test "with no starts_at an NFL slate locks at 11:00 Denver on its opening Sunday, as the model says" do
    travel_to Time.utc(2026, 9, 30, 18, 0) # Wednesday
    build_span_contest!(@contest, week_one_kickoff: Time.utc(2026, 10, 2, 18, 0)) # Friday
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "no starts_at, future kickoff, NFL")
    assert_equal Time.utc(2026, 10, 4, 17, 0), facts_for(@contest).locks_at(@contest) # Sunday 11:00 MDT
    assert_equal "open", facts_for(@contest).phase(@contest)
  end

  test "with no starts_at and no kickoff the lock is the slate's own start" do
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "no starts_at, no games")
    assert_equal slates(:one).starts_at.to_i, facts_for(@contest).locks_at(@contest).to_i
  end

  # The span builder names its slates "NFL ...", so the derived lock is the
  # opening-Sunday rule (Contest::LockRule), not the first kickoff itself.
  test "a passed NFL Sunday lock with no starts_at reads locked and live" do
    travel_to Time.utc(2026, 10, 4, 18, 0) # Sunday, an hour after 11:00 Denver
    build_span_contest!(@contest, week_one_kickoff: 1.hour.ago)
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "kicked off")
    assert_equal "live", facts_for(@contest).phase(@contest)
  end

  test "an NFL Thursday kickoff with no starts_at still reads open until the Sunday lock" do
    travel_to Time.utc(2026, 10, 2, 18, 0) # Friday, after TNF
    build_span_contest!(@contest, week_one_kickoff: Time.utc(2026, 10, 2, 0, 15))
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "TNF kicked off")
    assert_equal Time.utc(2026, 10, 4, 17, 0), facts_for(@contest).locks_at(@contest)
    assert_equal "open", facts_for(@contest).phase(@contest)
  end

  test "a passed starts_at reads live, and a settled contest reads locked but not live" do
    @contest.update!(starts_at: 1.hour.ago)
    assert_agrees_with_model(@contest, "locked")
    assert_equal "live", facts_for(@contest).phase(@contest)

    @contest.update!(status: :settled)
    assert_agrees_with_model(@contest, "settled")
    assert_equal "settled", facts_for(@contest).phase(@contest)
    assert_not facts_for(@contest).live?(@contest)
  end

  test "agrees with the model on a retired-format contest with no slate" do
    @contest.update!(starts_at: nil)
    write_retired_format!(@contest)

    assert_agrees_with_model(@contest, "retired format")
    assert_equal 0, facts_for(@contest).picks_required(@contest)
    assert_nil facts_for(@contest).locks_at(@contest)
  end

  test "a page of contests costs the same two queries as one contest" do
    others = 4.times.map do |i|
      slate = Slate.create!(name: "Slate #{i} #{SecureRandom.hex(3)}")
      SlateMatchup.create!(slate: slate, team_slug: "team-a", status: "pending")
      Contest.create!(name: "Extra #{i}", slate: slate, status: :open, starts_at: nil)
    end
    page = Contest.includes(:slate).where(id: [@contest.id] + others.map(&:id)).to_a

    queries = count_queries do
      facts = Api::V1::ContestFacts.for(page)
      page.each do |contest|
        facts.picks_required(contest)
        facts.phase(contest)
        facts.multi_week?(contest)
      end
    end

    assert_equal 2, queries
  end
end
