# frozen_string_literal: true

require "test_helper"

# [component] Turf renders the ENGINE's environment banner and keeps no fork of
# its own (studio-engine >= 0.30).
#
# The engine partial was built by lifting this app's own behavior, so this test
# guards the swap: that the navbar delegates, that the forks are gone, and —
# most importantly — that the two locals Turf alone needs are still passed.
# Dropping either is silent: `devnet:` just stops labelling the cluster, and
# `preview:` renders a SECOND banner on the admin navbar-review page, whose
# duplicate vt-pinned-header disables every view transition on that page.
class EnvironmentBannerAdoptionTest < ActionDispatch::IntegrationTest
  NAVBAR = Rails.root.join("app/views/layouts/_navbar.html.erb")

  test "the navbar renders the shared engine partial" do
    assert_includes NAVBAR.read, %(render "studio/banners/environment")
  end

  test "the navbar passes the preview and devnet locals" do
    navbar = NAVBAR.read

    assert_includes navbar, "preview: is_preview",
                    "a preview copy must not render a second banner (duplicate vt-pinned-header)"
    assert_includes navbar, "devnet: Solana::Config.devnet?",
                    "the cluster label is Turf-specific and only the host can supply it"
  end

  test "no host fork of the banner buttons survives" do
    %w[
      app/views/shared/_email_status_button.html.erb
      app/views/shared/_dev_mode_button.html.erb
    ].each do |path|
      assert_not Rails.root.join(path).exist?, "#{path} should have moved into studio-engine"
    end

    assert_not_includes NAVBAR.read, "shared/email_status_button"
    assert_not_includes NAVBAR.read, "shared/dev_mode_button"
  end

  # shared/_app_banner is NOT dead — _impersonation_banner still renders it.
  # Asserted so a future cleanup pass doesn't delete it on the assumption that
  # the environment banner was its only caller.
  test "shared/_app_banner stays for the impersonation banner" do
    assert Rails.root.join("app/views/shared/_app_banner.html.erb").exist?
    assert_includes Rails.root.join("app/views/shared/_impersonation_banner.html.erb").read,
                    "shared/app_banner"
  end

  test "the navbar decides none of the banner's rules itself" do
    navbar = NAVBAR.read

    assert_not_includes navbar, "show_environment_banner"
    assert_not_includes navbar, "environment_message"
  end

  test "the engine supplies the banner contract this navbar depends on" do
    %i[qa_environment? show_environment_banner? environment_banner_message local_inbox_reachable?].each do |method|
      assert Studio.respond_to?(method), "studio-engine >= 0.30 must define Studio.#{method}"
    end
  end

  test "a rendered page carries the banner and links the local inbox" do
    get root_path
    follow_redirect! while response.redirect? # root lands on the active contest

    assert_response :success
    assert_select "a[href='/_studio/local_emails']", minimum: 1
    assert_includes response.body, "#{Rails.env.capitalize} Environment"
  end
end
