require "test_helper"

# [unit] The scripted showcase board (LaptopShowcaseEntrants::Script): with no
# real entries and a simulated featured game, every touchdown trades first
# place between Mason (the home team) and turf (the away team), mack stays
# under both, and every total is the board's own math: each pick's points are
# its team's points times that team's Turf Score, summed.
class LaptopShowcaseScriptTest < ActiveSupport::TestCase
  Showcase = NextContest::LiveShowcase

  setup do
    @slate = Slate.create!(name: "NFL Script", slug: "nfl-script-test", sport: "nfl", starts_at: 3.days.ago)
    @contest = Contest.new(name: "Script", slug: "script-test", status: "open", contest_type: "standard", slate: @slate)
    @game = games(:future_game)
    @matchups = [
      matchup(@game.home_team_slug, 1.4), matchup(@game.away_team_slug, 1.2),
      *(1..18).map { |i| matchup("sc-other-#{i}", 1.0 + (i % 5) * 0.3) }
    ]
    @sim = LaptopScoreSimulation.new(@game)
  end

  def matchup(team_slug, turf_score)
    SlateMatchup.new(slate: @slate, team_slug: team_slug, turf_score: turf_score).tap(&:readonly!)
  end

  def script(entries: [], sim: @sim, matchups: @matchups)
    showcase = Showcase.new(contest: @contest, games: {}, focus_slug: @game.slug, matchups: matchups,
                            entries: entries, messages: [])
    LaptopShowcaseEntrants::Script.build(showcase, sim)
  end

  test "Mason leads the opening, and each touchdown trades the lead: away to turf, home to Mason" do
    s = script
    assert s, "a script exists for close Turf Scores"
    leaders = @sim.frames.each_index.map { |i| s.leader_at(i) }
    expected = @sim.frames.map { |f| f.team.nil? || f.team.slug == @game.home_team_slug ? "showcase-mason" : "showcase-turf" }
    assert_equal expected, leaders
    assert_equal "showcase-mason", leaders.first
    assert_equal "showcase-turf", leaders[1], "the first touchdown is the away side's"
    assert_equal "showcase-mason", leaders[2], "and the second takes it back"
    leaders.each_cons(2) { |a, b| refute_equal a, b, "every touchdown flips first place" }
  end

  test "mack stays under both all game" do
    s = script
    @sim.frames.each_index do |i|
      t = s.totals_at(i)
      assert_operator t["showcase-mack"], :<, [t["showcase-mason"], t["showcase-turf"]].min
    end
  end

  test "every total is the multiplier math: points times Turf Score, summed over six picks" do
    s = script
    @sim.frames.each_index do |i|
      frame = @sim.frames[i]
      entries = s.entries_at(i)
      assert_equal entries.map { |e| -e.score }, entries.map { |e| -e.score }.sort, "highest first"
      entries.each do |entry|
        assert_equal 6, entry.selections.size
        assert_equal 6, entry.selections.map { |sel| sel.slate_matchup.team_slug }.uniq.size
        assert_in_delta entry.selections.sum(&:points), entry.score, 1e-9, "the total is the sum of the picks"
        entry.selections.each do |sel|
          goals = sel.points / sel.slate_matchup.turf_score
          assert_in_delta goals.round, goals, 1e-9, "#{entry.slug}: whole points times the Turf Score"
        end
        assert_equal s.totals_at(i)[entry.slug], entry.score
      end
      mason = entries.find { |e| e.slug == "showcase-mason" }
      dal = mason.selections.find { |sel| sel.slate_matchup.team_slug == @game.home_team_slug }
      assert_in_delta frame.game.home_score * 1.4, dal.points, 1e-9, "Mason's home pick scores the simulated home points"
      turf = entries.find { |e| e.slug == "showcase-turf" }
      tb = turf.selections.find { |sel| sel.slate_matchup.team_slug == @game.away_team_slug }
      assert_in_delta frame.game.away_score * 1.2, tb.points, 1e-9, "turf's away pick scores the simulated away points"
      refute entries.find { |e| e.slug == "showcase-mack" }.selections.any? { |sel|
        [@game.home_team_slug, @game.away_team_slug].include?(sel.slate_matchup.team_slug)
      }, "mack holds neither featured team"
    end
  end

  test "nothing is saved: every scripted record is new and readonly" do
    script.entries_at(1).each do |entry|
      assert entry.new_record? && entry.readonly?
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.save!(validate: false) }
      entry.selections.each { |sel| assert sel.readonly? }
    end
  end

  test "no script with a real entry, without a simulation, or when no flip window exists" do
    assert_nil script(entries: [Entry.new]), "a real contest's board is never moved"
    assert_nil script(sim: nil)
    far = [matchup(@game.home_team_slug, 3.0), matchup(@game.away_team_slug, 1.0), *@matchups.drop(2)]
    assert_nil script(matchups: far), "Turf Scores 3x apart leave no gap that flips every touchdown"
  end
end
