require "test_helper"

# [component] The /admin/referrals funnel table, rendered with and without an
# email-signup source (DropSignup ships in its own task; absent must read as
# "not collected", never as a column of zeros).
class AdminReferralsTableTest < ActionView::TestCase
  Row = ReferralReport::Row

  # A report double: the partial reads only these methods.
  FakeReport = Struct.new(:rows, :emails, :window, :hidden, keyword_init: true) do
    def emails? = emails
    def hidden_references = hidden.to_i
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
    assert_equal "40.0", row.at_css("[data-cell='email-rate']").text.strip
    assert_equal "30.0", row.at_css("[data-cell='account-rate']").text.strip
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

  # Signups are dated by signup, visitors by click, so a window can hold more
  # signups than visitors. The column says "per 100 visitors" and a footnote
  # says why it can pass 100; it is never drawn as a percentage, and never
  # capped (a cap would draw 100 for both 100 and 250).
  test "a rate over 100 is drawn as signups per 100 visitors, uncapped, with a footnote" do
    late = Row.new(reference: "late", clicks: 2, visitors: 2, top_paths: [], email_signups: 5, account_signups: 3)
    doc = render_table(FakeReport.new(rows: [late], emails: true, window: "7"))
    row = doc.at_css("[data-reference-row='late']")
    assert_equal "250.0", row.at_css("[data-cell='email-rate']").text.strip
    assert_equal "150.0", row.at_css("[data-cell='account-rate']").text.strip
    refute_includes doc.css("[data-cell]").map(&:text).join, "%"
    assert_equal "Emails per 100 visitors*", doc.at_css("th[data-col='email-rate']").text.strip
    assert_equal "Accounts per 100 visitors*", doc.at_css("th[data-col='account-rate']").text.strip
    note = doc.at_css("[data-rate-footnote]")
    assert note, "the footnote renders under a table with rows"
    assert_includes note.text, "can pass 100"
  end

  test "no rate footnote under an empty table" do
    refute render_table(FakeReport.new(rows: [], emails: false, window: "30")).at_css("[data-rate-footnote]")
  end

  test "an empty window says so" do
    doc = render_table(FakeReport.new(rows: [], emails: false, window: "30"))
    assert doc.at_css("[data-referral-empty]")
  end

  test "references past the cap are counted under the table" do
    doc = render_table(FakeReport.new(rows: [tiktok], emails: false, window: "30", hidden: 1234))
    note = doc.at_css("[data-referral-hidden]")
    assert note, "the hidden-count note renders"
    assert_includes note.text, "top #{ReferralReport::TOP_REFERENCES}"
    assert_includes note.text, "1,234 more"
  end

  test "no note when nothing is hidden" do
    refute render_table(FakeReport.new(rows: [tiktok], emails: false, window: "30")).at_css("[data-referral-hidden]")
  end

  # The per-day table for one reference.
  DailyReport = Struct.new(:window, :emails, keyword_init: true) do
    def emails? = emails
  end

  def render_daily(reference, daily)
    Nokogiri::HTML5.fragment(render(partial: "admin/referrals/daily",
                                    locals: { report: DailyReport.new(window: "all", emails: false), reference: reference, daily: daily }))
  end

  def day(date)
    ReferralReport::DayRow.new(date: date, clicks: 1, visitors: 1, email_signups: nil, account_signups: 0)
  end

  test "the per-day heading lets a long reference wrap instead of scrolling the page" do
    long = "a" * 120
    doc = render_daily(long, [])
    ref = doc.at_css("[data-daily-reference]")
    assert_equal long, ref.text
    assert_includes ref["class"].split, "break-all", "a token with no spaces must break"
    assert_includes ref.parent["class"].split, "min-w-0", "the heading must be allowed to shrink in its flex row"
  end

  test "per-day dates carry the year, so an all-time window spanning years is unambiguous" do
    doc = render_daily("tiktok", [day(Date.new(2027, 1, 2)), day(Date.new(2026, 12, 31))])
    dates = doc.css("tr[data-day] td:first-child").map { |td| td.text.strip }
    assert_equal ["Sat Jan 2, 2027", "Thu Dec 31, 2026"], dates
  end
end
