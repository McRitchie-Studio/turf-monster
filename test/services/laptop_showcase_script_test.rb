require "test_helper"

# [unit] The scripted showcase board (LaptopShowcaseEntrants::Script) over the
# fictional showcase (LaptopFictionalShowcase): exactly two entrants, Mason
# holding the home Cowboys and Turf the away 49ers; every touchdown trades
# first place between them; and every total is the board's own math: each
# pick's points are its team's points times that team's Turf Score, summed.
class LaptopShowcaseScriptTest < ActiveSupport::TestCase
  setup do
    @showcase = LaptopFictionalShowcase.build
    focus = @showcase.games.values.flatten.find { |g| g.slug == @showcase.focus_slug }
    @sim = LaptopScoreSimulation.new(focus)
    @script = LaptopShowcaseEntrants::Script.build(@showcase, @sim)
  end

  test "exactly two entrants, Mason and Turf, on every frame" do
    @sim.frames.each_index do |i|
      entries = @script.entries_at(i)
      assert_equal %w[Mason Turf], entries.map { |e| e.user.username }.sort
      assert_equal %w[showcase-mason showcase-turf], entries.map(&:slug).sort
    end
  end

  test "Mason leads the 3-7 opening, and each touchdown trades the lead" do
    leaders = @sim.frames.each_index.map { |i| @script.leader_at(i) }
    assert_equal "showcase-mason", leaders.first, "the Cowboys' 7 puts Mason on top"
    assert_equal "showcase-turf", leaders[1], "the 49ers' first touchdown puts Turf on top"
    assert_equal "showcase-mason", leaders[2], "the Cowboys' next takes it back"
    leaders.each_cons(2) { |a, b| refute_equal a, b, "every touchdown flips first place" }
    assert_equal 7, leaders.size, "the opening and six touchdowns"
  end

  test "Mason holds the Cowboys and Turf the 49ers, scored from the simulated frame" do
    dal = LaptopFictionalShowcase.team_slug("DAL")
    sf = LaptopFictionalShowcase.team_slug("SF")
    @sim.frames.each_with_index do |frame, i|
      entries = @script.entries_at(i).index_by(&:slug)
      mason_dal = entries["showcase-mason"].selections.find { |s| s.slate_matchup.team_slug == dal }
      turf_sf = entries["showcase-turf"].selections.find { |s| s.slate_matchup.team_slug == sf }
      assert_in_delta frame.game.home_score * 1.6, mason_dal.points, 1e-9
      assert_in_delta frame.game.away_score * 1.3, turf_sf.points, 1e-9
      refute entries["showcase-mason"].selections.any? { |s| s.slate_matchup.team_slug == sf }
      refute entries["showcase-turf"].selections.any? { |s| s.slate_matchup.team_slug == dal }
    end
  end

  test "every total is the multiplier math: points times Turf Score, summed over six picks" do
    @sim.frames.each_index do |i|
      entries = @script.entries_at(i)
      assert_equal entries.map { |e| -e.score }, entries.map { |e| -e.score }.sort, "highest first"
      entries.each do |entry|
        assert_equal 6, entry.selections.map { |sel| sel.slate_matchup.team_slug }.uniq.size
        assert_equal entry.selections.sum(&:points), entry.score, "the total is the sum of the picks"
        entry.selections.each do |sel|
          goals = sel.points / sel.slate_matchup.turf_score
          assert_equal goals.round, goals, "#{entry.slug}: whole points times the Turf Score"
        end
        assert_equal @script.totals_at(i)[entry.slug], entry.score
      end
    end
  end

  test "nothing is saved: every scripted record is new and readonly" do
    @script.entries_at(1).each do |entry|
      assert entry.new_record? && entry.readonly?
      assert entry.user.new_record? && entry.user.readonly?
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.save!(validate: false) }
      entry.selections.each { |sel| assert sel.readonly? }
    end
  end

  test "no script without a simulation" do
    assert_nil LaptopShowcaseEntrants::Script.build(@showcase, nil)
  end
end
