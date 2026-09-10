require "test_helper"

# Component tier for the redesigned multi-week team card: renders the real
# partial and asserts the new identity block (city over mascot, team gradient,
# accent mascot, light-forward flip) without depending on contest fixtures.
class MultiWeekTeamCardTest < ActionView::TestCase
  include ApplicationHelper
  include TeamColorsHelper
  include ContestsHelper

  MatchupDouble = Struct.new(:id, :team, :locked, keyword_init: true) do
    def locked? = locked
  end
  # `game` defaults to nil, which is the TBD-kickoff case: the column falls back
  # to its week label. The dated case is built explicitly by game_double below.
  WeekMatchupDouble = Struct.new(:opponent_team, :game, keyword_init: true)
  GameDouble = Struct.new(:kickoff_at, keyword_init: true)

  # Real (unsaved) Team so the card's palette helpers read the actual color API:
  # a dark-disposition Ravens by default (navy field, gold mascot).
  def team_double(**overrides)
    Team.new({
      name: "Baltimore Ravens", location: "Baltimore",
      emoji: "🐦‍⬛", short_name: "BAL",
      color_dark: "#241773", color_light: "#9e7c0c", color_disposition: "dark"
    }.merge(overrides))
  end

  def opponents_double
    [
      [1, WeekMatchupDouble.new(opponent_team: team_double(name: "Indianapolis Colts", emoji: "🐴", short_name: "IND",
                                               color_dark: "#002c5f", color_light: "#a2aaad"))],
      [2, nil], # bye
      [3, WeekMatchupDouble.new(opponent_team: team_double(name: "Dallas Cowboys", emoji: "⭐", short_name: "DAL"))]
    ]
  end

  # The same three columns, but with real kickoffs — the shape the board
  # actually renders. Weeks 4-6 of the seeded 2026 schedule, and week 5 is
  # DELIBERATELY the Monday nighter: 2026-10-13T00:15Z is Monday Oct 12 in
  # Eastern, so a UTC read of it prints the 13th.
  def dated_opponents_double
    [
      [4, WeekMatchupDouble.new(
        opponent_team: team_double(name: "Indianapolis Colts", emoji: "🐴", short_name: "IND",
                                   color_dark: "#002c5f", color_light: "#a2aaad"),
        game: GameDouble.new(kickoff_at: Time.utc(2026, 10, 4, 17, 0)))],
      [5, WeekMatchupDouble.new(
        opponent_team: team_double(name: "Dallas Cowboys", emoji: "⭐", short_name: "DAL"),
        game: GameDouble.new(kickoff_at: Time.utc(2026, 10, 13, 0, 15)))],
      [6, WeekMatchupDouble.new(
        opponent_team: team_double(name: "Las Vegas Raiders", emoji: "☠️", short_name: "LV"),
        game: nil)]
    ]
  end

  def render_card(team, multiplier: 1.1, opponents: opponents_double)
    render(partial: "contests/multi_week_team_card",
           locals: { matchup: MatchupDouble.new(id: 42, team: team, locked: false),
                     multiplier: multiplier, opponents: opponents })
  end

  def render_dated_card(team = team_double)
    render_card(team, opponents: dated_opponents_double)
  end

  test "card splits city and mascot onto separate lines" do
    html = render_card(team_double)
    assert_includes html, "Baltimore"
    assert_includes html, "Ravens"
  end

  test "card drops the big team mascot emoji" do
    html = render_card(team_double)
    refute_includes html, "🐦‍⬛", "the header mascot emoji should be gone"
  end

  test "card paints a team-color gradient background" do
    html = render_card(team_double)
    assert_includes html, "linear-gradient"
  end

  test "mascot uses the accent color (a well-contrasting secondary)" do
    html = render_card(team_double)
    assert_match(/Ravens/, html)
    assert_includes html, "#9e7c0c", "mascot should render in the accent color"
  end

  test "dark team uses light foreground text" do
    html = render_card(team_double)
    assert_includes html, TeamColorsHelper::LIGHT_FG
  end

  test "light-forward team flips to dark foreground and a dark accent" do
    saints = team_double(name: "New Orleans Saints", location: "New Orleans",
                         emoji: "⚜️", short_name: "NO",
                         color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light")
    html = render_card(saints)
    assert_includes html, "New Orleans"
    assert_includes html, "Saints"
    assert_includes html, TeamColorsHelper::DARK_FG
    assert_includes html, "#101820"
    refute_includes html, "⚜️"
  end

  test "selection and lock wiring survive the restyle" do
    html = render_card(team_double)
    assert_includes html, "toggleSelection('42')"
    assert_includes html, "is-selected"
  end

  test "week opponents still render under the team" do
    html = render_card(team_double)
    assert_includes html, "IND"
    assert_includes html, "DAL"
    assert_includes html, "bye"
    assert_includes html, "Points"
  end

  # --- mobile opponent chips -------------------------------------------------
  # A mobile card is half a ~390px viewport, so each of the three opponent
  # columns is only ~45px wide. At text-sm the emoji plus a three-letter
  # abbreviation overflows that and `truncate` eats the short name down to one
  # letter ("I…"), which hides the very thing the row exists to show. These
  # assert the mobile size is smaller AND that md+ still gets the original.

  def fragment(html) = Nokogiri::HTML::DocumentFragment.parse(html)

  def classes_of(node)
    refute_nil node
    node["class"].to_s.split
  end

  def week_label(html, label)
    fragment(html).css("p").find { |p| p.text.strip == label }
  end

  def label_texts(html)
    fragment(html).css("p.tm-opponent-week").map { |p| p.text.strip }
  end

  def aria_label(html)
    html[/aria-label="([^"]*)"/, 1].to_s
  end

  # The row <p> holding one column's emoji + abbreviation.
  def opponent_row(html, text)
    fragment(html).css("p.tm-opponent-row").find { |p| p.text.include?(text) }
  end

  def chip_span(html, text)
    fragment(html).css("span").find { |s| s.text.strip == text }
  end

  test "week label is a touch smaller on mobile and restores at lg" do
    classes = classes_of(week_label(render_card(team_double), "Week 1"))
    assert_includes classes, "text-[9px]", "mobile week label should shrink below 10px"
    assert_includes classes, "lg:text-[10px]", "the wide (lg) card keeps the original 10px label"
  end

  test "opponent abbreviation shrinks on mobile so a three-letter short name fits" do
    classes = classes_of(chip_span(render_card(team_double), "IND"))
    refute_includes classes, "text-sm",
                    "an unconditional text-sm truncates IND inside a ~48px mobile column"
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm", "the wide (lg) card keeps the original size"
  end

  test "opponent emoji shrinks with its abbreviation on mobile" do
    classes = classes_of(chip_span(render_card(team_double), "\u{1F434}"))
    refute_includes classes, "text-sm"
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm"
  end

  test "bye week keeps the same responsive sizing as a real opponent" do
    classes = classes_of(chip_span(render_card(team_double), "bye"))
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm"
  end

  # --- opponent column labels ------------------------------------------------
  # The column used to read "Week 4". It now reads the DAY that game is played,
  # because the span is named all over the surrounding page and the week number
  # is the one thing the column need not repeat.

  test "opponent column labels the game date instead of the week" do
    html = render_dated_card

    assert_not_nil week_label(html, "Oct 4"), "the week-4 column should print its game date"
    refute_includes label_texts(html), "Week 4", "the week number should be off the face of the card"
  end

  # THE REGRESSION THIS FILE EXISTS FOR. kickoff_at is stored in true UTC and
  # the app sets no config.time_zone, so Time.zone IS UTC. This game kicks off
  # Monday Oct 12 at 8:15 PM Eastern and stores as 2026-10-13T00:15Z. A UTC
  # strftime prints "Oct 13" — tomorrow — and does it on every Sunday-, Monday-
  # and Thursday-night game on the board.
  test "a night game is dated in Eastern, not in UTC" do
    html = render_dated_card

    assert_not_nil week_label(html, "Oct 12"),
                   "a Monday nighter must date to its Eastern game day"
    assert_nil week_label(html, "Oct 13"),
               "the UTC calendar day is the day AFTER this game — it must not be shown"
  end

  # ~1 game in 20 has no kickoff yet (256 of 272 weekly-slate games carried one
  # when last counted). Those columns keep the label they have always had
  # rather than going blank.
  test "a game with no kickoff falls back to its week label" do
    html = render_dated_card

    assert_not_nil week_label(html, "Week 6"), "a TBD kickoff should still name its week"
  end

  test "tooltip and accessible name keep the week the column dropped" do
    html = render_dated_card
    cell = fragment(html).css("[title]").find { |node| node["title"].to_s.include?("Colts") }

    assert_includes cell["title"], "Week 4", "the tooltip must still carry the week"
    assert_includes cell["title"], "Oct 4", "and the date it now shows"

    # Read from the RAW html, not from Nokogiri. The card's <button> carries
    # Alpine's `@click`, and Nokogiri's HTML4 parser gives up partway through
    # that attribute — it returns the button with attributes ["x-data", "if",
    # "hoverlocked", "pressing", "settimeout"] and no class, style or
    # aria-label at all. A Nokogiri read of aria-label here is silently nil,
    # which would pass any `refute` and fail every `assert` for the wrong
    # reason.
    aria = aria_label(html)
    assert_includes aria, "Week 4 · Oct 4: Indianapolis Colts"
    assert_includes aria, "Week 6: Las Vegas Raiders",
                    "an undated column announces its week alone"
  end

  test "undated opponents render exactly as before" do
    html = render_card(team_double)

    assert_not_nil week_label(html, "Week 1")
    assert_not_nil week_label(html, "Week 3")
  end

  # --- the "vs" divider ------------------------------------------------------

  test "the opponents divider reads vs in the card's own foreground, bolded" do
    html = render_dated_card
    label = fragment(html).css("span").find { |span| span.text.strip == "vs" }

    assert_not_nil label, "the divider should read vs"
    assert_includes label["class"].to_s.split, "font-bold"
    assert_includes label["style"].to_s, TeamColorsHelper::LIGHT_FG,
                    "vs wears the same foreground as the multiplier, not the faint grey"
    refute_includes html, "Opponents", "the old five-syllable label should be gone"
  end

  test "the vs divider flips with a light-forward team, as the multiplier does" do
    saints = team_double(name: "New Orleans Saints", location: "New Orleans",
                         emoji: "⚜️", short_name: "NO",
                         color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light")
    label = fragment(render_card(saints)).css("span").find { |span| span.text.strip == "vs" }

    assert_includes label["style"].to_s, TeamColorsHelper::DARK_FG,
                    "on a gold field vs must take the dark foreground or it disappears"
  end

  # --- the multiplier line ---------------------------------------------------

  # A multiplier of exactly 1 used to render "1× Point". The number multiplies
  # points rather than counting them, so the noun never goes singular: 1x is
  # one TIMES points.
  test "a 1x multiplier still reads Points" do
    html = render_card(team_double, multiplier: 1)

    assert_includes html, "Points"
    label = fragment(html).css("span").find { |span| span.text.strip == "Point" }
    assert_nil label, "the multiplier label must never go singular"
  end

  test "the multiplier sign sits outside the mono span so it stays on the baseline" do
    html = render_card(team_double, multiplier: 1.1)
    spans = fragment(html).css("span")
    number = spans.find { |span| span.text.strip == "1.1" }
    sign   = spans.find { |span| span.text.strip == "x" }

    assert_not_nil number, "the digits should render alone in their own span"
    assert_includes number["class"].to_s.split, "font-mono"
    assert_not_nil sign, "the multiplier sign should be its own span"
    refute_includes sign["class"].to_s.split, "font-mono",
                    "a monospace sign is drawn small on the math axis and floats"
    refute_includes html, "&times;"
  end

  # --- opponent legibility rim -----------------------------------------------

  test "each opponent row carries a halo in the opponent's own dark" do
    row = opponent_row(render_dated_card, "IND")

    assert_includes row["style"].to_s, "radial-gradient",
                    "an abbreviation with no backdrop dissolves into a same-luminance field"
    assert_includes row["style"].to_s, rgba("#002c5f", 0.85)
  end

  # A text-shadow traces the glyph and leaves the counters and inter-letter
  # gaps showing raw field. The backdrop darkens the AREA instead.
  test "the halo is a backdrop on the row, not a shadow on the glyphs" do
    html = render_dated_card

    refute_includes html, "text-shadow: 0 0 1px", "the glyph-tracing rim was replaced"
    assert_not_nil opponent_row(html, "IND")
  end

  test "the halo flips with the host field, as the label colour does" do
    saints = team_double(name: "New Orleans Saints", location: "New Orleans",
                         emoji: "⚜️", short_name: "NO",
                         color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light")
    html = render_card(saints)

    # On the gold field the label takes the opponent's dark, so the halo must
    # take their light or it paints the text's own colour behind the text.
    assert_includes chip_span(html, "IND")["style"].to_s, "#002c5f",
                    "label is the opponent's dark on a gold field"
    assert_includes opponent_row(html, "IND")["style"].to_s, rgba("#a2aaad", 0.85),
                    "the halo flips to the opponent's light"
  end
end
