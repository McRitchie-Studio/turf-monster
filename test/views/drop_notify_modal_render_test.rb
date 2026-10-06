require "test_helper"

# [unit] The drop-notify card's header, on both sides of NextSlateDrop::DROPS_AT.
#
# The card opens whenever no contest is open to enter (NextContest.pick), and
# that stays true after the drop until the new slate's contests exist. Its
# header used to say "drops Tuesday morning" on both sides of the instant.
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

  test "one second before the drop the header says it drops Tuesday morning" do
    travel_to(NextSlateDrop::DROPS_AT - 1.second) do
      doc = modal
      assert_equal "false", doc.at_css('[data-test="drop-modal"]')["data-dropped"]
      assert_equal "Weeks 7-9 drops Tuesday morning", doc.at_css('[data-test="drop-modal-title"]').text
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
      assert_equal "dropped ? 'Weeks 7-9 is live' : 'Weeks 7-9 drops Tuesday morning'", title["x-text"]
      sub = modal.at_css('[data-test="drop-modal-subtitle"]')
      assert_match(/\Adropped \? 'The board went live .+\.' : 'The board goes live .+ Get one email when it does\.'\z/, sub["x-text"])
    end
  end
end
