require "test_helper"

# [component] The hero laptop's lobby preview, with contests and with none.
# Return values, not #rendered (it accumulates across calls).
class LaptopLobbyRenderTest < ActionView::TestCase
  setup do
    SeasonConfig.set_main_contest!(nil)
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
  end

  def lobby_html
    render(partial: "pages/laptop_lobby", locals: { lobby: NextContest.lobby })
  end

  def contest(slug, starts_at:, coming_soon: false)
    Contest.create!(name: slug.titleize, slug: slug, status: "open", coming_soon: coming_soon,
                    entry_fee_cents: 1900, max_entries: 29, contest_type: "standard",
                    slate: slates(:one), starts_at: starts_at)
  end

  test "with contests, it lists the real ones, decorative and inert" do
    contest("weeks-5-7", starts_at: 3.days.from_now)
    contest("weeks-7-9", starts_at: 9.days.from_now, coming_soon: true)
    doc = Nokogiri::HTML.fragment(lobby_html)

    laptop = doc.at_css('[data-test="laptop-mock"]')
    assert_equal "true", laptop["aria-hidden"]
    assert laptop.key?("inert")
    rows = doc.css('[data-test="laptop-lobby-row"]').map { |r| r.at_css("p").text.strip }
    assert_equal ["Weeks 5 7", "Weeks 7 9"], rows, "open before coming soon, as the lobby orders them"
    assert_includes doc.text, "Coming Soon", "a coming-soon contest is labelled truthfully"
  end

  test "a locked contest is never shown" do
    contest("locked-one", starts_at: 1.hour.ago)
    doc = Nokogiri::HTML.fragment(lobby_html)
    assert_empty doc.css('[data-test="laptop-lobby-row"]')
    refute_includes doc.text, "Locked One"
  end

  test "with no contests, the screen shows the next drop rather than a blank" do
    doc = Nokogiri::HTML.fragment(lobby_html)
    assert_empty doc.css('[data-test="laptop-lobby-row"]')
    drop = doc.at_css('[data-test="laptop-lobby-next-drop"]')
    assert drop, "the empty state is a card, not a blank screen"
    assert_includes drop.text, "Weeks 7-9"
  end

  test "the lobby query costs a bounded number of queries, whatever the count" do
    3.times { |i| contest("c-#{i}", starts_at: (i + 2).days.from_now) }
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { NextContest.lobby }
    assert_operator queries, :<=, 5, "contests + slates + attachments + one grouped count"
  end
end
