require "test_helper"

# [unit] The drop-notify card's header, on both sides of NextSlateDrop::DROPS_AT.
#
# The card opens whenever no contest is open to enter (NextContest.pick), and
# that stays true after the drop until the new slate's contests exist. Its
# header used to say "drops Tuesday morning" on both sides of the instant; it
# now says "Weeks 7–9 drops Oct 20", the date read from NextSlateDrop.
# Return values, not #rendered (it accumulates across calls).
class DropNotifyModalRenderTest < ActionView::TestCase
  def modal
    Nokogiri::HTML.fragment(render(partial: "modals/drop_notify"))
  end

  def cta_title
    html = render(partial: "pages/next_contest_cta", locals: { pick: NextContest::Pick.new(contest: nil), test_id: "v2-hero-cta" })
    # Read from the raw markup: Nokogiri's HTML4 parser drops an @-prefixed
    # attribute, so the click handler is not on the parsed node.
    html[/modals\.open\('drop-notify', \{ title: '([^']*)' \}\)/, 1]
  end

  test "one second before the drop the header says it drops Oct 20" do
    travel_to(NextSlateDrop::DROPS_AT - 1.second) do
      doc = modal
      assert_equal "false", doc.at_css('[data-test="drop-modal"]')["data-dropped"]
      assert_equal "Weeks 7–9 drops Oct 20", doc.at_css('[data-test="drop-modal-title"]').text
      assert_equal "The board goes live Tuesday, October 20 at 8:00 AM Mountain. Get one email when it does.",
                   doc.at_css('[data-test="drop-modal-subtitle"]').text
      refute_includes doc.at_css('[data-test="drop-modal-title"]').text, "live"
      assert_equal "Get notified when Weeks 7-9 drops", cta_title
    end
  end

  test "at the drop instant the header says the slate is live" do
    travel_to(NextSlateDrop::DROPS_AT) do
      doc = modal
      assert_equal "true", doc.at_css('[data-test="drop-modal"]')["data-dropped"]
      assert_equal "Weeks 7-9 is live", doc.at_css('[data-test="drop-modal-title"]').text
      assert_equal "The board went live Tuesday, October 20 at 8:00 AM Mountain.",
                   doc.at_css('[data-test="drop-modal-subtitle"]').text
      refute_includes doc.at_css('[data-test="drop-modal-title"]').text, "Tuesday"
      assert_equal "The Weeks 7-9 slate is live", cta_title
    end
  end

  # The card stays open across the instant: Alpine's `dropped` flips, so each
  # span's x-text must carry both strings and pick by that flag, and its server
  # text must equal the branch for the state it was drawn in.
  test "the header flips live with the countdown, and Alpine's first paint matches the server" do
    travel_to(NextSlateDrop::DROPS_AT - 1.hour) do
      title = modal.at_css('[data-test="drop-modal-title"]')
      assert_equal "dropped ? 'Weeks 7-9 is live' : 'Weeks 7–9 drops Oct 20'", title["x-text"]
      sub = modal.at_css('[data-test="drop-modal-subtitle"]')
      assert_match(/\Adropped \? 'The board went live .+\.' : 'The board goes live .+ Get one email when it does\.'\z/, sub["x-text"])
    end
  end

  # Alex, 2026-10-06: the header carries the date, so the modal's form drops
  # its visible label (kept for assistive tech) and stacks the button under a
  # full-width input; the page's own section keeps its joined row.
  test "the modal's form is stacked with an sr-only label; the header date comes from NextSlateDrop" do
    travel_to(NextSlateDrop::DROPS_AT - 1.day) do
      doc = modal
      label = doc.at_css('label[for="drop_modal_email"]')
      assert_equal "sr-only", label["class"]
      assert_equal "Notify me when Weeks 7-9 drops", label.text.strip
      row = doc.at_css('[data-test="drop-modal-row"]')
      assert_equal %w[flex flex-col items-stretch gap-3], row["class"].split
      assert_includes doc.at_css("#drop_modal_email")["class"].split, "w-full"
      assert_includes doc.at_css('[data-test="drop-modal-row"] button')["class"].split, "w-full"
      assert_equal "Weeks 7–9 drops #{NextSlateDrop.drops_at.strftime('%b %-d')}", doc.at_css('[data-test="drop-modal-title"]').text
      assert_includes doc.text, "One email when the slate drops. No spam."
      assert_equal "The board goes live Tuesday, October 20 at 8:00 AM Mountain. Get one email when it does.",
                   doc.at_css('[data-test="drop-modal-subtitle"]').text
    end
  end

  test "the page's own notify section keeps its visible label and joined row" do
    section = Nokogiri::HTML.fragment(render(partial: "pages/drop_notify_form", locals: { id_prefix: "drop_signup" }))
    assert_includes section.at_css('label[for="drop_signup_email"]')["class"].split, "block"
    assert_includes section.at_css('[data-test="v2-notify-row"]')["class"].split, "sm:flex-row"
  end
end
