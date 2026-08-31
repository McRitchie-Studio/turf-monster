require "test_helper"

# [component] The Phantom MOBILE deep link, after this app stopped carrying its
# own copy of it.
#
# WHAT THIS REPLACED. turf-monster owned both halves of the mobile round trip —
# app/javascript/phantom_deeplink.js (the hand-off out to the Phantom app) and
# app/views/solana_sessions/phantom_callback.html.erb (the return leg) — and
# studio-engine now ships both, PROMOTED OUT OF THIS APP, which is why the diff
# was small. What this app keeps is the ROUTE, the controller action, and the
# blocking tweetnacl tag.
#
# THE TWO HALVES FAILED DIFFERENTLY, which is why they are asserted differently:
#
#   the deep link  was a JS MODULE, so there was no competing view path and no
#                  shadow — the engine partial was simply never rendered. Its
#                  ghost is a file on disk plus two loader lines.
#   the callback   was a TRUE SHADOW at the identical virtual path, winning
#                  resolution outright and leaving the engine's copy inert.
#
# THE CONTRACT THIS APP OWES THE ENGINE, and the reason this file is not
# optional: studio/modals/_wallet_connect suppresses Phantom's mobile INSTALL row
# on `self.isMobile && self.canDeepLink && i.name === 'Phantom'`, and canDeepLink
# is `typeof startPhantomDeepLink === 'function'`. Whether that global exists on
# the page therefore decides what a phone SEES, not merely what a tap does.
#
# WHAT LOSING IT ACTUALLY DOES, measured in a browser on 2026-08-30 rather than
# reasoned about — because the reasoning in circulation was BACKWARDS and this
# app's own comments carried it. Both getters read canDeepLink, so both flip
# together: `missingInstalls` stops filtering Phantom and `showPhantomDeepLink`
# goes false. A phone is therefore left with Phantom's INSTALL row, NOT with "no
# Phantom path at all". That is still a regression — you cannot install a browser
# extension on iOS Safari, so the row is a dead end and it is precisely the bug
# wallet_picker_single_phantom_test was written to kill — but it is a visible dead
# end rather than an empty list, and a reader hunting an empty list will not find
# it. Control run, iPhone 13 viewport, one variable changed:
#
#   global present   deep-link row VISIBLE   install rows: Solflare, Backpack
#   global deleted   deep-link row HIDDEN    install rows: Phantom, Solflare, Backpack
#
# TWO RENDER SITES. layouts/application and layouts/modal_preview keep SEPARATE
# registration lists, and both mount the picker — so both need the global. One
# render in shared/_alpine_factories covers both; these tests check the RENDERED
# pages rather than that arrangement, so a future third layout fails here.
# THE ENGINE FLOOR THIS FILE DEPENDS ON IS NOW THE ONE THE GEMFILE DECLARES.
# `studio/solana/_phantom_deeplink`, the `solana_sessions/phantom_callback`
# template, `Studio.wallet_debug_sink` and `Studio.wallet_sign_in_statement` all
# first exist in studio-engine 0.64.0. This file used to record that the pin
# UNDERSTATED that — `~> 0.63` with MINIMUM at 0.63.0 — and point at
# /tasks/raise-engine-pin-to-0-64 as the change that would close it. That task
# landed: the Gemfile pins `~> 0.64` and engine_pin_contract_test sets MINIMUM to
# 0.64.0, which is the MAXIMUM first-appearance across everything this app
# renders or configures.
#
# The sharpest consequence is worth keeping in view here, because it is NOT what
# this file's own tests catch: `config/initializers/studio.rb` SETS
# `config.wallet_debug_sink`, so a bundle that walks back to 0.63 raises
# NoMethodError inside `Studio.configure` and the app never boots. The tests
# below would fail on such a bundle too, but the boot does first.
#
class PhantomDeeplinkAdoptionTest < ActionDispatch::IntegrationTest
  # The literal this app's users have been signing since long before the
  # promotion. HARDCODED on purpose: deriving it from Studio.wallet_sign_in_statement
  # would assert the helper equals itself, and the whole question is whether
  # moving to the engine changed one signed byte. It did not — Studio.app_name is
  # "Turf Monster" and the engine builds "Sign in to #{app_name}".
  SIGNED_STATEMENT = "Sign in to Turf Monster".freeze

  # The preview cards whose modal can actually CALL startPhantomDeepLink:
  # wallet-connect is the engine picker, wallet-setup is this app's own. Derived
  # by grepping both view trees for the call, not guessed — widen this only
  # together with the layout gate it mirrors.
  DEEP_LINK_PREVIEWS = %w[wallet-connect wallet-setup].freeze

  # A card that cannot reach the deep link, used as the payload control below.
  NON_DEEP_LINK_PREVIEW = "birthday".freeze

  # ── The fork is gone, proved by RESOLUTION ────────────────────────────

  test "the deep link renders from outside this app" do
    assert_not ResolvedPhantomDeeplink.shadowed_by_app?,
      "studio/solana/phantom_deeplink resolved to #{ResolvedPhantomDeeplink.identifier}, " \
      "inside this app's app/views — the deep link has been re-forked as a shadow"
  end

  test "the callback renders from outside this app" do
    # THE ONE THAT WAS ACTUALLY SHADOWED. Same virtual path in both places, host
    # wins, so for as long as the app's copy existed the engine's was dead code
    # and no markup assertion anywhere could tell.
    assert_not ResolvedPhantomDeeplink.callback_shadowed_by_app?,
      "solana_sessions/phantom_callback resolved to " \
      "#{ResolvedPhantomDeeplink.callback_identifier}, inside this app's " \
      "app/views — the callback fork is back and the engine's copy is inert again"
  end

  test "both forks are gone from disk" do
    # A render assertion cannot answer this for the callback: the fork and the
    # engine template produce near-identical markup, which is exactly what let
    # the copy survive unnoticed.
    assert_not File.exist?(ResolvedPhantomDeeplink::FORK_JS),
      "#{ResolvedPhantomDeeplink::FORK_JS} is back — the engine owns the deep link now"
    assert_not File.exist?(ResolvedPhantomDeeplink::FORK_VIEW),
      "#{ResolvedPhantomDeeplink::FORK_VIEW} is back — it would shadow the engine's " \
      "callback at the identical virtual path and win silently"
  end

  test "the fork's two loader lines are gone, so nothing re-defines the global" do
    # The fork loaded as an importmap module that ASSIGNED window.startPhantomDeepLink.
    # Leaving either line behind is not merely untidy: the module would load after
    # the engine's parse-time script and overwrite it with the un-promoted version,
    # restoring the base58 dependency the engine deliberately inlined away.
    refute_match(/^pin ["']phantom_deeplink["']/,
                 Rails.root.join("config/importmap.rb").read,
                 "config/importmap.rb still pins the deleted module")
    refute_match(/^import ["']phantom_deeplink["']/,
                 Rails.root.join("app/javascript/application.js").read,
                 "application.js still imports the deleted module")
  end

  test "base58 stays, because the deep link was not its only reader" do
    # Only the DEEP LINK's dependency on it moved — the engine inlined its own
    # copy so the partial has exactly one dependency (nacl). wallet_provider.js
    # and solana_stores.js still call window.encodeBase58, so deleting base58.js
    # alongside the deep link would break wallet signing on DESKTOP.
    assert File.exist?(Rails.root.join("app/javascript/base58.js")),
      "base58.js was deleted with the deep link, but it has other readers"
    assert_match(/^import ["']base58["']/, Rails.root.join("app/javascript/application.js").read,
                 "base58 left the importmap — window.encodeBase58 is gone and " \
                 "wallet_provider.js:175 throws on the first address encode")
  end

  # ── The stripper, proved before anything is asserted through it ───────

  test "the stripper leaves the code behind and takes the prose" do
    # THE CONTROL FOR EVERY ASSERTION BELOW. A stripper that ate the file would
    # make `refute_match` vacuously true and `assert_match` loudly false — but a
    # stripper that ate only SOME of it fails in one direction and is invisible.
    raw     = ResolvedPhantomDeeplink.source
    stripped = ResolvedPhantomDeeplink.deeplink_code

    assert_operator raw.length, :>, 4000, "the resolved partial is far smaller than expected"
    assert_operator stripped.length, :>, 1500,
      "the stripper left #{stripped.length} of #{raw.length} bytes — it ate the code, " \
      "and every assertion reading it is now vacuous"
    assert_operator stripped.length, :<, raw.length,
      "the stripper removed nothing — the prose is still in the string being asserted on"

    # It took the two things it exists to take.
    refute_match(/PROMOTED from turf-monster/, stripped, "an ERB comment survived the strip")
    refute_match(%r{^\s*// Phantom deep link protocol}, stripped, "a JS line comment survived the strip")
    # And the prose it removed really did name the function, which is the whole
    # reason a bare-name assertion cannot be trusted here.
    #
    # THE REMOVED TEXT IS COLLECTED, NOT SUBTRACTED. `raw.gsub(stripped, "")` looks
    # like the removed prose and is not: the stripper cuts INTERIOR spans, so the
    # stripped text is nowhere a contiguous substring of raw, gsub matches nothing,
    # and the assertion silently degrades to "raw mentions the name" — which is
    # true no matter what the stripper did. Gather the spans instead.
    prose = raw.scan(/<%#.*?%>/m).join("\n") + raw.scan(%r{^\s*//.*$}).join("\n")
    assert_match(/startPhantomDeepLink/, prose,
                 "the removed prose never mentioned startPhantomDeepLink, so the strip " \
                 "is guarding against a danger that does not exist here — re-check it")
    assert_operator prose.length, :>, 500,
                 "the stripper claims to have removed #{raw.length - stripped.length} bytes " \
                 "but only #{prose.length} bytes of comment can be found — the two are " \
                 "measuring different things"
  end

  # ── The function is DEFINED, not merely named ─────────────────────────

  test "the resolved partial defines the function in definition form" do
    code = ResolvedPhantomDeeplink.deeplink_code

    assert_match(/function\s+startPhantomDeepLink\s*\(\s*linkMode\s*,\s*currentUserId\s*\)/, code,
                 "the deep link's definition is gone, or its arity changed — the picker " \
                 "passes (linkMode, currentUserId) and the User-ID binding needs both")
    assert_match(/window\.startPhantomDeepLink\s*=\s*startPhantomDeepLink\s*;/, code,
                 "the function is defined but never published on window, so the picker's " \
                 "canDeepLink getter reads undefined and the phone loses Phantom entirely")
  end

  # ── What the BROWSER actually receives, on both layouts ───────────────

  test "every layout that mounts the picker ships the global exactly once" do
    each_picker_render do |label, body|
      hits = body.scan(/window\.startPhantomDeepLink\s*=\s*startPhantomDeepLink\s*;/)
      assert_equal 1, hits.length,
        "#{label}: found #{hits.length} definitions of window.startPhantomDeepLink. " \
        "Zero means this layout's picker offers a phone no Phantom row at all; two " \
        "means the deleted importmap module is loading again and overwriting the engine's."
    end
  end

  test "the picker's canDeepLink gate and its precondition ship on the same page" do
    # THE CROSS-REPO CONTRACT, asserted where it actually binds: on one rendered
    # page, at the same moment. Reading the two halves out of two different files
    # would pass with them on two different pages.
    each_picker_render do |label, body|
      x_data = picker_x_data(body)
      assert x_data.present?, "#{label}: could not locate the picker's x-data"
      assert_match(/typeof\s+startPhantomDeepLink\s*===\s*.function./, x_data,
                   "#{label}: the picker no longer gates on the deep link existing — " \
                   "re-derive what suppresses Phantom's mobile install row before " \
                   "trusting the assertion below")
      assert_match(/window\.startPhantomDeepLink\s*=\s*startPhantomDeepLink\s*;/, body,
                   "#{label}: the picker asks for startPhantomDeepLink and this page " \
                   "does not define it — so both of its getters flip together and a " \
                   "phone falls back to Phantom's browser-extension INSTALL row, which " \
                   "cannot be completed on iOS Safari")
    end
  end

  # ── The three things that must not drift (traced to the verifier) ─────

  test "the signed statement is byte-for-byte what this app signed before the promotion" do
    assert_equal SIGNED_STATEMENT, Studio.wallet_sign_in_statement,
      "the SIWS statement changed. The server does not verify it, so nothing fails " \
      "loudly — but it is what the human reads inside Phantom, and the callback " \
      "rebuilds it to post for verification, so a drift between the two halves " \
      "fails every mobile sign-in."
  end

  test "the deep link and the callback carry the SAME statement, rendered" do
    # They cannot drift only because both read Studio.wallet_sign_in_statement.
    # Asserting that in SOURCE would pass on a page where one of them failed to
    # render; assert it on the two pages a phone actually loads.
    assert_includes about_page, SIGNED_STATEMENT.to_json,
      "the deep link page does not carry the statement it will ask Phantom to sign"
    assert_includes callback_page, SIGNED_STATEMENT.to_json,
      "the callback does not carry the statement it rebuilds for verification — " \
      "every mobile sign-in would fail the signature check"
  end

  test "the User-ID binding line survives, unreformatted" do
    # OPSEC-005 does a SUBSTRING match on "User-ID: <id>" in
    # Solana::SessionAuth#verify_solana_signature!. Reformatting or translating
    # it does not fail a test elsewhere; it fails wallet LINKING in production.
    assert_match(/statement\s*\+\s*.\\nUser-ID: .\s*\+\s*currentUserId/,
                 ResolvedPhantomDeeplink.deeplink_code,
                 "the User-ID binding line changed shape — the server matches it as a substring")
    assert_match(/statementLine\s*\+=\s*.\\nUser-ID: .\s*\+\s*storedUserId/,
                 ResolvedPhantomDeeplink.callback_code,
                 "the callback rebuilds the binding line differently from the deep link " \
                 "that signed it, so a linked-wallet signature can never verify")
  end

  test "the domain is taken from the browser, not configured" do
    # OPSEC-018: the server checks it against request.host_with_port. A configured
    # value would be an app override of a signed field, and it breaks sign-in.
    assert_match(/domain:\s*window\.location\.host/, ResolvedPhantomDeeplink.deeplink_code,
                 "domain is no longer read from window.location.host")
  end

  # ── The nacl race, decided rather than inherited ──────────────────────

  test "this app loads nacl from a blocking tag and renders no async loader" do
    # THE DECISION /tasks/adopt-engine-phantom-deeplink made. The engine's
    # studio/solana/deeplink_assets APPENDS a script element — asynchronous — and
    # the callback's IIFE reads nacl AT PARSE TIME and hard-fails with no retry.
    # Rendering the engine loader here would race it. A blocking tag cannot.
    offenders = Dir[Rails.root.join("app/views/**/*.erb").to_s].select do |path|
      File.read(path).gsub(/<%#.*?%>/m, "").match?(%r{["']studio/solana/deeplink_assets["']})
    end
    assert_empty offenders.map { |p| p.delete_prefix("#{Rails.root}/") },
      "these views render the engine's ASYNC nacl loader. The callback reads nacl " \
      "at parse time and fails outright when it loses the race. Adopt it only " \
      "together with a callback that waits."

    tag = File.read(Rails.root.join("app/views/layouts/application.html.erb"))
            .gsub(/<%#.*?%>/m, "")[%r{<script[^>]*tweetnacl[^>]*>}]
    assert tag.present?, "the layout no longer loads tweetnacl at all — every mobile sign-in fails"
    refute_match(/\bdefer\b|\basync\b/, tag,
                 "tweetnacl is loaded #{tag} — deferring it reintroduces exactly the race " \
                 "this app avoided by NOT adopting studio/solana/deeplink_assets")
  end

  # ── The route this app KEEPS ──────────────────────────────────────────

  test "the callback route is still this app's, and reaches the callback action" do
    # THE TRAP IN THE ADOPTION NOTE, which said the engine now draws this route
    # so turf's declaration had become a duplicate. It is not, twice over:
    # the engine's copy sits behind Studio.draw_auth_routes (false here), and
    # Studio.routes draws the OmniAuth wildcard auth/:provider/callback
    # UNCONDITIONALLY and EARLIER, so a phantom callback drawn after it would
    # recognise as omniauth_callbacks#create with provider "phantom".
    #
    # Deleting the app's line therefore 404s every mobile sign-in. This asserts
    # RECOGNITION rather than the presence of a line in routes.rb, so it fails on
    # the wildcard capturing it too — which a source grep would not see.
    assert_recognizes({ controller: "solana_sessions", action: "phantom_callback" },
                      "/auth/phantom/callback")
  end

  # ── The debug sink this app opts back in to ───────────────────────────

  test "the debug sink is opted in through a predicate that survives a QA dyno" do
    # The engine defaults this OFF because the sink sits beside a signing key.
    # Restoring it is this app's call, and Rails.env.production? is the wrong
    # predicate: a Heroku QA dyno runs RAILS_ENV=production, so an env test
    # would take QA's debugging away while looking correct.
    AppFlags.stub :live_production?, true do
      assert_not Studio.wallet_debug_sink?, "the sink renders on a real production deploy"
    end
    AppFlags.stub :live_production?, false do
      assert Studio.wallet_debug_sink?, "QA and development lost the sink"
    end
  end

  # ── nacl on the PREVIEW layout, the half the blocking-tag test missed ──

  test "every preview that can reach the deep link ships nacl on the same page" do
    # THE BUG THIS KILLS (found reviewing /tasks/adopt-engine-phantom-deeplink).
    # shared/_alpine_factories renders the engine deep link on EVERY preview, so
    # window.startPhantomDeepLink exists on all 52 cards and the engine picker
    # paints its mobile Phantom row on that global EXISTING. But
    # layouts/modal_preview gated tweetnacl on @modal_id == "username", so on a
    # phone the row painted and the tap threw "nacl is not defined"
    # SYNCHRONOUSLY, before the fetch — where the deep link's own catch could
    # never see it. A dead button that reported nothing.
    #
    # Asserted on the RENDERED page because that is the only place the two halves
    # meet. Reading the gate out of the layout source would pass on a card that
    # never rendered it, which is exactly how this gap survived.
    DEEP_LINK_PREVIEWS.each do |modal_id|
      body = preview_page(modal_id)

      # THE PRECONDITION, asserted first: without it this test could pass by
      # asserting nacl for a card that has no deep link to feed.
      assert_match(/window\.startPhantomDeepLink\s*=\s*startPhantomDeepLink\s*;/, body,
                   "#{modal_id}: this preview does not define the global at all, so the " \
                   "nacl assertion below is guarding nothing — re-derive DEEP_LINK_PREVIEWS")

      tag = nacl_tag(body)
      assert tag.present?,
             "#{modal_id}: the preview defines startPhantomDeepLink but loads no tweetnacl. " \
             "The engine picker paints its mobile Phantom row on that global, and the deep " \
             "link's first act is nacl.box.keyPair() — so the row is a dead button whose " \
             "tap throws before the fetch, where nothing catches it."
      refute_match(/\bdefer\b|\basync\b/, tag,
                   "#{modal_id}: tweetnacl is loaded #{tag} — deferring it reintroduces the " \
                   "race the blocking tag exists to avoid")
    end
  end

  test "a preview that cannot reach the deep link still does not pay for nacl" do
    # THE CONTROL, and the acceptance criterion "the iframe payload cost stays
    # deliberate" written as an assertion. Without it the test above is satisfied
    # by ungating tweetnacl for all 52 cards, which is the fix this one refuses.
    body = preview_page(NON_DEEP_LINK_PREVIEW)
    assert_nil nacl_tag(body),
               "#{NON_DEEP_LINK_PREVIEW} loads tweetnacl, but nothing on that card can call " \
               "startPhantomDeepLink. The gate has been widened past the cards that need it."
  end

  test "the expensive half stays on the one preview that needs it" do
    # web3.js measured 452 KB against the CDN versus tweetnacl's 31 KB, so it is
    # 93 percent of the pair and the entire reason the pair was gated. The nacl
    # split must not have dragged it along: a gallery that loads web3.js on the
    # wallet cards is the page-load stall this gate was written to prevent.
    assert_nil web3_tag(preview_page("wallet-connect")),
               "wallet-connect now loads web3.js. Only the username preview signs a " \
               "transaction; every other card pays 452 KB for a script it never calls."
    assert web3_tag(preview_page("username")).present?,
           "the username preview lost web3.js — its signing path deserializes and " \
           "broadcasts a transaction through it"
  end

  private

  def each_picker_render
    yield "layouts/application (/about)", about_page
    yield "layouts/modal_preview (/admin/modals/preview)", modal_preview_page
  end

  def about_page
    @about_page ||= begin
      get about_path
      assert_response :success
      response.body
    end
  end

  def modal_preview_page
    @modal_preview_page ||= begin
      log_in_as users(:alex)
      get admin_modal_preview_path(modal_id: "wallet-connect")
      assert_response :success
      response.body
    end
  end

  def callback_page
    @callback_page ||= begin
      get "/auth/phantom/callback"
      assert_response :success
      response.body
    end
  end

  # The picker's own x-data, located by a member only IT declares. The page
  # carries many x-data attributes; a first-match read would grab another one.
  def picker_x_data(body)
    body[/<div x-data="([^"]*canDeepLink[^"]*)"/m, 1]
  end

  # One rendered preview card, by modal id. Memoised per id: each card is a
  # separate request with its own @modal_id, which is precisely what the layout
  # gate keys on.
  def preview_page(modal_id)
    @preview_pages ||= {}
    @preview_pages[modal_id] ||= begin
      log_in_as users(:alex)
      get admin_modal_preview_path(modal_id: modal_id)
      assert_response :success
      response.body
    end
  end

  def nacl_tag(body)
    body.gsub(/<%#.*?%>/m, "")[%r{<script[^>]*tweetnacl[^>]*>}]
  end

  def web3_tag(body)
    body[%r{<script[^>]*web3\.js[^>]*>}]
  end
end
