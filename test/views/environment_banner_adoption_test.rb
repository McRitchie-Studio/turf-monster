# frozen_string_literal: true

require "test_helper"

# [component] Turf renders the ENGINE's environment banner and keeps no fork of
# its own (studio-engine >= 0.30).
#
# The engine partial was built by lifting this app's own behavior, so this test
# guards the swap: that the layout delegates, that the forks are gone, and that
# the local Turf alone needs is still passed (`devnet:` just stops labelling the
# cluster when dropped), and that a preview navbar paints no SECOND banner on
# the admin navbar-review page, whose duplicate vt-pinned-header would disable
# every view transition on that page.
#
# Since /tasks/turf-readopts-engine-navbar the navbar is studio-engine's, and
# the layout renders the engine's bar stack (studio/banners/_stack) as the
# navbar's sibling, right before it, as the stack's own header asks.
class EnvironmentBannerAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

  def layout_markup
    LAYOUT.read.gsub(/<%#.*?%>/m, " ") # prose must not satisfy these
  end

  test "the layout renders the engine's bar stack, then the navbar" do
    markup = layout_markup
    stack  = markup.index(%(render "studio/banners/stack"))
    navbar = markup.index(%(render "layouts/navbar"))
    refute_nil stack, "the layout renders the shared engine bar stack"
    refute_nil navbar
    assert stack < navbar, "the stack is the navbar's sibling ABOVE it"
  end

  # The property this has always protected: a preview copy paints no second
  # banner, because a duplicate vt-pinned-header disables every view transition
  # on /admin/navbar. The engine navbar renders no bar stack at all, preview or
  # not; the layout's stack renders once per page.
  test "a preview render emits no environment banner at all" do
    html = ApplicationController.render(partial: "layouts/navbar", locals: { show_logged_in: false, preview: true })
    assert_not_includes html, "Environment"
    assert_not_includes html, "studio-bar-stack"
  end

  test "the layout passes the devnet local" do
    assert_includes layout_markup, %(render "studio/banners/stack", devnet: Solana::Config.devnet?),
                    "the cluster label is Turf-specific and only the host can supply it"
  end

  test "no host fork of the banner buttons survives" do
    %w[
      app/views/shared/_email_status_button.html.erb
      app/views/shared/_dev_mode_button.html.erb
    ].each do |path|
      assert_not Rails.root.join(path).exist?, "#{path} should have moved into studio-engine"
    end

    assert_not_includes LAYOUT.read, "shared/email_status_button"
    assert_not_includes LAYOUT.read, "shared/dev_mode_button"
  end

  # shared/_app_banner is NOT dead: _frozen_account_banner still renders it.
  # The impersonation bar it also drew is the engine's since
  # /tasks/turf-readopts-engine-navbar. Asserted so a cleanup pass does not
  # delete it on the assumption that the environment banner was its only caller.
  test "shared/_app_banner stays for the frozen-account banner" do
    assert Rails.root.join("app/views/shared/_app_banner.html.erb").exist?
    assert_includes Rails.root.join("app/views/shared/_frozen_account_banner.html.erb").read,
                    "shared/app_banner"
    refute Rails.root.join("app/views/shared/_impersonation_banner.html.erb").exist?,
           "the impersonation bar is studio/banners/_impersonation now"
  end

  test "the layout decides none of the banner's rules itself" do
    markup = layout_markup

    assert_not_includes markup, "show_environment_banner"
    assert_not_includes markup, "environment_message"
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
