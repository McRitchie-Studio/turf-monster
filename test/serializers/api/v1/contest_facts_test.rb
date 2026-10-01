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
    assert_equal contest.locks_at&.to_i, facts.locks_at(contest)&.to_i, "#{label}: locks_at"
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

  test "with no starts_at the lock is the slate's first kickoff, as the model says" do
    build_span_contest!(@contest, week_one_kickoff: 2.days.from_now)
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "no starts_at, future kickoff")
    assert_in_delta 2.days.from_now.to_i, facts_for(@contest).locks_at(@contest).to_i, 5
    assert_equal "open", facts_for(@contest).phase(@contest)
  end

  test "with no starts_at and no kickoff the lock is the slate's own start" do
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "no starts_at, no games")
    assert_equal slates(:one).starts_at.to_i, facts_for(@contest).locks_at(@contest).to_i
  end

  test "a first kickoff in the past with no starts_at reads locked and live" do
    build_span_contest!(@contest, week_one_kickoff: 1.hour.ago)
    @contest.update!(starts_at: nil)

    assert_agrees_with_model(@contest, "kicked off")
    assert_equal "live", facts_for(@contest).phase(@contest)
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

  test "agrees with the model on a survivor contest with no slate" do
    @contest.update!(game_type: :world_cup_survivor, slate: nil, starts_at: nil)

    assert_agrees_with_model(@contest, "survivor")
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
