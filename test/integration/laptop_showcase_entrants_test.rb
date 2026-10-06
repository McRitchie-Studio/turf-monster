require "test_helper"

# [unit] + [integration] The hero laptop's showcase entrants
# (LaptopShowcaseEntrants): an under-filled contest gains Mason, turf and mack
# on the LAPTOP's board, drawn by the real leaderboard partial with their
# images, scored by Selection#computed_points, and nothing is written; a
# contest with three or more real entries shows only its real entrants.
class LaptopShowcaseEntrantsTest < ActionDispatch::IntegrationTest
  NAMES = %w[Mason turf mack].freeze

  setup do
    SeasonConfig.set_main_contest!(nil)
    Message.delete_all
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    @slate = Slate.create!(name: "NFL 2026 Weeks 5-7", slug: "nfl-2026-weeks-5-7-showcase", sport: "nfl", starts_at: 3.days.ago)
    # 18 teams in 9 games, team i scoring i goals at x1.0, so every pick's
    # points differ and the deal is strictly ordered.
    9.times do |g|
      home = team("sc-h#{g}", "Home#{g}")
      away = team("sc-a#{g}", "Away#{g}")
      game = Game.create!(slug: "sc-game-#{g}", home_team_slug: home.slug, away_team_slug: away.slug,
                          kickoff_at: 1.hour.ago, status: "in_progress", venue: "Test Stadium")
      [[home, away], [away, home]].each_with_index do |(t, o), side|
        SlateMatchup.create!(slate: @slate, team_slug: t.slug, opponent_team_slug: o.slug, game_slug: game.slug,
                             goals: g * 2 + side, turf_score: 1.0, rank: g * 2 + side + 1)
      end
    end
    @contest = Contest.create!(name: "NFL 2026 Weeks 5-7", slug: "weeks-5-7-showcase", status: "open", entry_fee_cents: 1900,
                               max_entries: 29, contest_type: "standard", slate: @slate, starts_at: 2.days.ago)
  end

  def team(slug, name)
    Team.find_or_create_by!(slug: slug) { |t| t.name = name; t.short_name = name; t.league = "nfl" }
  end

  def board
    get turf_monster_v2_path
    assert_response :success
    css_select('[data-test="laptop-live-leaderboard"]').first.tap { |node| assert node, "the laptop board renders" }
  end

  def row_names(node)
    node.css('[data-role="entry-row"]').map { |r| r.at_css(".font-bold.truncate").text.strip }
  end

  def counts
    [Entry.count, User.count, Selection.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count,
     Contest.count, @contest.reload.attributes]
  end

  test "an empty contest shows Mason, turf and mack, with images, in that order, crown on Mason" do
    assert_equal @contest, NextContest.live_showcase&.contest, "the laptop shows this contest"
    node = board
    assert_equal NAMES, row_names(node)

    rows = node.css('[data-role="entry-row"]')
    assert_equal %w[showcase-mason showcase-turf showcase-mack], rows.map { |r| r["data-entry-slug"] }
    images = rows.map { |r| r.at_css('img[data-test="showcase-avatar"]') }
    assert images.all?, "each showcase row wears its image, not initials"
    %w[mason turf mack].zip(images).each { |name, img| assert_match %r{showcase/#{name}}, img["src"] }
    assert_equal NAMES, images.map { |i| i["alt"] }
    assert rows.first.text.include?("👑"), "Mason is first, crowned"
    refute rows[1].text.include?("👑")

    scores = rows.map { |r| r["data-score"].to_f }
    assert_equal scores.sort.reverse, scores
    assert_operator scores[0], :>, scores[1]
    assert_operator scores[1], :>, scores[2]
    assert_equal 6, rows.first.css('[title*=" — "]').map { |p| p["title"] }.uniq.size, "six picks from the real slate"
  end

  test "the showcase scores are the app's own pick math" do
    showcase = LaptopShowcaseEntrants.fill(NextContest.live_showcase)
    showcase.entries.each do |entry|
      expected = entry.selections.sum { |s| s.slate_matchup.goals * s.slate_matchup.turf_score }
      assert_equal expected.to_f, entry.score.to_f, "#{entry.user.username}: goals x turf score, summed"
      assert_equal 6, entry.selections.map { |s| s.slate_matchup.team_slug }.uniq.size, "six distinct teams"
    end
  end

  test "nothing is persisted: no entry, user, pick or attachment, and the contest is untouched" do
    before = counts
    board
    assert_equal before, counts
    showcase = LaptopShowcaseEntrants.fill(NextContest.live_showcase)
    showcase.entries.each do |entry|
      # validate: false reaches the write itself, which readonly! refuses.
      assert entry.new_record? && entry.readonly?
      assert entry.user.new_record? && entry.user.readonly?
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.save!(validate: false) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.user.save!(validate: false) }
      entry.selections.each { |s| assert_raises(ActiveRecord::ReadOnlyRecord) { s.save!(validate: false) } }
    end
    assert_equal before, counts
  end

  test "a contest with three or more real entries shows the real entrants only" do
    real = User.limit(3).to_a
    assert_equal 3, real.size
    real.each_with_index do |user, i|
      user.update_columns(username: "realplayer#{i}")
      @contest.entries.create!(user: user, status: :active).tap { |e| e.update_column(:score, 100 - i) }
    end
    node = board
    assert_equal %w[realplayer0 realplayer1 realplayer2], row_names(node)
    assert_empty node.css('[data-entry-slug^="showcase-"]')
    assert_empty node.css('img[data-test="showcase-avatar"]')
  end

  test "with one real entry, it is ranked among the showcase by score" do
    user = users(:sam)
    user.update_columns(username: "onlyreal")
    @contest.entries.create!(user: user, status: :active).tap { |e| e.update_column(:score, 10_000) }
    assert_equal ["onlyreal", *NAMES], row_names(board)
  end
end
