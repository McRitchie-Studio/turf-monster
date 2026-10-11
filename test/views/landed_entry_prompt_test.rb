require "test_helper"

# [component] shared/_landed_entry_prompt: one card per landed row, each with
# the contest, the reason, the deadline and two plain POST forms, and nothing
# that needs a script to be safe or to work. With no rows it renders nothing.
class LandedEntryPromptViewTest < ActionView::TestCase
  include LandedEntryPromptHelper

  setup do
    @contest = contests(:one)
    @entry = @contest.entries.create!(user: users(:sam), status: :cart, payment_state: "draft")
    @entry.update_columns(payment_state: "landed", payment_refusal_code: "entry_limit_reached",
                          payment_landed_at: Time.zone.parse("2026-10-07 20:00 -04:00"))
  end

  def render_prompt(rows)
    @landed_entry_prompts = rows
    Nokogiri::HTML5.fragment(render(partial: "shared/landed_entry_prompt"))
  end

  test "one landed row: the contest, the reason, the deadline and two plain forms" do
    card = render_prompt([@entry]).at_css("[data-landed-entry-prompt='#{@entry.slug}']")

    assert_includes card.text, @contest.name
    assert_includes card.text, "this contest's entry limit was reached before we could finish your entry"
    assert_equal "Sun, Oct 11 at 9:00 AM ET", card.at_css("[data-landed-entry-deadline]").text.strip
    assert_equal card["aria-labelledby"], card.at_css("h2")["id"]

    forms = card.css("form")
    assert_equal [reauthorize_landed_entry_path(@entry.slug), decline_landed_entry_path(@entry.slug)], forms.map { |f| f["action"] }
    assert(forms.all? { |f| f["method"] == "post" && f.at_css("button[type=submit]") })
  end

  test "the card carries no Alpine and no script: it is safe before anything loads" do
    html = render_prompt([@entry]).to_html

    refute_match(/x-data|x-show|x-on:|@click|<script|onclick=/, html)
  end

  test "an unknown refusal code reads the general sentence" do
    @entry.update_columns(payment_refusal_code: "verification_refused")

    assert_includes render_prompt([@entry]).text, "Solana, but we could not finish your entry."
  end

  # Alex 2026-10-10: a decline is a decline; promise the player nothing.
  PROMISES = /in touch|finish the entry|refund|we will|our team/i

  test "the card states facts and promises nothing, with support as an offer" do
    text = render_prompt([@entry]).text.squish

    refute_match PROMISES, text
    assert_includes text, "Yes tries the entry again, with no new charge. No leaves it out for good."
    assert_includes text, "contact support@turfmonster.media"
  end

  test "CONTROL: no rows, no card" do
    assert_empty render_prompt([]).css("[data-landed-entry-prompt]")
  end
end
