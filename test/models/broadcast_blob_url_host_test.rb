require "test_helper"
# turbo-rails 2.x only require-s this helper lazily inside its
# on_load(:action_cable) hook, which has not fired when this file loads — so
# require it explicitly (same reason Contest::LiveBroadcastTest does).
require "turbo/broadcastable/test_helper"

# REGRESSION — /tasks/blob-url-uses-example-org
#
# A production LogRocket capture on 2026-09-07 caught a contest page requesting
#
#   https://example.org/rails/active_storage/blobs/redirect/<signed-id>/...
#
# while every OTHER blob redirect in the same session correctly used
# turfmonster.media. One code path, not a global misconfiguration.
#
# THE MECHANISM, end to end:
#
#   1. A Turbo Stream broadcast renders its partial through
#      ApplicationController.render — i.e. ActionController::Renderer — which
#      has no real request to read a host from.
#   2. Renderer#render builds its Rack env from RouteSet#default_env
#      (actionpack-8.1.3.1 lib/action_dispatch/routing/route_set.rb:441), and
#      that line hard-codes `host: "example.org"` whenever the route set carries
#      no default_url_options. It does NOT raise — the URL is silently wrong.
#   3. ActionView resolves image_tag's non-String source through
#      polymorphic_URL (resolve_image_source), so a rendered attachment is
#      ABSOLUTE. The placeholder host therefore shipped to real browsers.
#
# Both broadcast paths on the contest live page render an avatar:
# Message#broadcast_new_message (chat) and Contest::LiveBroadcast
# #replace_leaderboard (the board), each via components/_avatar.
#
# These tests assert the RENDERED PAYLOAD rather than the config value, so they
# keep biting even if the fix moves somewhere else.
class BroadcastBlobUrlHostTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  # The host actionpack falls back to when nothing supplies one.
  PLACEHOLDER_HOST = "example.org".freeze
  # config/initializers/route_default_url_options.rb's value for RAILS_ENV=test.
  # Deliberately a literal: reading it back off the route set would let a
  # regression that sets the placeholder host satisfy its own assertion.
  EXPECTED_HOST = "www.example.com".freeze

  BLOB_REDIRECT_PATH = "/rails/active_storage/blobs/redirect/".freeze

  setup do
    @contest = contests(:one)
    @user    = users(:jordan)
    @user.avatar.attach(
      io: File.open(Rails.root.join("test/fixtures/files/banner.png")),
      filename: "banner.png",
      content_type: "image/png"
    )
  end

  test "chat broadcast renders the avatar blob URL against the app host" do
    message = Message.create!(contest: @contest, user: @user, body: "hello")

    # after_create_commit does not fire under transactional fixtures — call the
    # broadcaster directly, exactly as Contest::LiveBroadcastTest does.
    streams = capture_turbo_stream_broadcasts([ @contest, :messages ]) do
      message.send(:broadcast_new_message)
    end

    assert_blob_redirect_on_app_host(streams, "chat message broadcast")
  end

  test "live leaderboard broadcast renders entry avatar blob URLs against the app host" do
    @contest.update!(starts_at: 1.hour.ago, status: "open")
    entries(:two).update!(user: @user)

    streams = capture_turbo_stream_broadcasts([ @contest, :live ]) do
      Contest::LiveBroadcast.send(:replace_leaderboard, @contest)
    end

    assert_blob_redirect_on_app_host(streams, "live leaderboard broadcast")
  end

  test "out-of-request rendering of an attachment never falls back to the placeholder host" do
    # The rawest form of the defect: the renderer Turbo broadcasts through,
    # rendering the one partial both broadcast paths share.
    html = ApplicationController.render(
      partial: "components/avatar",
      locals:  { user: @user, size: "nav" },
      formats: [ :html ]
    )

    src = first_blob_redirect_src(html)
    assert src, "expected components/avatar to render a blob redirect, got: #{html}"
    assert_equal EXPECTED_HOST, URI.parse(src).host,
                 "ApplicationController.render must not fall back to #{PLACEHOLDER_HOST}"
  end

  test "the route set carries a default host so out-of-request helpers have one" do
    options = Rails.application.routes.default_url_options

    assert options[:host].present?,
           "Rails.application.routes.default_url_options[:host] is blank — every URL " \
           "generated outside a request falls back to #{PLACEHOLDER_HOST}"
    assert_not_equal PLACEHOLDER_HOST, options[:host]
    # default_env is the exact hash ActionController::Renderer merges into its
    # Rack env; pin the value the renderer actually reads, not just our input.
    assert_not_equal PLACEHOLDER_HOST, Rails.application.routes.default_env["HTTP_HOST"]
  end

  private

    def assert_blob_redirect_on_app_host(streams, label)
      assert_not_empty streams, "#{label} produced no Turbo Stream payload"

      src = first_blob_redirect_src(streams.map(&:to_html).join)
      assert src, "#{label} rendered no Active Storage blob redirect: #{streams.map(&:to_html).join}"
      assert_equal EXPECTED_HOST, URI.parse(src).host,
                   "#{label} emitted a blob URL on the wrong host: #{src}"
    end

    # Broadcast payloads wrap their HTML in <template>, whose contents Nokogiri
    # does not expose to a plain css("img") descent — scan the serialized markup
    # instead, which is what the browser receives anyway.
    def first_blob_redirect_src(html)
      html.scan(/src="([^"]+)"/).flatten.find { |src| src.include?(BLOB_REDIRECT_PATH) }
    end
end
