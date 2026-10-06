require "test_helper"

# [component] /turf-monster-v2's template under a page variant: each copy
# field the variant sets replaces the page's own, the blank ones leave it, and
# the root carries the experiment, the variant and (for a counted visitor only)
# the beacon URL. Rendered straight from the template with the controller's
# ivars, no request.
class TurfMonsterV2VariantRenderTest < ActionView::TestCase
  include PageExperimentFixture

  setup do
    @experiment = create_page_experiment
    @teams = {}
    @next_contest = NextContest.pick
    @lobby = NextContest.lobby
    @live_showcase = nil
  end

  def render_page(variant_key, bot: false)
    assignment = @experiment.assign(param: variant_key, bot: bot)
    @page_variant = assignment.variant
    view.define_singleton_method(:page_experiment_assignment) { assignment }
    Nokogiri::HTML5.fragment(render(template: "pages/turf_monster_v2"))
  end

  def text(doc, test_id) = doc.at_css(%([data-test="#{test_id}"])).text.squish

  test "the fantasy-football variant swaps the headline, both subheads and the title" do
    doc = render_page("fantasy-football")
    root = doc.at_css('[data-test="turf-monster-v2"]')
    assert_equal %w[turf-monster-v2 fantasy-football /experiment-events],
                 [root["data-experiment"], root["data-variant"], root["data-experiment-beacon"]]
    assert_equal ["NFL Team", "Fantasy", "Football"], doc.css('[data-test="v2-headline"] span').map { |s| s.text.strip }
    assert_equal "Draft 6 NFL teams, not players. Desktop variant subhead.", text(doc, "v2-subhead-desktop")
    assert_equal "Draft 6 NFL teams. Mobile variant subhead.", text(doc, "v2-subhead-mobile")
    assert_equal "Turf Monster — NFL Team Fantasy Football", view.content_for(:title)
    assert_equal "Variant meta description.", view.content_for(:meta_description)
  end

  test "the control, which overrides nothing, renders the page's own copy" do
    doc = render_page("control")
    assert_equal ["Pick 6 teams.", "Stack points.", "Get paid."], doc.css('[data-test="v2-headline"] span').map { |s| s.text.strip }
    assert_match(/\AChoose 6 NFL teams\./, text(doc, "v2-subhead-desktop"))
    assert_equal "Every point your teams score counts, times their multiplier. Underdogs score big.", text(doc, "v2-subhead-mobile")
    assert_equal "Turf Monster — Pick 6 NFL Teams, Stack Points", view.content_for(:title)
  end

  test "a variant that sets only the headline keeps the page's subheads" do
    @experiment.variants.find_by!(key: "fantasy-football").update!(subhead_desktop: nil, subhead_mobile: nil, meta_title: nil)
    @experiment.reload
    doc = render_page("fantasy-football")
    assert_equal ["NFL Team", "Fantasy", "Football"], doc.css('[data-test="v2-headline"] span').map { |s| s.text.strip }
    assert_match(/\AChoose 6 NFL teams\./, text(doc, "v2-subhead-desktop"))
    assert_equal "Turf Monster — Pick 6 NFL Teams, Stack Points", view.content_for(:title)
  end

  test "a bot's page names its variant but carries no beacon" do
    root = render_page(nil, bot: true).at_css('[data-test="turf-monster-v2"]')
    assert_equal "control", root["data-variant"]
    assert_nil root["data-experiment-beacon"]
  end
end
