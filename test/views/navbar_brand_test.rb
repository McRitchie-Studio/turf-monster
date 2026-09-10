require "test_helper"

# [component] The navbar after the brand rename and the link move.
#
# TWO THINGS THIS DEFENDS, and neither is visual.
#
# 1. THE RENAME IS BRAND-ONLY. "Turf Totals" names two different things in this
#    app: the product, and one of the two GAME MODES (turf_totals vs survivor).
#    A blanket rename reads as a tidy-up and quietly renames the mode — so pin
#    that the wordmark moved and the mode's own rules page did not.
# 2. THE MOVED LINKS ARE STILL REACHABLE. NFL Totals and Reserves left the bar
#    for the gear sidebar, and that sidebar is `return unless current_user`. A
#    logged-out visitor would lose NFL Totals entirely if the footer did not
#    carry it — which is a page vanishing from the site, not a layout tweak.
class NavbarBrandTest < ActionView::TestCase
  NAVBAR = Rails.root.join("app/views/layouts/_navbar.html.erb")
  FOOTER = Rails.root.join("app/views/shared/_footer.html.erb")
  SIDEBAR = Rails.root.join("app/views/components/_gear_sidebar.html.erb")
  RULES_PAGE = Rails.root.join("app/views/pages/turf_totals_v1.html.erb")
  NFL_RULES_PAGE = Rails.root.join("app/views/pages/turf_monster_v1.html.erb")
  ROUTES = Rails.root.join("config/routes.rb")
  # The one page whose "Turf Totals" is the GAME MODE, not the brand.
  GAME_MODE_PAGE = RULES_PAGE

  # --- the wordmark -----------------------------------------------------------

  test "the wordmark reads Turf Monster" do
    src = NAVBAR.read

    assert_includes src, ">Monster</span>", "the wordmark's second half must read Monster"
    refute_includes src, ">Totals</span>", "no half of the wordmark may still say Totals"
    assert_includes src, 'alt="Turf Monster"', "the logo's alt text is brand copy too"
  end

  test "the game mode keeps its name" do
    # turf_totals is a game_type in the database and the name of the mode the
    # World Cup rules page documents. The rename must not have reached it.
    assert_includes RULES_PAGE.read, "Turf Totals v1",
                    "the mode's own rules page is not brand copy and stays"
    # The route identifier is not copy and never renames. This used to be pinned
    # through the FOOTER's Rules link, but every Rules link now follows the
    # season (see the sweep below), so pin the route where it is DECLARED — a
    # declaration cannot drift the way a reference to it can.
    # Anchored on a word boundary, NOT assert_includes: "as: :turf_totals_v1"
    # is a prefix of "as: :turf_totals_v1_legacy", so a plain substring match
    # is satisfied by the very rename it exists to refuse. (Measured: that
    # mutant survived until this line became a regex.)
    assert_match(/as: :turf_totals_v1\b/, ROUTES.read,
                 "the route identifier is not copy and never renames")
    # Reachability is proven separately, and by RENDER rather than by source:
    # pages_controller_test's "the World Cup rules page still answers" GETs the
    # path and asserts 200. An old link in the wild must never 404.
  end

  # --- the season ---------------------------------------------------------------

  # THE RULES LINK FOLLOWS THE SEASON, NOT THE BRAND. There are two versioned
  # rules pages because the two sports are different games underneath: the World
  # Cup page (/turf-totals-v1) documents a logarithmic multiplier to x3.0 scored
  # on goals; the NFL page (/turf-monster-v1) documents a linear one to x2.0
  # scored on points, over a multi-week span. Pointing the navbar at the season
  # being played is a CONTENT decision and is not the rename this file guards —
  # turf-totals-v1 keeps its route, its name, and its footer link (asserted
  # above).
  #
  # Counted, not merely present: the bar draws Rules TWICE (desktop nav and the
  # mobile sub-navbar), and a repoint that moved only the one you looked at is
  # exactly the miss an assert_includes sails past.
  test "both Rules links point at the season being played" do
    src = NAVBAR.read

    assert_equal 2, src.scan(/link_to "Rules", turf_monster_v1_path/).size,
                 "desktop AND mobile Rules links must point at the NFL rules page"
    refute_includes src, 'link_to "Rules", turf_totals_v1_path',
                    "no Rules link may still point at the World Cup page"
  end

  # ONE LABEL, ONE DESTINATION — the sweep that would have caught THIS bug.
  # Repointing the navbar at the NFL page left the FOOTER and the TRANSPARENCY
  # hub tile on the World Cup one, so the site shipped two contradictory
  # rulebooks under a single label: they disagree on the scoring unit (points
  # vs goals), the multiplier ceiling (x2.0 vs x3.0) and the tie rule. During
  # NFL season a player clicking footer Rules read the wrong rulebook for the
  # contest they were entering.
  #
  # Pinning each site's literal would rot exactly the way the miss did, so
  # SWEEP for the LABEL: any Rules link added anywhere tomorrow is covered
  # without editing this file, and one pointed at the wrong season fails here.
  RULES_LINK_SURFACES = %w[
    app/views/**/*.erb
    app/helpers/**/*.rb
  ].freeze

  # The two spellings a Rules link is written in: the plain `link_to "Rules",
  # <path>` and the hub tile's `name: "Rules", url: <path>`. The character class
  # carries DIGITS deliberately — both rules routes are versioned
  # (turf_monster_v1_path), and an [a-z_]+ class matches NEITHER, which is a
  # sweep that reads nothing and reports a clean site.
  RULES_LINK = /"Rules",\s*(?:url:\s*)?([a-z0-9_]+_path)/

  def rules_links
    RULES_LINK_SURFACES.flat_map { |glob| Dir[Rails.root.join(glob)] }.flat_map do |file|
      rel = Pathname(file).relative_path_from(Rails.root).to_s
      File.read(file).scan(RULES_LINK).map { |(path)| [rel, path] }
    end
  end

  test "every link labelled Rules points at the same rulebook" do
    found = rules_links
    files = found.map(&:first)

    # A sweep that reads NOTHING passes everything, so prove it reached the
    # known sites before trusting what it says about them.
    assert_operator found.size, :>=, 4,
                    "the sweep found #{found.size} Rules links; it must reach at least " \
                    "the navbar's two, the footer's and the transparency hub's"
    assert_equal 2, files.count("app/views/layouts/_navbar.html.erb"),
                 "the bar draws Rules twice — desktop nav and mobile sub-navbar"
    assert_includes files, "app/views/shared/_footer.html.erb",
                    "the footer's Rules link must be in the sweep"
    assert_includes files, "app/views/transparency/show.html.erb",
                    "the transparency hub's Rules tile must be in the sweep"

    assert_equal ["turf_monster_v1_path"], found.map(&:last).uniq,
                 "every Rules link must land on ONE rulebook — the season being played — " \
                 "or the site documents two different games under one label: #{found.inspect}"
  end

  # The page the link now lands on has to exist, and has to be the NFL one. A
  # navbar pointing at a route whose view was never written is a 500 on the most
  # linked page in the app.
  test "the NFL rules page exists and documents the NFL" do
    assert_path_exists NFL_RULES_PAGE.to_s
    src = NFL_RULES_PAGE.read

    assert_includes src, "Turf Monster", "the NFL rules page is brand-named"
    assert_includes src, "NFL 2026", "and says which season it documents"
  end

  # THE TEST THAT WOULD HAVE CAUGHT THE MISS. The brand is drawn as TWO SPANS in
  # four places ("Turf" + "Totals"), so a search-and-replace over the string
  # "Turf Totals" sails straight past every one of them — the navbar was renamed
  # while the footer, the landing page and the auth card still read TurfTotals,
  # and only a screenshot found it. Sweep the views instead of trusting the pass.
  # THE SWEEP THAT MISSED THE MANIFEST. The first version of this globbed
  # app/views/**/*.erb, so no file outside app/views could ever fail it — and
  # public/site.webmanifest shipped "Turf Totals" as the PWA name and short_name,
  # which is what a phone puts on the home screen after Add to Home Screen. Sweep
  # every SHIPPING surface the brand can appear on, not just the one the last
  # miss happened to be in.
  BRAND_SURFACES = %w[
    app/views/**/*.erb
    app/helpers/**/*.rb
    app/mailers/**/*.rb
    config/initializers/studio.rb
    public/*.webmanifest
  ].freeze

  # Files whose "Turf Totals" is the GAME MODE (turf_totals vs survivor), not the
  # brand. Every entry needs a reason, because an allowlist is how a real miss
  # gets waved through.
  GAME_MODE_FILES = {
    "app/views/pages/turf_totals_v1.html.erb" => "the mode's own versioned rules page",
    "app/views/pages/terms.html.erb"          => "scopes the editing rule to the mode; Survivor is excluded in the same sentence",
    "app/helpers/landing_pages_helper.rb"     => "comments the else-branch that reads TURF_TOTALS_DEFAULT_PICKS_REQUIRED",
    "app/views/contests/show.html.erb"        => "section comments naming the mode's board",
    "app/views/contests/_world_cup_survivor_board.html.erb" => "a comment contrasting this board with the turf_totals flow",
    "app/views/pages/responsible_gaming.html.erb" => "scopes the six-picks claim to the mode; picks_required is 0 for Survivor (contest.rb:204)"
  }.freeze

  test "no shipping surface still carries the retired brand" do
    offenders = BRAND_SURFACES.flat_map { |g| Dir[Rails.root.join(g)] }
      .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
      .reject { |rel| GAME_MODE_FILES.key?(rel) }
      .select { |rel| Rails.root.join(rel).read.include?("Turf Totals") }

    assert_empty offenders,
                 "these ship the retired brand: #{offenders.join(', ')} — rename them, " \
                 "or add them to GAME_MODE_FILES WITH a reason if the string is the game mode"
  end

  test "no split wordmark still reads Totals" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].reject { |f| f == GAME_MODE_PAGE.to_s }
      .select { |f| File.read(f).match?(/Turf<\/span>\s*<span[^>]*>Totals|Turf <span[^>]*>Totals/) }
      .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }

    assert_empty offenders,
                 "these draw the brand as two spans and still say Totals: #{offenders.join(', ')}"
  end

  # --- the move ---------------------------------------------------------------

  test "NFL Totals and Reserves left the navbar" do
    src = NAVBAR.read

    refute_includes src, '"NFL Totals"', "NFL Totals moved to the gear sidebar"
    refute_includes src, '"Reserves"', "Reserves moved to the gear sidebar"
    # The two that earned their slot are still there.
    assert_includes src, '"Contests"'
    assert_includes src, '"Rules"'
  end

  test "the gear sidebar picked both of them up" do
    src = SIDEBAR.read

    assert_includes src, "nfl_team_totals_path", "NFL Totals must land in the sidebar"
    assert_includes src, "proof_of_reserves_path", "Reserves was already here"
  end

  test "a logged-out visitor can still reach both pages" do
    # The gear sidebar opens with `return unless current_user`, so it is not a
    # destination for anonymous traffic. The footer is, and both pages are public.
    footer = FOOTER.read

    assert_includes SIDEBAR.read, "return unless current_user",
                    "if the sidebar ever became public this test's premise changes"
    assert_includes footer, "nfl_team_totals_path",
                    "NFL Totals would be unreachable logged-out without this"
    assert_includes footer, "proof_of_reserves_path",
                    "Proof of Reserves is a trust page and must stay public-reachable"
  end
end
