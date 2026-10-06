require "test_helper"

# [component] The /admin/short_links table (admin/short_links/_list): the full
# short URL behind a copy button, target, reference, clicks, status, and the
# disable/enable action, for live, disabled and empty lists.
class AdminShortLinksListTest < ActionView::TestCase
  def link(token, reference: "#{token}-bio", target: "/turf-monster-v2", disabled: false)
    CampaignLink.create!(token: token, target_path: target, reference: reference,
                         expires_at: (disabled ? 1.minute.ago : nil))
  end

  # ActionView::TestCase#rendered accumulates, so parse the return value.
  def render_list(links, clicks = {})
    Nokogiri::HTML5.fragment(render(partial: "admin/short_links/list",
                                    locals: { short_links: links, clicks: clicks }))
  end

  test "a live link: full short URL to copy, target, reference, clicks and a Disable action" do
    doc = render_list([link("tt", reference: "tiktok-bio")], { "tiktok-bio" => 1234 })
    row = doc.at_css("[data-short-link='tt']")

    assert_equal "http://test.host/l/tt", row.at_css("[data-copy-text]")["data-copy-text"]
    assert_equal "test.host/l/tt", row.at_css("code").text.strip, "the scheme is dropped from the display only"
    assert_equal "/turf-monster-v2", row.at_css("a[target=_blank]")["href"]
    assert_includes row.at_css("a[href*='admin/referrals']")["href"], "reference=tiktok-bio"
    assert_equal "1,234", row.at_css("[data-clicks]").text.strip
    assert_includes row.text, "LIVE"
    assert_equal "Disable", row.at_css("form button, form input[type=submit]").then { |b| b.text.presence || b["value"] }.strip
    assert row.at_css("form[action$='/admin/short_links/tt/toggle']")
  end

  test "a link nobody clicked shows zero, not a blank" do
    doc = render_list([link("ig")])
    assert_equal "0", doc.at_css("[data-short-link='ig'] [data-clicks]").text.strip
  end

  test "a disabled link reads DISABLED and offers Enable, with no confirm" do
    doc = render_list([link("old", disabled: true)])
    row = doc.at_css("[data-short-link='old']")
    assert_includes row.text, "DISABLED"
    button = row.at_css("form button, form input[type=submit]")
    assert_equal "Enable", (button.text.presence || button["value"]).strip
    assert_nil row.at_css("[data-turbo-confirm]")
  end

  test "an empty list says so" do
    doc = render_list([])
    assert_includes doc.at_css("[data-short-links]").text, "No short links yet"
  end
end
