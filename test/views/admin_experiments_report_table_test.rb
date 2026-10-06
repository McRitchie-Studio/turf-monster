require "test_helper"

# [component] The side-by-side table on /admin/experiments
# (admin/experiments/_report_table): one row per variant with its counts and
# per-100 rates, the control marked, and the significance hint per challenger.
class AdminExperimentsReportTableTest < ActionView::TestCase
  include PageExperimentFixture

  setup do
    @experiment = create_page_experiment
    @today = Date.current
  end

  def event(variant, event, n)
    ExperimentEvent.record(experiment_slug: "turf-monster-v2", variant_key: variant, event: event,
                           visitor_id: format("00000000-0000-4000-8000-%012d", n))
  end

  # ActionView::TestCase#rendered accumulates, so parse the return value.
  def render_table(report = ExperimentReport.new(@experiment))
    Nokogiri::HTML5.fragment(render(partial: "admin/experiments/report_table", locals: { report: report }))
  end

  def cell(doc, variant, name)
    doc.at_css(%([data-variant-row="#{variant}"] [data-cell="#{name}"])).text.squish
  end

  test "one row per variant, in order, the control marked" do
    doc = render_table
    assert_equal %w[control fantasy-football], doc.css("[data-variant-row]").map { |r| r["data-variant-row"] }
    assert_includes doc.at_css('[data-variant-row="control"]').text, "control"
    assert_equal "Baseline", cell(doc, "control", "significance")
  end

  test "every CTA has a column, labelled as the page labels it" do
    doc = render_table
    headers = doc.css("thead th").map { |th| th.text.squish }
    assert_includes headers, "Play Turf Monster taps"
    assert_includes headers, "Notify me taps"
    assert_includes headers, "Watch updates live taps"
  end

  test "counts and per-100 rates per arm" do
    event("control", "visit", 1)
    event("control", "visit", 2)
    event("control", "cta:play", 1)
    event("fantasy-football", "visit", 3)
    DropSignup.create!(email: "a@example.com", slate_key: "s", experiment_slug: "turf-monster-v2", variant_key: "fantasy-football")

    doc = render_table
    assert_equal "2", cell(doc, "control", "visitors")
    assert_equal "2", cell(doc, "control", "hits")
    assert_equal "50.0 / 100", cell(doc, "control", "cta-play-rate")
    assert_equal "1", cell(doc, "fantasy-football", "visitors")
    assert_equal "100.0 / 100", cell(doc, "fantasy-football", "email-rate")
    assert_equal "0.0 / 100", cell(doc, "control", "email-rate"), "visitors and no signups is a real zero"
  end

  test "an arm with no visitors shows a dash for its rates, not a zero" do
    doc = render_table
    assert_equal "— / 100", cell(doc, "fantasy-football", "email-rate")
  end

  test "the hint says not significant yet below the minimum sample" do
    event("control", "visit", 1)
    event("fantasy-football", "visit", 2)
    doc = render_table
    node = doc.at_css('[data-variant-row="fantasy-football"] [data-cell="significance"]')
    assert_equal "not_yet", node["data-verdict"]
    assert_includes node.text, "Not significant yet: needs #{ExperimentReport::MIN_VISITORS} visitors in each arm"
  end
end
