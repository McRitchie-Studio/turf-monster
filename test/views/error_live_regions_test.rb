require "test_helper"

# [component] EVERY error paragraph is a live region, and every one of them
# exists before its error does.
#
# THE GAP THIS CLOSES. /tasks/error-text-fails-light-mode (PR #642) and its
# follow-up (PR #649) repainted thirteen error paragraphs so they clear WCAG AA.
# Exactly ONE of them — the wallet-setup connect failure — was also announced.
# The other twelve rendered a sentence that a screen reader was never told
# about, and they are the sentences that say a signature was rejected, a wallet
# was refused, or an entry did not go through. Legible and unannounced is only
# half a fix.
#
# WHY THE MARKUP SHAPE IS THE ASSERTION AND NOT JUST THE ATTRIBUTE. Five of the
# twelve were `<template x-if="<error>">`, so the paragraph did not exist until
# the error did — and a live region INSERTED alongside its own content is not
# reliably announced, because assistive technology has to be observing the
# region before the text lands in it. Adding aria-live to that markup would have
# been a green test over an unchanged experience. So this file asserts the
# ORDERING as well as the attributes: the region is mounted and empty, and only
# its visibility moves.
#
# WHAT THIS TIER CANNOT PROVE: that the sentence really arrives after the region
# at runtime. e2e/wallet_failure_report.spec.js proves that end for the
# wallet-setup paragraph — it reads the region while it is still empty and then
# watches it fill.
class ErrorLiveRegionsTest < ActiveSupport::TestCase
  VIEWS = Rails.root.join("app/views")

  # THE REGISTER IS A CHOICE PER SURFACE, so it is pinned per surface rather
  # than blanket-asserted. `alert`/assertive interrupts, and that is right for a
  # sentence answering a click someone is waiting on. `status`/polite waits for
  # a pause, and that is right for the reserves banner, whose refresh() also
  # runs from init() on page load — an assertive region there talks over a page
  # the reader has only just opened. The same split already exists in
  # _wallet_setup.html.erb, whose install HINT is status/polite while its
  # connect FAILURE is alert/assertive.
  SITES = {
    ["modals/_auth.html.erb", "props.googleError"]              => "alert",
    ["modals/_auth.html.erb", "props.phantomError"]             => "alert",
    ["modals/_auth.html.erb", "props.formError"]                => "alert",
    ["modals/_cdp_ramp.html.erb", "props.sendError"]            => "alert",
    ["modals/_newsletter_subscribe.html.erb", "error"]          => "alert",
    ["modals/_unsubscribe_confirm.html.erb", "error"]           => "alert",
    ["modals/_wallet_changed.html.erb", "error"]                => "alert",
    ["modals/_wallet_setup.html.erb", "error"]                  => "alert",
    ["modals/auth/_resend_footer.html.erb", "props.resendError"] => "alert",
    ["contests/_quest_newsletter.html.erb", "error"]            => "alert",
    ["shared/_auth_card.html.erb", "error"]                     => "alert",
    ["wallet_exports/show.html.erb", "errorText"]               => "alert",
    ["proof_of_reserves/show.html.erb", "bannerError"]          => "status"
  }.freeze

  LIVE = { "alert" => "assertive", "status" => "polite" }.freeze

  # Comments are stripped before anything is matched. This file's own subject is
  # the markup SHAPE, and the views explain the `<template x-if>` they replaced
  # in prose directly above the paragraph that replaced it — a scan of the raw
  # source finds that sentence and reads it as markup. The sibling guard
  # (wallet_setup_error_live_region_test.rb) measured exactly that on 2026-09-07:
  # its refutation failed on its own explanation.
  def markup(path)
    VIEWS.join(path).read.gsub(/<%#.*?%>/m, "").gsub(/<!--.*?-->/m, "")
  end

  # The opening tag of the paragraph that carries this binding to the user.
  def error_tag(path, binding_expr)
    markup(path)[/<p\b[^>]*x-text="#{Regexp.escape(binding_expr)}"[^>]*>/m]
  end

  # A dynamic error paragraph is a <p> whose STATIC class paints it with the
  # theme's danger ink and whose content is written by Alpine. The static-class
  # half is what separates it from a tone binding — proof_of_reserves has two
  # <p> tags that go danger-ink through a `:class` conditional, and they are
  # status labels, not errors.
  def self.discover
    found = []
    Dir.glob(VIEWS.join("**/*.html.erb")).sort.each do |file|
      src = File.read(file).gsub(/<%#.*?%>/m, "").gsub(/<!--.*?-->/m, "")
      src.scan(/<p\b[^>]*>/m) do |tag|
        static_class = tag[/(?<![:@])\bclass="([^"]*)"/, 1].to_s
        next unless static_class.include?("text-danger-ink") && tag =~ /x-text=/
        found << [Pathname.new(file).relative_path_from(VIEWS).to_s, tag[/x-text="([^"]+)"/, 1]]
      end
    end
    found
  end

  test "the table covers every error paragraph in the app" do
    # THE GUARD THAT KEEPS THIS FIXED. Without it the table is a snapshot of
    # thirteen paragraphs somebody once looked at, and the fourteenth error
    # sentence ships unannounced exactly the way these twelve did — silently,
    # and with every test still green.
    discovered = self.class.discover.sort
    assert_equal SITES.keys.sort, discovered,
                 "a danger-ink error paragraph is missing from SITES (or SITES names one " \
                 "that no longer exists). Every error sentence owes a live region; add it " \
                 "to the table with the register its surface deserves."
  end

  test "every error paragraph is announced" do
    SITES.each do |(path, binding_expr), role|
      tag = error_tag(path, binding_expr)
      assert tag, "#{path} must still paint #{binding_expr} into a <p>"

      assert_includes tag, %(role="#{role}"),
                      "#{path} (#{binding_expr}) must carry role=#{role}"
      assert_includes tag, %(aria-live="#{LIVE.fetch(role)}"),
                      "#{path} (#{binding_expr}): the role implies it, but both are stated"
      assert_includes tag, 'aria-atomic="true"',
                      "#{path} (#{binding_expr}): the sentence is replaced whole, " \
                      "so it is announced whole"
    end
  end

  test "every region exists before its error does" do
    SITES.each_key do |(path, binding_expr)|
      tag = error_tag(path, binding_expr)

      # THE HALF THAT MAKES THE ATTRIBUTES WORK. x-show toggles `display` and
      # leaves the element mounted for the life of its surface; x-if inserts it
      # with its content already in place, which is the announcement that never
      # happens.
      assert_includes tag, %(x-show="#{binding_expr}"),
                      "#{path} (#{binding_expr}) must be HIDDEN before the error, not ABSENT"
      assert_includes tag, "x-cloak",
                      "#{path} (#{binding_expr}) must not flash before Alpine boots"

      # And it must not be re-wrapped later. This is the exact regression these
      # five paragraphs are being brought back from.
      refute_match(/<template\s+x-if="[^"]*#{Regexp.escape(binding_expr)}[^"]*"/, markup(path),
                   "#{path}: re-wrapping #{binding_expr} in a template un-announces it silently")
    end
  end

  test "every region carries no text of its own" do
    SITES.each_key do |(path, binding_expr)|
      body = markup(path)[
        /<p\b[^>]*x-text="#{Regexp.escape(binding_expr)}"[^>]*>(.*?)<\/p>/m, 1
      ]

      # An announced region that ships with placeholder copy announces the
      # placeholder. x-text replaces the whole subtree, so the element must be
      # empty in the markup.
      assert_equal "", body.to_s.strip,
                   "#{path} (#{binding_expr}) must be empty until Alpine writes the failure"
    end
  end
end
