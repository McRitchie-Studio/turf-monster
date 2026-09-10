require "test_helper"

class LandingPagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @active   = landing_pages(:launch) # active, contest: one
    @inactive = landing_pages(:draft)  # inactive, no contest
    @admin    = users(:alex)
  end

  test "shows an active landing page to anyone" do
    get landing_page_path(@active)
    assert_response :success
    assert_select "h1", text: @active.headline
  end

  test "renders the CTA pointing at the contest" do
    get landing_page_path(@active)
    assert_select "a[href=?][target=_blank]", contest_path(@active.contest.slug, scroll: 280), text: @active.cta_label
  end

  test "visiting seeds the reference cookie with the slug" do
    get landing_page_path(@active)
    assert_equal @active.slug, cookies[:reference]
  end

  test "an existing reference cookie is not overwritten by a landing page" do
    get faucet_path, params: { reference: "campaign-x" }
    get landing_page_path(@active)
    assert_equal "campaign-x", cookies[:reference]
  end

  test "inactive page is hidden from the public" do
    get landing_page_path(@inactive)
    assert_redirected_to root_path
  end

  test "inactive page is visible to admins for preview" do
    log_in_as(@admin)
    get landing_page_path(@inactive)
    assert_response :success
  end

  test "unknown slug redirects" do
    get landing_page_path("does-not-exist")
    assert_redirected_to root_path
  end

  test "a survivor contest funnel shows survivor copy and a free entry" do
    survivor = Contest.create!(name: "WC Survivor Test", game_type: "world_cup_survivor",
                               contest_type: "survivor_wc_free", status: "open")
    lp = LandingPage.create!(name: "Survivor Funnel", headline: "Last One Standing",
                             contest: survivor, active: true)
    get landing_page_path(lp)
    assert_response :success
    assert_select "p", text: "Win or draw to survive"       # survivor how-it-works step
    assert_select "p", text: "Pick 6 teams", count: 0 # not the Turf Totals copy
    assert_select "p", text: "Free"                         # $0 entry renders as Free
  end

  test "renders the gradient background by default" do
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-bg"
  end

  test "renders the blob background when the page selects it" do
    @active.update!(background_style: "blobs")
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-blobs svg"
    assert_select ".lp-bg", count: 0
  end

  test "renders the circles background when the page selects it" do
    @active.update!(background_style: "circles")
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-circles"
    assert_select ".lp-bg", count: 0
  end

  test "renders the badge when set" do
    @active.update!(badge: "Alpha Test")
    get landing_page_path(@active)
    assert_response :success
    assert_select ".lp-badge", text: "Alpha Test"
  end

  test "renders no badge when the badge is blank" do
    get landing_page_path(@active) # launch fixture has no badge
    assert_response :success
    assert_select ".lp-badge", count: 0
  end

  # --- Funnel copy regression: the steps and the rulebook link follow the
  # contest's SPORT, and neither sport is hardcoded. ---
  #
  # `Contest#game_type` is a FORMAT enum (turf_totals / world_cup_survivor), NOT
  # a sport. The SPORT lives on the SLATE — Turf Totals ran on the World Cup in
  # season 1 and runs on the NFL now — so a funnel that hardcodes either sport is
  # right for one audience and wrong for the other. This file has certified both
  # mistakes: the shipped code hardcoded World Cup, a fix hardcoded NFL, and the
  # green suite asserted that a FIFA-slate contest must render "NFL". Both sports
  # are asserted below so neither can be traded for the other again.
  #
  # `landing_pages(:launch)` -> `contests(:one)` -> `slates(:one)` is the World
  # Cup case, and that is production: both live funnels (/l/alpha,
  # /l/world-cup-week-1) are turf_totals on a fifa slate, one of them carrying an
  # open money contest. The fixture now states `sport: fifa` rather than leaving
  # it to be derived from the name "Test Slate".
  #
  # These read the RENDERED subtree, not the source: a `data-test` scope keeps the
  # layout's own nav/footer/meta copy out of the assertion, which a page-wide
  # assert_select would silently swallow.

  WORLD_CUP_WORDING = /world cup/i
  NFL_WORDING = /\bNFL\b/

  # A hardcoded calendar date rots the day after it passes, and "simulated" is
  # rehearsal vocabulary that must never reach a real-money funnel.
  REHEARSAL_NOISE = /simulated|\b(?:mon|tues|wednes|thurs|fri|satur|sun)day\b|\bthe \d{1,2}(?:st|nd|rd|th)\b|\b\d{1,2}(?::\d{2})?\s*[ap]m\b|\b[MECP][SD]T\b/i

  def funnel_steps_text
    subtree = css_select("[data-test='funnel-how-it-works']")
    assert_equal 1, subtree.size, "expected exactly one funnel how-it-works block"
    subtree.first.text
  end

  # A Turf Totals contest on an NFL slate — the audience production does not have
  # yet, and the one the NFL-hardcoding fix would have served at the World Cup's
  # expense. Built here rather than as a fixture on purpose: `slates(:one)` is
  # deliberately the fifa case, and a second global slate fixture would land in
  # every `Slate.selector_ordered` assertion in the suite.
  def nfl_funnel
    slate = Slate.create!(name: "NFL 2026 Week 1")
    assert_equal "nfl", slate.sport, "guard: this slate must read as football"

    contest = Contest.create!(name: "NFL Copy Contest", game_type: "turf_totals",
                              contest_type: "standard", status: "open", slate: slate)
    LandingPage.create!(name: "NFL Copy Funnel", headline: "Pick Six", contest: contest, active: true)
  end

  test "a World Cup contest funnel names the World Cup and never the NFL" do
    assert @active.contest.turf_totals?, "fixture guard: launch funnel is a Turf Totals contest"
    assert_equal "fifa", @active.contest.slate.sport, "fixture guard: on a World Cup slate"

    get landing_page_path(@active)
    assert_response :success

    steps = funnel_steps_text
    assert_match(WORLD_CUP_WORDING, steps, "the World Cup funnel must name the sport it is selling")
    assert_no_match(NFL_WORDING, steps, "World Cup funnel is showing NFL copy")

    # Byte-for-byte what production serves today on both live funnels. The
    # derivation must reproduce the live sentence exactly, not merely something
    # that mentions the World Cup — this is a real-money page with an open
    # contest on it, and the fix is not allowed to reword it.
    assert_includes steps, "Choose 6 World Cup team matchups for your entry."
  end

  test "an NFL contest funnel names the NFL and never the World Cup" do
    get landing_page_path(nfl_funnel)
    assert_response :success

    steps = funnel_steps_text
    assert_match(NFL_WORDING, steps, "the NFL funnel must name the sport it is selling")
    assert_no_match(WORLD_CUP_WORDING, steps, "NFL funnel is showing World Cup copy")
    assert_includes steps, "Choose 6 NFL team matchups for your entry."
  end

  test "neither sport's funnel carries a hardcoded date or rehearsal wording" do
    get landing_page_path(@active)
    assert_response :success
    assert_no_match(REHEARSAL_NOISE, funnel_steps_text,
                    "World Cup funnel is showing a hardcoded date or simulated-games copy")

    get landing_page_path(nfl_funnel)
    assert_response :success
    assert_no_match(REHEARSAL_NOISE, funnel_steps_text,
                    "NFL funnel is showing a hardcoded date or simulated-games copy")
  end

  test "the funnel rulebook link follows the contest's sport" do
    # turf-totals-v1 documents the World Cup format and is still badged
    # "World Cup 2026"; turf-monster-v1 documents the NFL format (routes.rb).
    get landing_page_path(@active)
    assert_response :success
    assert_select "[data-test='funnel-footer'] a[href=?]", turf_totals_v1_path
    assert_select "[data-test='funnel-footer'] a[href=?]", turf_monster_v1_path, count: 0

    get landing_page_path(nfl_funnel)
    assert_response :success
    assert_select "[data-test='funnel-footer'] a[href=?]", turf_monster_v1_path
    assert_select "[data-test='funnel-footer'] a[href=?]", turf_totals_v1_path, count: 0
  end

  test "the sportless draft preview names no sport at all" do
    assert_nil @inactive.contest, "fixture guard: draft funnel has no contest wired"

    log_in_as(@admin) # inactive pages are admin-preview only
    get landing_page_path(@inactive)
    assert_response :success

    steps = funnel_steps_text
    # No contest means no slate means no sport to read. The copy must stay true
    # by naming neither, rather than guessing one and being wrong half the time.
    # The exact sentence, so the sport slot collapsing to a blank (a dropped
    # `compact`) reads as the defect it is rather than passing a loose match.
    assert_includes steps, "Choose 6 team matchups for your entry."
    assert_no_match(NFL_WORDING, steps, "draft preview invented a sport (NFL)")
    assert_no_match(WORLD_CUP_WORDING, steps, "draft preview invented a sport (World Cup)")
    assert_no_match(REHEARSAL_NOISE, steps, "draft preview is showing a hardcoded rehearsal date")

    # The sportless fallback is the sitewide canonical Rules target, so the
    # preview agrees with the navbar and footer rendered around it.
    assert_select "[data-test='funnel-footer'] a[href=?]", turf_monster_v1_path
  end

  test "survivor funnel keeps its own copy and gains no NFL wording" do
    survivor = Contest.create!(name: "WC Survivor Copy", game_type: "world_cup_survivor",
                               contest_type: "survivor_wc_free", status: "open")
    lp = LandingPage.create!(name: "Survivor Copy Funnel", headline: "Last One Standing",
                             contest: survivor, active: true)

    get landing_page_path(lp)
    assert_response :success

    steps = funnel_steps_text
    assert_match(/survive/i, steps, "survivor funnel must keep its survivor copy")
    assert_no_match(NFL_WORDING, steps, "NFL copy leaked into the survivor branch")
  end
end
