require "test_helper"

# FreeEntryMailer#ready — "your free entry is ready", sent once a hand-minted
# grant confirms (Admin::FreeEntriesController#grant; the when is pinned in
# free_entries_grant_test.rb, the what here).
class FreeEntryMailerTest < ActionMailer::TestCase
  setup do
    @user    = users(:sam)
    @user.update_columns(email: "fan@example.com")
    @contest = contests(:one)
  end

  test "goes to the player under the promised subject" do
    mail = FreeEntryMailer.ready(@user, @contest)

    assert_equal ["fan@example.com"], mail.to
    assert_equal "Your free Turf Monster entry is ready", mail.subject
  end

  test "links the contest and names it, in both parts" do
    mail = FreeEntryMailer.ready(@user, @contest)
    url  = Rails.application.routes.url_helpers.contest_url(@contest.slug, **ActionMailer::Base.default_url_options)

    assert_includes mail.html_part.body.to_s, url
    assert_includes mail.text_part.body.to_s, url
    assert_includes mail.text_part.body.to_s, @contest.name
  end

  test "with no contest it still renders and links home" do
    mail = FreeEntryMailer.ready(@user, nil)

    assert_includes mail.text_part.body.to_s, "Pick a contest"
    assert_includes mail.text_part.body.to_s, Rails.application.routes.url_helpers.root_url(**ActionMailer::Base.default_url_options)
  end
end
