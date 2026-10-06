require "test_helper"

# [integration] /admin/drop_signups/announcement: preview, exact count, and a
# manual Send that is admin-only, refuses before the drop without "send early",
# and refuses unless the operator typed the current count.
class Admin::DropAnnouncementTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  KEY = NextSlateDrop::SLATE_KEY

  setup do
    DropSignup.create!(email: "a@example.com", slate_key: KEY)
    DropSignup.create!(email: "b@example.com", slate_key: KEY, user: users(:jordan))
    DropSignup.create!(email: "done@example.com", slate_key: KEY, notified_at: 1.day.ago)
    DropSignup.create!(email: "gone@example.com", slate_key: KEY, unsubscribed_at: 1.day.ago)
    DropSignup.create!(email: "next@example.com", slate_key: "nfl-2026-weeks-10-12")
  end

  def before_drop(&) = travel_to(NextSlateDrop.drops_at - 1.day, &)
  def after_drop(&)  = travel_to(NextSlateDrop.drops_at + 1.hour, &)

  test "requires admin, for the page, the send and the previews" do
    [nil, users(:jordan)].each do |viewer|
      reset!
      log_in_as(viewer) if viewer
      get admin_drop_signups_announcement_path
      assert_response :redirect
      post admin_drop_signups_announcement_path, params: { confirm_count: "2", send_early: "1" }
      assert_response :redirect
      get admin_drop_signups_announcement_preview_path(email: "announcement", variant: "new_player")
      assert_response :redirect
    end
    assert_no_enqueued_jobs(only: DropAnnouncementJob)
    assert_nil DropSignup.find_by(email: "a@example.com").notified_at
  end

  test "shows the exact recipient count: this drop, not notified, not unsubscribed" do
    log_in_as(users(:alex))
    get admin_drop_signups_announcement_path
    assert_response :success
    assert_select '[data-test="announcement-recipient-count"]', text: "2"
    assert_select '[data-test="announcement-claimed"]', text: "1"
  end

  test "the page embeds all four previews, and each renders" do
    log_in_as(users(:alex))
    get admin_drop_signups_announcement_path
    pairs = %w[announcement confirmation].product(%w[new_player existing_player])
    pairs.each { |kind, variant| assert_select %([data-test="announcement-preview-#{kind}-#{variant}"]) }
    pairs.each do |kind, variant|
      get admin_drop_signups_announcement_preview_path(email: kind, variant: variant)
      assert_response :success
      assert_includes response.body, "Unsubscribe"
    end
    assert_equal 0, Studio::Link.where(linkable_type: "DropSignup").count, "previews mint no links"
  end

  test "before the drop, the send is refused without send early" do
    log_in_as(users(:alex))
    before_drop do
      get admin_drop_signups_announcement_path
      assert_select '[data-test="announcement-send-early"]'
      post admin_drop_signups_announcement_path, params: { confirm_count: "2" }
    end
    assert_redirected_to admin_drop_signups_announcement_path
    assert_match(/hasn't dropped yet/, flash[:alert])
    assert_no_enqueued_jobs(only: DropAnnouncementJob)
  end

  test "before the drop, send early with the typed count enqueues the send" do
    log_in_as(users(:alex))
    before_drop do
      assert_enqueued_with(job: DropAnnouncementJob, args: [KEY]) do
        post admin_drop_signups_announcement_path, params: { confirm_count: "2", send_early: "1" }
      end
    end
    assert_match(/Queued the announcement for 2 addresses/, flash[:notice])
  end

  test "after the drop, no early flag is needed" do
    log_in_as(users(:alex))
    after_drop do
      get admin_drop_signups_announcement_path
      assert_select '[data-test="announcement-send-early"]', count: 0
      assert_enqueued_with(job: DropAnnouncementJob) do
        post admin_drop_signups_announcement_path, params: { confirm_count: "2" }
      end
    end
  end

  test "a wrong or missing typed count is refused" do
    log_in_as(users(:alex))
    after_drop do
      ["", "3", "1", "two"].each do |typed|
        post admin_drop_signups_announcement_path, params: { confirm_count: typed }
        assert_match(/Type 2/, flash[:alert], typed.inspect)
      end
    end
    assert_no_enqueued_jobs(only: DropAnnouncementJob)
  end

  test "sending, then the page shows what went out; a second send has nobody left" do
    log_in_as(users(:alex))
    after_drop do
      perform_enqueued_jobs(only: DropAnnouncementJob) do
        post admin_drop_signups_announcement_path, params: { confirm_count: "2" }
      end
      get admin_drop_signups_announcement_path
      assert_select '[data-test="announcement-recipient-count"]', text: "0"
      assert_select '[data-test="announcement-claimed"]', text: "3"

      post admin_drop_signups_announcement_path, params: { confirm_count: "0" }
      assert_match(/Nobody is left/, flash[:alert])
    end
    assert_equal 2, EmailDelivery.where(email_key: "DropSignupMailer#announcement").count
  end
end
