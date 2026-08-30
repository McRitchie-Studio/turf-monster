require "test_helper"

# [component] The Connect-Wallet picker, after this app stopped carrying its own
# copy of it.
#
# WHAT THIS REPLACED. turf-monster owned a 226-line modals/_wallet_connect while
# studio-engine ships studio/modals/_wallet_connect — the partial PROMOTED OUT OF
# THIS APP, which is why the diff was small. DIFFERENT virtual paths, so Rails
# resolution never collapsed them: this was a parallel COPY that simply won at
# every callsite, and the engine's copy was never reached. It had already drifted
# ahead — a live region on the connect error, a connecting-guard on the deep
# link, a brand-icon fallback chain that does not reach for an app-served SVG,
# and canDeepLink, which stops the mobile Phantom install row being suppressed in
# favour of a deep-link button that cannot work.
#
# WHAT IS LEFT FOR THIS APP TO DEFEND is the SEAM, not the picker. The engine
# tests the picker. This app supplies four hooks and one slot through
# WalletPickerHelper, and every one of them is the sort of thing that can go
# missing while the page still looks perfect:
#
#   onInit / canPick / verifyArgs / onDeepLink / onBack   (extra_data)
#   the legal-age attestation                             (slot)
#
# TWO RENDER SITES, and both must move. layouts/application and
# layouts/modal_preview keep SEPARATE modal registration lists, so a picker
# adopted in one and forked in the other renders the old copy at /admin/style
# forever, silently. The static guard below is derived from the layout glob
# rather than a hardcoded pair, so a third layout is covered the day it appears.
class WalletPickerAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUTS = Dir[Rails.root.join("app/views/layouts/*.html.erb").to_s].freeze

  # ── The fork is gone, proved by RESOLUTION ────────────────────────────

  test "the picker renders from outside this app" do
    assert_not ResolvedWalletPicker.shadowed_by_app?,
      "studio/modals/wallet_connect resolved to #{ResolvedWalletPicker.identifier}, " \
      "inside this app's app/views — the picker has been re-forked as a shadow"
  end

  test "the old app path no longer resolves" do
    # The fork lived at a DIFFERENT virtual path, so the assertion above cannot
    # see it coming back where it was. This one can.
    assert_not ResolvedWalletPicker.app_path_resolves?,
      "modals/_wallet_connect resolves again — the fork is back at its old path"
  end

  test "the fork is gone from disk" do
    # A render assertion cannot answer this: the fork and the engine partial
    # produce near-identical markup, which is what let the copy survive.
    assert_not File.exist?(ResolvedWalletPicker::FORK_PATH),
      "#{ResolvedWalletPicker::FORK_PATH} is back — the engine owns this picker now"
  end

  test "no layout renders the old picker path" do
    offenders = LAYOUTS.select do |path|
      # ERB comments stripped: both layouts DISCUSS the picker above the render,
      # and a raw read that saw the old path quoted in prose would fail this
      # test for a sentence.
      File.read(path).gsub(/<%#.*?%>/m, "").match?(%r{["']modals/wallet_connect["']})
    end

    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
      "these layouts still render the deleted fork"
  end

  test "every layout that registers the picker renders the ENGINE partial" do
    # Registration and render are separate lines, and the failure mode is a
    # layout that registers the id and renders nothing (blank card) or renders
    # the fork. Derived from the glob so a third layout cannot slip through.
    registering = LAYOUTS.select do |path|
      File.read(path).include?("id === 'wallet-connect'")
    end

    assert_operator registering.length, :>=, 2,
      "expected at least layouts/application and layouts/modal_preview to " \
      "register the picker, found #{registering.length} — the scan matched " \
      "almost nothing, so every assertion below it is vacuous"

    offenders = registering.reject do |path|
      File.read(path).include?(%(render "studio/modals/wallet_connect"))
    end

    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
      "these layouts register the wallet-connect id without rendering the " \
      "engine picker — the card comes up EMPTY there"
  end

  # ── The seam: the hooks this app contributes ──────────────────────────

  # Every hook is asserted in DEFINITION FORM, never by bare name. The picker
  # names its own hooks in comments that ship to the page as rendered HTML, so
  # `assert_includes body, "canPick"` passes against a page where canPick was
  # deleted. Anchor on the shape only a definition has.
  HOOKS = {
    "onInit"     => /onInit\(\)\s*\{/,
    "canPick"    => /canPick\(\)\s*\{/,
    "verifyArgs" => /verifyArgs\(\)\s*\{/,
    "onDeepLink" => /onDeepLink\(\)\s*\{/,
    "onBack"     => /onBack\(\)\s*\{/
  }.freeze

  test "both render paths carry every hook this app contributes" do
    each_picker_render do |label, body|
      x_data = picker_x_data(body)
      assert x_data.present?, "#{label}: could not locate the picker's x-data"

      HOOKS.each do |name, definition|
        # Against the x-data, NOT the page. A double quote that closes the
        # attribute early leaves the later hooks in the page as loose text, so a
        # body-wide match would still find them while they no longer run.
        assert_match definition, x_data,
          "#{label}: #{name} is not DEFINED on the picker. The engine calls each " \
          "hook only `if (typeof this.#{name} === 'function')`, so a missing one " \
          "is silent: the picker keeps working and just stops doing turf's half."
      end
    end
  end

  test "the extra-data fragment reaches the attribute unescaped" do
    # THE FAILURE THAT RENDERS A WORKING PAGE. If the fragment loses its
    # html_safe on the way in, every single quote becomes &#39; — which still
    # PARSES, because a browser decodes entities inside an attribute. The page
    # works and only the source reads wrong, so nothing but this can see it.
    each_picker_render do |label, body|
      x_data = picker_x_data(body)
      assert x_data.present?, "#{label}: could not locate the picker's x-data"
      # Anchored on a quoted string ONLY turf's fragment carries. The engine's
      # own back() also reads Alpine.store('modals'), so an assertion on that
      # would pass with this app's fragment escaped, or absent altogether.
      assert_includes x_data, "localStorage.setItem('phantom_dl_age_attested'",
        "#{label}: the fragment's quotes were escaped on the way into the attribute"
      assert_not_includes x_data, "&#39;",
        "#{label}: the fragment reached the attribute HTML-escaped"
    end
  end

  test "the extra-data fragment contains no double quote" do
    # A single double quote inside the double-quoted x-data closes the attribute
    # early; Alpine then mounts the component as a silent no-op, and every
    # markup assertion in this file still passes while the modal is dead in a
    # real browser. Inherited from the deleted fork's own guard.
    #
    # READ THE HELPER, NOT THE RENDERED ATTRIBUTE. The obvious version of this
    # test — extract the x-data and refute a quote in it — is INERT, and only
    # mutation showed it: picker_x_data captures with [^"]*, so what it returns
    # can never contain a double quote whatever the helper emits. Injecting one
    # left the test green. The helper's own string is where the character is.
    fragment = ApplicationController.helpers.send(:wallet_connect_extra_data)

    assert fragment.present?, "the helper produced no extra_data fragment"
    assert_not_includes fragment, '"',
      "a double quote inside the double-quoted x-data closes it early and " \
      "silently kills the picker in the browser"
  end

  # ── The seam: the legal-age attestation slot ──────────────────────────

  test "the attestation rides the slot, on both render paths" do
    with_attestation_flag(true) do
      each_picker_render(reload: true) do |label, body|
        assert_includes body, "data-age-attestation",
          "#{label}: the picker lost its legal-age checkbox"
        assert_match %r{<template x-if="needsAttestation">}, body,
          "#{label}: the checkbox renders unconditionally — a linking flow and a " \
          "signed-in user would be asked to attest again"
      end
    end
  end

  test "a parked flag passes no slot at all" do
    with_attestation_flag(false) do
      each_picker_render(reload: true) do |label, body|
        assert_not_includes body, "data-age-attestation",
          "#{label}: the parked checkbox still ships in the page source"
      end
    end
  end

  test "the slot does not leak the page body into the card" do
    # THE TRAP THE ENGINE'S OWN HEADER WARNS ABOUT. The slot is a NAMED LOCAL,
    # never a block: block_given? is ALWAYS true inside a compiled Rails partial
    # — it inherits the LAYOUT's yield — so a block-shaped slot falls through to
    # view_flow[:layout] and prints the whole captured page body inside the modal
    # card. It only fires during the LAYOUT pass, which is exactly how a modal is
    # mounted, so no partial-render test can see it. This runs a real page.
    with_attestation_flag(true) do
      assert_equal 1, about_page(reload: true).scan("About Turf Totals").size,
        "the page's own content appears twice — the slot fell through to " \
        "view_flow[:layout] and printed the page inside the picker"
    end
  end

  # ── The capability the engine now asks this app for ───────────────────

  test "this app supplies the deep-link function the engine gates on" do
    # NEW CONTRACT, and it is easy to miss. The engine suppresses Phantom's
    # mobile install row ONLY when `typeof startPhantomDeepLink === 'function'`,
    # and paints the deep-link row on the same condition. The fork suppressed the
    # install row unconditionally, so this dependency did not exist before the
    # adoption.
    #
    # CORRECTED 2026-08-30, measured rather than reasoned. This comment used to
    # say an app without the global "leaves a phone with NO Phantom path at all".
    # It does not: both getters read canDeepLink, so losing it un-suppresses the
    # INSTALL row at the same moment it hides the deep-link row. The phone gets
    # Phantom's browser-extension download page — a dead end on iOS Safari, which
    # is bug enough, but a VISIBLE one. Anyone auditing for an empty wallet list
    # would have looked straight past it.
    #
    # 2026-08-30 (adopt-engine-phantom-deeplink): THE DEEP LINK IS THE ENGINE'S
    # NOW TOO. It used to be app/javascript/phantom_deeplink.js loaded through
    # the importmap; a File.read of that path is now a read of a file that does
    # not exist, and the assertion errored rather than failed. The GUARANTEE is
    # unchanged and still belongs here — it is the picker's precondition — so it
    # is restated against the page the picker is mounted on. Everything else
    # about the deep link is pinned in phantom_deeplink_adoption_test.
    each_picker_render do |label, body|
      assert_match(/window\.startPhantomDeepLink\s*=\s*startPhantomDeepLink\s*;/, body,
                   "#{label}: nothing on this page publishes startPhantomDeepLink on " \
                   "window, so the engine picker hides its deep-link row and hands a " \
                   "phone Phantom's browser-extension INSTALL row instead — the iOS " \
                   "dead end. Assert the DEFINITION, never the bare " \
                   "name: the picker's x-data and the engine partial both NAME the " \
                   "function in comments that ship to this page.")
    end
  end

  private

  # The two paths that mount the picker, rendered for real. Yielded as
  # (label, body) so a failure names which one broke.
  def each_picker_render(reload: false)
    yield "layouts/application (/about)", about_page(reload: reload)
    yield "layouts/modal_preview (/admin/modals/preview)", modal_preview_page(reload: reload)
  end

  def about_page(reload: false)
    @about_page = nil if reload
    @about_page ||= begin
      get about_path
      assert_response :success
      response.body
    end
  end

  def modal_preview_page(reload: false)
    @modal_preview_page = nil if reload
    @modal_preview_page ||= begin
      log_in_as users(:alex)
      get admin_modal_preview_path(modal_id: "wallet-connect")
      assert_response :success
      response.body
    end
  end

  # The picker's own x-data, located by a member only IT declares. The page
  # carries many x-data attributes; a first-match read would grab another one.
  def picker_x_data(body)
    body[/<div x-data="([^"]*get needsAttestation[^"]*)"/m, 1] ||
      body[/<div x-data="([^"]*canPick\(\)[^"]*)"/m, 1]
  end

  def with_attestation_flag(on)
    previous = ENV["ENABLE_AGE_ATTESTATION"]
    ENV["ENABLE_AGE_ATTESTATION"] = on ? "true" : nil
    yield
  ensure
    ENV["ENABLE_AGE_ATTESTATION"] = previous
  end
end
