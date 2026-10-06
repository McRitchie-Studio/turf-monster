require "test_helper"

# [component] The /admin/referrals funnel table, rendered with and without an
# email-signup source (DropSignup ships in its own task; absent must read as
# "not collected", never as a column of zeros).
class AdminReferralsTableTest < ActionView::TestCase
  Row = ReferralReport::Row

  # A report double: the partial reads only these four methods.
  FakeReport = Struct.new(:rows, :emails, :window, keyword_init: true) do
    def emails? = emails
  end

  def tiktok(email: nil)
    Row.new(reference: "tiktok", clicks: 12, visitors: 10, top_paths: [["/", 8], ["/lp/tiktok", 2]],
            email_signups: email, account_signups: 3)
  end

  # ActionView::TestCase#rendered accumulates, so parse the return value.
  def render_table(report)
    Nokogiri::HTML5.fragment(render(partial: "admin/referrals/table", locals: { report: report }))
  end

  test "with emails: the email columns and rate render per row" do
    doc = render_table(FakeReport.new(rows: [tiktok(email: 4)], emails: true, window: "30"))

    row = doc.at_css("[data-reference-row='tiktok']")
    assert_equal "12", row.at_css("[data-cell='clicks']").text.strip
    assert_equal "4", row.at_css("[data-cell='email']").text.strip
    assert_equal "40.0%", row.at_css("[data-cell='email-rate']").text.strip
    assert_equal "30.0%", row.at_css("[data-cell='account-rate']").text.strip
    assert doc.at_css("th[data-col='email']")
    assert_nil doc.at_css("[data-email-absent]")
  end

  test "without emails: no email columns, and a note says why" do
    doc = render_table(FakeReport.new(rows: [tiktok], emails: false, window: "30"))

    assert_nil doc.at_css("th[data-col='email']")
    assert_nil doc.at_css("[data-cell='email']")
    assert doc.at_css("[data-email-absent]")
    assert_equal "3", doc.at_css("[data-reference-row='tiktok'] [data-cell='accounts']").text.strip
  end

  test "each reference links to its per-day table in the same window" do
    doc = render_table(FakeReport.new(rows: [tiktok], emails: false, window: "7"))
    href = doc.at_css("[data-reference-row='tiktok'] a")["href"]
    assert_includes href, "reference=tiktok"
    assert_includes href, "days=7"
  end

  test "top landing paths list with their counts" do
    doc = render_table(FakeReport.new(rows: [tiktok], emails: false, window: "30"))
    text = doc.at_css("[data-reference-row='tiktok']").text.squish
    assert_includes text, "/lp/tiktok (2)"
  end

  test "a row with no visitors shows a dash, not a rate" do
    row = Row.new(reference: "newsletter", clicks: 0, visitors: 0, top_paths: [], email_signups: 2, account_signups: 0)
    doc = render_table(FakeReport.new(rows: [row], emails: true, window: "30"))
    assert_equal "—", doc.at_css("[data-reference-row='newsletter'] [data-cell='email-rate']").text.strip
  end

  test "an empty window says so" do
    doc = render_table(FakeReport.new(rows: [], emails: false, window: "30"))
    assert doc.at_css("[data-referral-empty]")
  end
end
