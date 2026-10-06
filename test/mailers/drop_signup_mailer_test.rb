require "test_helper"

# [component] DropSignupMailer: the two drop emails, each in a new-player and an
# existing-player variant chosen at SEND time, all with the drop time in
# Mountain, a signed one-click unsubscribe and the RFC 8058 headers.
class DropSignupMailerTest < ActionMailer::TestCase
  KEY = NextSlateDrop::SLATE_KEY

  def url_helpers = Rails.application.routes.url_helpers
  def url_opts = ActionMailer::Base.default_url_options

  def signup(email = "new-fan@example.com", **attrs)
    DropSignup.create!(email: email, slate_key: KEY, source: "tiktok", **attrs)
  end

  def bodies(mail) = [mail.html_part.body.to_s, mail.text_part.body.to_s]

  # --- shared copy ------------------------------------------------------------

  test "the confirmation names the drop time on Mountain wall clocks, never UTC" do
    mail = DropSignupMailer.confirmation(signup)
    assert_equal ["new-fan@example.com"], mail.to
    assert_equal "You're on the list for Weeks 7–9", mail.subject
    bodies(mail).each do |body|
      assert_includes body, "Tuesday, October 20 at 8:00 AM MDT"
      refute_includes body, "14:00"
    end
  end

  test "the drop time comes from NextSlateDrop, not the template" do
    later = NextSlateDrop.wall_clock(Date.new(2026, 11, 10), 9)
    NextSlateDrop.stub(:drops_at_label, later.strftime("%A, %B %-d at %-l:%M %p %Z")) do
      assert_includes DropSignupMailer.confirmation(signup).text_part.body.to_s, "Tuesday, November 10 at 9:00 AM MST"
    end
  end

  test "every variant of both emails carries the signed unsubscribe link and the one-click headers" do
    row = signup
    url = url_helpers.drop_unsubscribe_url(token: row.unsubscribe_token, **url_opts)
    %i[confirmation announcement].each do |kind|
      DropSignupMailer::VARIANTS.each do |variant|
        mail = DropSignupMailer.public_send(kind, row, variant: variant)
        bodies(mail).each { |body| assert_includes body, url, "#{kind}/#{variant}" }
        assert_equal "<#{url}>", mail["List-Unsubscribe"].value
        assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].value
      end
    end
  end

  test "the announcement subject says the drop is live" do
    assert_equal "Weeks 7–9 is live", DropSignupMailer.announcement(signup).subject
  end

  # --- variant selection (at send time) ---------------------------------------

  test "an address with no account gets the new-player copy" do
    mail = DropSignupMailer.confirmation(signup)
    assert_includes mail.text_part.body.to_s, "Finish setting up your account"
    refute_includes mail.text_part.body.to_s, "View contests"
  end

  test "a signed-in visitor's signup gets the existing-player copy" do
    mail = DropSignupMailer.confirmation(signup("other@example.com", user: users(:jordan)))
    text = mail.text_part.body.to_s
    assert_includes text, "Get ready for Weeks 7–9"
    refute_match(/set(ting)? up your account|create your account|sign(s)? (you )?(up|in)/i, text, "no sign-up language")
  end

  test "an address an account holds matches case-insensitively" do
    users(:sam).update_columns(email: "Sam.Fan@Example.com")
    mail = DropSignupMailer.confirmation(signup("sam.fan@example.com"))
    assert_includes mail.text_part.body.to_s, "Get ready for Weeks 7–9"
  end

  # The outbox renders the mail when its job runs. An address that signs up
  # for an account between the enqueue and the send gets the account copy.
  test "an account created after the enqueue is seen at send time" do
    row = signup("late@example.com")
    Studio.stub(:local_email_capture?, false) do
      row.deliver_confirmation!
      User.create!(email: "late@example.com")
      EmailDelivery.find_by!(to: "late@example.com").deliver_now!
    end
    text = ActionMailer::Base.deliveries.last.text_part.body.to_s
    assert_includes text, "Get ready for Weeks 7–9"
    refute_includes text, "Finish setting up your account"
    assert_equal 0, Studio::Link.magic_links.where(linkable: row).count, "no sign-up link minted for an account holder"
  end

  # --- CTA URLs ----------------------------------------------------------------

  test "new-player confirmation: a live magic link for this address, crediting the signup's source" do
    row = signup
    mail = DropSignupMailer.confirmation(row).message # render now: the link is minted at render
    link = Studio::Link.magic_links.find_by!(linkable: row)

    assert_equal "new-fan@example.com", link.email
    assert link.live?
    refute link.metadata["age_attested"], "nobody attested for the recipient"
    magic = url_helpers.link_url(token: link.token, reference: "tiktok", **url_opts)
    assert_includes mail.text_part.body.to_s, "Finish setting up your account: #{magic}"
    assert_includes mail.html_part.body.to_s, %(href="#{magic}")
    assert_includes mail.text_part.body.to_s, url_helpers.turf_monster_v2_url(anchor: "how-to-play", **url_opts)
  end

  test "existing-player confirmation: how to play, then the contests page" do
    mail = DropSignupMailer.confirmation(signup("x@example.com", user: users(:jordan)))
    text = mail.text_part.body.to_s
    assert_includes text, "Get ready for Weeks 7–9: #{url_helpers.turf_monster_v2_url(anchor: 'how-to-play', **url_opts)}"
    assert_includes text, "View contests: #{url_helpers.contests_url(**url_opts)}"
  end

  test "new-player announcement: a magic link that lands on the next contest" do
    row = signup
    contest = contests(:one)
    NextContest.stub(:pick, NextContest::Pick.new(contest: contest)) do
      mail = DropSignupMailer.announcement(row)
      assert_includes mail.text_part.body.to_s, "Create your account and play: "
    end
    link = Studio::Link.magic_links.find_by!(linkable: row)
    assert_equal url_helpers.contest_path(contest.slug), link.return_to
  end

  test "existing-player announcement: Play Turf Monster to the next contest, tagged with the email reference" do
    contest = contests(:one)
    NextContest.stub(:pick, NextContest::Pick.new(contest: contest)) do
      mail = DropSignupMailer.announcement(signup("x@example.com", user: users(:jordan)))
      expected = url_helpers.contest_url(contest.slug, reference: NextSlateDrop::EMAIL_REFERENCE, **url_opts)
      assert_includes mail.text_part.body.to_s, "Play Turf Monster: #{expected}"
    end
  end

  test "with no open contest the existing-player announcement falls back to the explainer" do
    NextContest.stub(:pick, NextContest::Pick.new(contest: nil)) do
      mail = DropSignupMailer.announcement(signup("x@example.com", user: users(:jordan)))
      expected = url_helpers.turf_monster_v2_url(reference: NextSlateDrop::EMAIL_REFERENCE, **url_opts)
      assert_includes mail.text_part.body.to_s, "Play Turf Monster: #{expected}"
    end
  end

  test "a preview on an unsaved signup mints nothing" do
    preview = DropSignup.new(email: "p@example.com", slate_key: KEY)
    assert_no_difference -> { Studio::Link.count } do
      DropSignupMailer.confirmation(preview, variant: :new_player).message
      DropSignupMailer.announcement(preview, variant: :new_player).message
    end
  end
end
