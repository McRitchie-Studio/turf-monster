require "test_helper"

# [component] + [integration] The hero laptop's contest-live snapshot: a live
# contest, a finished one, and none (the lobby fallback). Plus the privacy
# rules for a public marketing page: signed-out chrome whoever is signed in,
# no chat bodies, no emails or wallets, usernames only.
class LaptopLiveRenderTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_main_contest!(nil)
    Message.delete_all
    Selection.delete_all
    Entry.delete_all
    Contest.delete_all
    @slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6-laptop", sport: "nfl",
                           starts_at: 20.days.ago)
  end

  def nfl_contest(slug, starts_at:, status: "open")
    Contest.create!(name: slug.titleize, slug: slug, status: status, entry_fee_cents: 1900, max_entries: 29,
                    contest_type: "standard", slate: @slate, starts_at: starts_at)
  end

  def laptop
    get turf_monster_v2_path
    assert_response :success
    node = css_select('[data-test="laptop-mock"]').first
    assert node, "the laptop renders"
    node
  end

  test "a contest being played shows its live page, with the top entries by score" do
    contest = nfl_contest("weeks-4-6-live", starts_at: 2.days.ago)
    contest.entries.create!(user: users(:jordan), status: :active).update_column(:score, 120.5)
    contest.entries.create!(user: users(:sam), status: :active).update_column(:score, 140.0)

    node = laptop
    live = node.at_css('[data-test="laptop-live"]')
    assert live, "the live snapshot draws"
    assert live.key?("x-ignore"), "static: Alpine never walks it"
    assert_includes live.text, "Weeks 4 6 Live"
    assert_equal %w[sam_test jordan_test], live.css('[data-test="laptop-live-leader"]').map { |li| li.css("span")[1].text.strip }
    assert_includes live.text, "140.0"
  end

  test "with nothing live, the most recently finished NFL contest shows" do
    nfl_contest("older-final", starts_at: 30.days.ago, status: "settled")
    nfl_contest("newer-final", starts_at: 10.days.ago, status: "settled")
    showcase = NextContest.live_showcase
    assert_equal "newer-final", showcase.contest.slug
    refute showcase.live?
    assert_includes laptop.at_css('[data-test="laptop-live"]').text, "Newer Final"
  end

  test "with no live or finished contest, the laptop falls back to the lobby" do
    nfl_contest("upcoming", starts_at: 5.days.from_now)
    assert_nil NextContest.live_showcase
    node = laptop
    assert_nil node.at_css('[data-test="laptop-live"]')
    assert node.at_css('[data-test="laptop-lobby-row"]') || node.at_css('[data-test="laptop-lobby-next-drop"]')
  end

  # PRIVACY. Signed in as an admin with a username, email and wallet, the
  # laptop still draws the signed-out chrome and none of the viewer's details;
  # a leader with no username is "Player N", never an email prefix or wallet;
  # and no chat message body appears.
  test "signed in, the laptop shows nothing of the viewer and no chat" do
    viewer = users(:alex)
    viewer.update_columns(web3_solana_address: "So1anaViewerAddre55xxxxxxxxxxxxxxxxxxxxxxxx", seeds: 777)
    contest = nfl_contest("weeks-4-6-private", starts_at: 2.days.ago)
    nameless = users(:casey)
    nameless.update_columns(username: nil)
    contest.entries.create!(user: nameless, status: :active).update_column(:score, 99.0)
    Message.create!(contest: contest, user: users(:jordan), body: "secret chat body do not show")

    log_in_as(viewer)
    html = laptop.to_html
    [viewer.username, viewer.email, viewer.web3_solana_address, "777", "secret chat body",
     nameless.email.to_s, nameless.email.to_s.split("@").first.capitalize].reject(&:blank?).each do |private_bit|
      refute_includes html, private_bit, "the laptop must not show #{private_bit.inspect}"
    end
    assert_includes html, "Player 1", "a player with no username is anonymous"
    assert_includes Nokogiri::HTML.fragment(html).at_css('[data-test="laptop-live"]').text, "Contests"
  end
end
