require "test_helper"
require "tmpdir"

# [component] The Connect-Wallet picker, after this app stopped carrying its own
# copy of it.
#
# WHAT THIS REPLACED. turf-monster owned a 226-line modals/_wallet_connect while
# the shared copy sat at studio/modals/_wallet_connect — the partial PROMOTED OUT
# OF THIS APP, which is why the diff was small. That shared copy moved once more
# on 2026-09-01 (/tasks/turf-rides-gem-modals): solana-studio owns it now, at
# solana_studio/modals/_wallet_connect, and /tasks/drop-engine-web3-modals has
# since deleted studio-engine's. DIFFERENT virtual paths, so Rails
# resolution never collapsed them: this was a parallel COPY that simply won at
# every callsite, and the engine's copy was never reached. It had already drifted
# ahead — a live region on the connect error, a connecting-guard on the deep
# link, a brand-icon fallback chain that does not reach for an app-served SVG,
# and canDeepLink, which stops the mobile Phantom install row being suppressed in
# favour of a deep-link button that cannot work.
#
# WHAT IS LEFT FOR THIS APP TO DEFEND is the SEAM, not the picker. The owning
# gem tests the picker. This app supplies four hooks and one slot through
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
      "solana_studio/modals/wallet_connect resolved to #{ResolvedWalletPicker.identifier}, " \
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

  test "every layout that registers the picker renders the GEM partial" do
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
      File.read(path).include?(%(render "solana_studio/modals/wallet_connect"))
    end

    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
      "these layouts register the wallet-connect id without rendering the " \
      "gem picker — the card comes up EMPTY there"
  end

  # ── WHICH gem serves it, not merely "not this app" ────────────────────

  # THE HOLE THESE FOUR CLOSE. Every assertion above answers "is the picker
  # forked BY THIS APP". None of them answers "which external copy WINS", and
  # for the whole of wave 2 that difference was invisible: solana-studio and
  # studio-engine both shipped the partial, at solana_studio/modals and
  # studio/modals respectively, so a resolution check passed against EITHER one.
  # It discriminated only because the two namespaces happened to be disjoint.
  # /tasks/drop-engine-web3-modals deleted the engine copy and took that accident
  # with it. These make the discrimination deliberate: the file that serves the
  # picker must sit under the directory SOLANA-STUDIO ITSELF names.

  test "the picker resolves out of the solana-studio gem's own view root" do
    # ASKED OF THE GEM, never matched against "/gems/" — see the long warning in
    # test/support/resolved_wallet_picker.rb. The literal-path form cannot pass
    # in a consumer-CI lane that bundles the gem as a path checkout, and it once
    # red-sealed a gem publish.
    assert_not_empty ResolvedWalletPicker::GEM_VIEWS,
      "solana-studio contributes no app/views to this app's lookup at all, so " \
      "every origin assertion here is unanswerable rather than merely false"

    assert ResolvedWalletPicker.served_by_gem?,
      "solana_studio/modals/wallet_connect resolved to " \
      "#{ResolvedWalletPicker.identifier}, which is not under " \
      "#{ResolvedWalletPicker::GEM_VIEWS.join(', ')} — something OTHER than " \
      "solana-studio is serving this app's picker"
  end

  test "both render paths are SERVED BY the gem file, not merely resolvable to it" do
    # RESOLUTION AND SERVICE ARE DIFFERENT QUESTIONS. The test above asks a fresh
    # lookup what WOULD resolve; this one watches the two real pages render and
    # reads back the identifier of the template that actually ran. A view path
    # prepended after boot, or a template already compiled and served from cache,
    # separates the two answers.
    origins = ResolvedWalletPicker.render_origins do
      each_picker_render(reload: true) { |label, body| assert body.present?, "#{label}: empty page" }
    end

    # COUNT FIRST, ALWAYS. If neither page mounted the picker, origins is [] and
    # the offender check below is vacuously true — the exact shape of a probe
    # that passes while measuring the wrong page.
    assert_operator origins.length, :>=, 2,
      "captured #{origins.length} picker render(s) across /about and " \
      "/admin/modals/preview, expected one from each — a page stopped mounting " \
      "the picker, so the origin assertion below would have passed on nothing"

    offenders = origins.uniq.reject { |served| ResolvedWalletPicker.served_by_gem?(served) }

    assert_empty offenders,
      "these files served the picker and are not under " \
      "#{ResolvedWalletPicker::GEM_VIEWS.join(', ')} — the page is being " \
      "rendered by a copy that is not solana-studio's"
  end

  test "the render capture reads the namespace, not just the file name" do
    # THE NEAR MISS, pinned. The capture the test above depends on filters render
    # identifiers, and the obvious filter — basename == _wallet_connect.* — looks
    # exact and is not. studio-engine 0.67.0 ships
    # app/views/style/modals/_wallet_connect.html.erb, a thin demo configuration
    # of this same picker that the living style guide renders. Same file name,
    # different virtual path, and it sits in the ENGINE — so a name-only filter
    # captures it on any page carrying the style guide and reports the picker as
    # served from outside the gem. That is a guard failing on a CORRECT bundle,
    # which is worse than no guard at all.
    #
    # Asserted against synthetic paths rather than the engine's real one: a
    # fixed path into another gem is the antipattern this whole support module
    # exists to avoid, and it would turn a future engine cleanup into an error
    # here instead of a finding.
    assert ResolvedWalletPicker.serves_this_partial?(
      "/anywhere/solana_studio/modals/_wallet_connect.html.erb"
    ), "the capture no longer recognises the picker's own path — every origin " \
       "assertion in this section would go quiet rather than fail"

    assert_not ResolvedWalletPicker.serves_this_partial?(
      "/anywhere/style/modals/_wallet_connect.html.erb"
    ), "the capture matched the style guide's specimen, which shares the file " \
       "name and lives in studio-engine — the origin check would fail on a " \
       "bundle that is entirely correct"
  end

  test "a competing copy at the SAME virtual path is caught, and only by this check" do
    # THE NEGATIVE CONTROL. An assertion that cannot fail is worse than none, and
    # the two above would both pass today against a bundle that had never been
    # checked. So this stands a decoy up at the SAME virtual path, in a directory
    # that is neither this app nor the gem — the shape studio-engine re-adding
    # app/views/solana_studio/modals/_wallet_connect would take — and proves
    # three things in order: the decoy really did win, served_by_gem? rejects it,
    # and shadowed_by_app? calls it innocent.
    #
    # That last one is the point of the whole task. The pre-existing guards are
    # BLIND here: the decoy is not inside app/views, and the old app path still
    # does not resolve, so every assertion that existed before this section stays
    # green while a foreign file renders the picker.
    Dir.mktmpdir do |root|
      decoy = File.join(root, "solana_studio", "modals", "_wallet_connect.html.erb")
      FileUtils.mkdir_p(File.dirname(decoy))
      File.write(decoy, "<div data-decoy-picker></div>")

      origins = with_prepended_view_path(root) do
        ResolvedWalletPicker.render_origins { about_page(reload: true) }
      end

      assert_equal [ decoy ], origins.uniq,
        "the decoy never served the page (got #{origins.uniq.inspect}), so this " \
        "control demonstrates nothing about the assertions above"

      assert_not ResolvedWalletPicker.served_by_gem?(decoy),
        "served_by_gem? accepted a file outside the gem's view root — the origin " \
        "assertions above cannot fail and are decoration"

      assert_not decoy.start_with?(ResolvedWalletPicker::APP_VIEWS),
        "the decoy landed inside app/views, so shadowed_by_app? would have caught " \
        "it too and this control proves nothing about the NEW check's reach"
    end
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

  # Renders inside a lookup whose FIRST view path is `path`, then puts the
  # controller's own path set back.
  #
  # Restoring the PathSet is not enough on its own: ActionView memoises compiled
  # templates against a details key, so a stale key would keep serving the decoy
  # to every test that ran after this one in the same process. Cleared on both
  # sides, and the ensure runs even when the block raises.
  def with_prepended_view_path(path)
    previous = ApplicationController.view_paths
    ApplicationController.prepend_view_path(path)
    ActionView::LookupContext::DetailsKey.clear
    yield
  ensure
    ApplicationController.view_paths = previous
    ActionView::LookupContext::DetailsKey.clear
  end

  def with_attestation_flag(on)
    previous = ENV["ENABLE_AGE_ATTESTATION"]
    ENV["ENABLE_AGE_ATTESTATION"] = on ? "true" : nil
    yield
  ensure
    ENV["ENABLE_AGE_ATTESTATION"] = previous
  end
end
