require "test_helper"

# [component] The shared engine emails page, as turf-monster renders it.
#
# The engine owns this view, so this does not re-test the engine's own suite.
# What it pins is the SEAM: that turf-monster's registry data reaches the page,
# and that the page it reaches is the ENGINE's — the app deleted its own
# Admin::EmailsController and the three routes that owned the admin_emails /
# admin_email helper names, and a stray local route would silently take them back.
class AdminEmailsRenderTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  test "the page is the engine's, not a local one" do
    route = Rails.application.routes.routes.find { |r| r.name == "admin_emails" }
    assert_equal "studio/emails", route.defaults[:controller]

    refute Object.const_defined?("Admin::EmailsController"),
      "the local email manager was retired — two pages is what this change removes"
  end

  # This counts BANNERS, not <img> tags — because how the engine draws a banner
  # is the engine's business, and it changes. A flat banner (every email THIS
  # app registers, each with its own committed artwork) renders as an <img>. An
  # email whose artwork the ENGINE owns and whose mailer layers live text over
  # it renders inside an <iframe>: the banner is its own <table>, and nesting
  # one directly in a list row would nest rows inside rows.
  #
  # `assert_select "tbody img", count: entries.size` asserted the DRAWING
  # TECHNIQUE — one <img> per row — so the first shared-catalog email to arrive
  # layered turned this red (9 rows, 8 images) for an upstream fact that broke
  # nothing here. Worse, it is a count of a per-row element that is not
  # guaranteed to render at all: an email with no artwork shows the engine's
  # "No banner" placeholder, a bare <div>.
  #
  # What must stay true is narrower and permanent: every registered email gets a
  # row, that row names the email, and that row's banner cell holds real
  # artwork rather than the placeholder.
  test "the table renders one row per registered email, name and banner together" do
    get admin_emails_path
    assert_response :success

    entries = Studio::EmailCatalog.entries
    refute_empty entries, "this app registers its emails at boot — an empty registry is the bug"

    rows = css_select("tbody tr")
    assert_equal entries.size, rows.size, "one row per registered email"

    entries.each do |entry|
      row = row_for(rows, entry.key)
      assert row, "#{entry.key} should have a row linking to its own page"
      assert_includes row.text, entry.label,
        "#{entry.key} should be identifiable by name"

      # Whether an email HAS artwork is the registry's business, not this
      # page's: a shared-catalog email may ship with none, and the engine's
      # "No banner" placeholder is the correct render for it. So the banner
      # claim is made only where there is a banner to make it about.
      next if Studio::EmailCatalog.preview_url(entry.key).blank?

      # The banner is the first cell in every version of this page the engine
      # has shipped. `img, iframe` is "artwork, however it is drawn" — the
      # placeholder is a bare <div>, so it fails this and nothing else does.
      assert row.css("td").first.css("img, iframe").any?,
        "#{entry.key} has artwork registered but showed no banner"
    end

    # ANTI-VACUITY. The check above tolerates either drawing technique, which on
    # its own would also tolerate the page drawing NOTHING this app owns. So pin
    # one row concretely: turf-monster's own committed artwork, resolved through
    # turf-monster's asset pipeline, reaching the ENGINE's list page as a real
    # image. If this app ever layers that email, this expectation moves to the
    # iframe — deliberately, not silently.
    winnings = row_for(rows, "contest_winnings")
    assert winnings, "contest_winnings should have a row"
    assert winnings.css("img[src*='winnings-banner']").any?,
      "this app's own banner artwork should reach the engine's list page"
  end

  test "each row links to that email's own preview page" do
    get admin_emails_path

    Studio::EmailCatalog.keys.each do |key|
      assert_select "a[href=?]", admin_email_path(key)
    end
  end

  test "the marketing email is badged and the transactional ones are not" do
    get admin_emails_path

    assert_select "tbody", text: /Marketing/, count: 1
  end

  test "an email's page renders its banner and its preview frame" do
    get admin_email_path("contest_winnings")
    assert_response :success

    assert_select "img[src*=?]", "winnings-banner"
    assert_select "iframe[src=?]", admin_email_raw_path("contest_winnings")
  end

  private

  # The row for one email, found by the link its name carries. The name-link is
  # the one element the engine renders exactly once per row in every version of
  # this page — the banner, the badge and the upload button are all conditional.
  def row_for(rows, key)
    href = admin_email_path(key)
    rows.find { |row| row.css("a[href='#{href}']").any? }
  end
end
