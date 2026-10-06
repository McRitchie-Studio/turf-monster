require "test_helper"

# [integration] /turf-monster-v2, the explainer that will become /about.
# Copy assertions are scoped to the page's data-test subtree: the layout ships
# site-wide meta that still describes the World Cup season.
class TurfMonsterV2PageTest < ActionDispatch::IntegrationTest
  def page_node
    node = css_select('[data-test="turf-monster-v2"]').first
    assert node, "the page must render its own subtree"
    node
  end

  def section_text(name)
    node = page_node.css(%([data-test="#{name}"])).first
    assert node, "section #{name} must render"
    node.text.squish
  end

  def assert_every_section_renders
    assert_response :success
    assert_includes section_text("v2-hero"), "Pick 6 teams. Stack points. Get paid."
    assert_includes section_text("v2-hero"), "NFL 2026"
    assert_includes section_text("v2-notify"), "Weeks 7-9 slate drops Tuesday morning"
    assert_includes section_text("v2-notify"), "One email when the slate drops. No spam."
    assert_includes section_text("v2-how-to-play"), "How to play"
    %w[Pick\ a\ contest Choose\ 6\ teams Climb\ the\ leaderboard\ and\ get\ paid].each do |step|
      assert_includes section_text("v2-how-to-play"), step
    end
    assert_includes section_text("v2-closing"), "Start playing"
  end

  test "renders every section signed out" do
    travel_to(NextSlateDrop::DROPS_AT - 3.days) do
      get turf_monster_v2_path
      assert_every_section_renders
    end
  end

  test "renders every section signed in" do
    log_in_as(users(:jordan))
    travel_to(NextSlateDrop::DROPS_AT - 3.days) do
      get turf_monster_v2_path
      assert_every_section_renders
    end
  end

  test "sets its own title and meta description" do
    get turf_monster_v2_path
    assert_select "title", /Pick 6 NFL Teams/
    assert_select %(meta[name="description"][content*="Weeks 7-9"])
  end

  test "the countdown's server fallback shows the remaining time before the drop" do
    travel_to(NextSlateDrop::DROPS_AT - (2.days + 5.hours + 7.minutes)) do
      get turf_monster_v2_path
      countdown = page_node.css('[data-test="v2-countdown"]').first
      # Four tiles; the no-JS frame is minute-precise, zero-padded, and its
      # seconds wait at 00 for Alpine.
      assert_equal %w[2 05 07 00], countdown.css("[x-text]").map { |n| n.text.strip }
      assert_equal %w[days hours minutes seconds], countdown.css("[x-text]").map { |n| n["x-text"] }
      assert_equal "off", countdown["aria-live"], "the countdown must not announce every tick"
      assert_equal "true", countdown.css('[data-test="v2-countdown-seconds"]').first["aria-hidden"]
      live = page_node.css('[data-test="v2-live"]').first
      assert_match(/display:\s*none/, live["style"].to_s, "the live state starts hidden before the drop")
      assert_includes page_node.to_html, NextSlateDrop.drops_at.utc.iso8601, "Alpine counts down to the same instant"
    end
  end

  test "after the drop the page says the slate is live and points at play" do
    travel_to(NextSlateDrop::DROPS_AT + 1.minute) do
      get turf_monster_v2_path
      live = page_node.css('[data-test="v2-live"]').first
      refute_match(/display:\s*none/, live["style"].to_s)
      assert_includes live.text, "The Weeks 7-9 slate is live"
      assert live.css(%(a[href="#{root_path}"])).any?
      refute_includes section_text("v2-hero"), "Get notified", "the hero stops promising a notification once the slate is out"
    end
  end

  test "multipliers in the how-to-play copy come from the shipped curve" do
    get turf_monster_v2_path
    step = page_node.css('[data-test="v2-turf-score-step"]').first.text
    assert_includes step, "1.0x"
    assert_includes step, "2.0x"
  end

  # The v1 operator rule: any mention of entry cost links to Getting Started.
  test "every USDC mention sits beside a Getting Started link, and the full rules are linked" do
    get turf_monster_v2_path
    page_node.css("p").select { |p| p.text.include?("USDC") }.each do |p|
      assert p.css(%(a[href="#{getting_started_path}"])).any?, "USDC copy must link to Getting Started: #{p.text.squish}"
    end
    assert page_node.css(%(a[href="#{turf_monster_v1_path}"])).any?
    assert page_node.css(%(a[href="#notify"])).any?, "the hero CTA scrolls to the notify section"
  end

  test "phones are decorative, with a caption beside each" do
    get turf_monster_v2_path
    phones = page_node.css('[data-test="phone-mock"]')
    assert_equal 2, phones.size
    phones.each { |phone| assert_equal "true", phone["aria-hidden"] }
    assert_equal 2, page_node.css("figure figcaption").size
  end

  test "renders when no Team rows exist" do
    Team.where(slug: TurfMonsterRules.team_slugs).delete_all
    get turf_monster_v2_path
    assert_response :success
    assert_includes page_node.css('[data-test="phone-pick-board"]').text, "San Francisco 49ers"
  end

  test "the no-JS round trip draws the success state from the flash" do
    post drop_signups_path, params: { email: "nojs@example.com" }
    assert_redirected_to turf_monster_v2_path(anchor: "notify")
    follow_redirect!
    success = page_node.css('[data-test="v2-notify-success"]').first
    refute_match(/display:\s*none/, success["style"].to_s)
    assert_includes success.text, "You’re on the list."
  end

  test "the /about page is untouched by this route" do
    get about_path
    assert_response :success
    refute_includes response.body, 'data-test="turf-monster-v2"'
  end
end
