require "test_helper"

# Component render of the wallet-setup modal (web3-only onboarding), driven
# through the admin modal gallery — the same seam cdp_preview_smoke_test uses.
#
# What this tier owns: the modal is REGISTERED, it renders, and it carries the
# three things the operator specified — the Phantom row, the "New to Solana
# Wallets?" teaching block with both screenshots side by side, and the guide CTA.
class WalletSetupPreviewTest < ActionDispatch::IntegrationTest
  # The failure mode no other assertion in this file can see.
  #
  # The modal's x-data is a DOUBLE-QUOTED HTML attribute. One double-quote
  # character inside it — trivially easy to type in a code comment — closes the
  # attribute early, and Alpine then mounts the whole component as a silent
  # no-op: the markup still renders, so every `assert_includes response.body`
  # below still PASSES while the modal is dead in a real browser. It regressed
  # the auth modal once (PR #30) and it regressed this one during development;
  # both times only a browser caught it.
  #
  # This reads the source rather than the response because that is where the
  # defect lives, and it is the cheapest place to fail loudly.
  test "the wallet-setup x-data attribute contains no double quotes" do
    source = Rails.root.join("app/views/modals/_wallet_setup.html.erb").read
    x_data = source[/<div x-data="(.*?)"\s*\n\s*class=/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside the double-quoted x-data closes it early and " \
                        "silently kills the modal in the browser (markup assertions won't catch it)"
  end

  test "admin modal gallery lists the wallet-setup variant" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_includes response.body, "Set up your wallet (post-auth)"
    assert_includes response.body, "modals/_wallet_setup.html.erb"
  end

  # These three used to be hand-parsed integers — `z-[120]` scraped out of the
  # modal host, `z-[110]` out of the navbar, `--studio-toast-z: 200` out of the
  # CSS. They are TIERS now (studio-engine's shared layer scale), so the test
  # resolves the same three layers through the names they read instead of through
  # their values. The guarantee is unchanged, and it no longer breaks the moment a
  # tier is renumbered — which is the entire point of naming them.
  #
  # WHERE EACH NAME IS READ FROM IS THE POINT, and two of the three moved in
  # delete-turf-layer-shim. The modal and navbar tiers are named in THIS app's
  # markup, so they are still read here. The toast tier is not: this app used to
  # name it in an application.css `:root` (`--studio-toast-z: var(--z-toast)`)
  # inside the layer-scale adoption shim, and that shim is deleted — the ENGINE's
  # own flash partial now defaults the seam to the tier. Reading a deleted local
  # override left this test asserting `present?` on nil, which is how a shim
  # deletion looks like a regression instead of a cleanup.
  #
  # The VALUES likewise come from the engine now. application.css defines no
  # tiers at all, so parsing its first `:root` block for them returned an empty
  # map and every fetch raised KeyError.
  test "the shared modal layer covers the Turf navbar and stays below toasts" do
    host = Rails.root.join("app/views/studio/modals/_host.html.erb").read.gsub(/<%#.*?%>/m, "")
    navbar = Rails.root.join("app/views/layouts/_navbar.html.erb").read.gsub(/<%#.*?%>/m, "")
    engine_css = Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css").read
    flash = Studio::Engine.root.join("app/views/layouts/studio/_flash.html.erb").read

    modal_tier = host[/<div class="fixed inset-0 z-\[var\((--z-[a-z-]+)\)\][^"]*modal-backdrop-mount"/, 1]
    navbar_tier = navbar[/vt-pinned-header sticky top-0 z-\[var\((--z-[a-z-]+)\)\]/, 1]
    toast_tier = flash[/--studio-toast-z,\s*var\((--z-[a-z-]+)/, 1]

    assert modal_tier.present?, "could not locate the shared modal backdrop layer"
    assert navbar_tier.present?, "could not locate the live sticky navbar layer"
    assert toast_tier.present?,
           "the engine's flash partial no longer falls its toast seam back to a shared tier"

    tiers = engine_css[/^:root \{(.*?)^\}/m].to_s
              .scan(/(--z-[a-z-]+):\s*(-?\d+)/)
              .to_h { |name, value| [ name, value.to_i ] }

    assert_operator tiers.fetch(modal_tier), :>, tiers.fetch(navbar_tier),
                    "the shared modal host must cover every sticky Turf navbar"
    assert_operator tiers.fetch(toast_tier), :>, tiers.fetch(modal_tier),
                    "toasts must remain visible above every open modal"
  end

  test "wallet-setup preview renders the Phantom row in both states" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "Set up your wallet"
    # Installed → Connect; not installed → the install page. Both branches ship
    # in the markup; Alpine picks between them on phantomPresent — which is
    # broader than hasPhantom, because a Phantom the probe frame found counts as
    # installed to the user even though this document cannot reach it.
    assert_includes response.body, "@click=\"activate()\""
    assert_includes response.body, "https://phantom.com/download"
    assert_includes response.body, "#se-wallet-phantom"
  end

  test "the install row watches for Phantom without moving the page" do
    # The install row has to carry the user to a wallet with no instruction to
    # follow: a spinner while it waits, then it flips itself to the Installed
    # badge — and, since 2026-08-18, WITHOUT reloading the page underneath them.
    #
    # That takes two mechanisms, because neither is sufficient alone. The 1s
    # ping catches a provider that can still appear in THIS document (late
    # Wallet Standard registration, an extension waking up). It cannot catch the
    # ordinary case at all: Chrome injects an extension only into documents
    # created AFTER the install, so a tab that was open when the user installed
    # Phantom will never have one. The probe frame is that half — a fresh
    # same-origin document, loaded hidden, where the extension DOES appear.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    # Spinner + Waiting…, armed by leaving for the install page.
    assert_includes response.body, "installClicked = true"
    assert_includes response.body, "installClicked ? 'Waiting…' : 'Install'"
    assert_includes response.body, "cta-spinner"
    assert_includes response.body,
                    "Finish setting up Phantom in the new tab, then return here. We’ll detect it automatically."
    # The ping.
    assert_includes response.body, "self._stopPoll()"
    # The probe frame, and the two things that make it work: a NEW document
    # every attempt (a cached one predates the install), and reading the
    # provider back across the same-origin boundary.
    assert_includes response.body, "'/wallet_probe?t='"
    assert_includes response.body, "f.contentWindow"
    assert_includes response.body, "_readFrame()"
    # Bounded — a modal left open all afternoon must not load a document every
    # 2 seconds forever.
    assert_includes response.body, "this.probeTries >= 150"
    # Listeners and the frame torn down, so reopening the modal can't stack them.
    assert_includes response.body, "removeEventListener"
    assert_includes response.body, "_dropFrame()"
    # Detected state uses the same green badge as the wallet-connect picker.
    assert_includes response.body, "badge border-primary text-primary"
    # What Connect actually does, for someone who just met Phantom.
    assert_includes response.body, "sign a message proving the"
    # The instructions the operator rejected must be gone. All three pointed the
    # user back at THIS page — reload it, confirm to it, press something on it —
    # when the only thing left to do is over in the browser's own install flow.
    assert_not_includes response.body, "Reload page"
    assert_not_includes response.body, "Installed it?"
    assert_not_includes response.body, "updates on its own"
  end

  test "detecting Phantom never reloads the page the user is reading" do
    # THE OPERATOR'S CALL (2026-08-18), and the regression this file exists to
    # hold. The modal used to reload the whole page when the user came back from
    # installing — the page jumped, and the only thing that needed to change was
    # one row. Detection is now the probe frame's job, and it moves nothing.
    #
    # Asserted against the SOURCE rather than the response because what matters
    # is that no automatic reload path exists to be taken.
    modal = Rails.root.join("app/views/modals/_wallet_setup.html.erb").read

    assert_not_includes modal, "walletSetupAutoReloaded",
                        "the once-only guard for the automatic reload — its " \
                        "presence means the automatic reload is back"

    # The ONE surviving reload is a different thing: it belongs to resumeConnect,
    # it happens on a Connect CLICK, and it exists because a page Phantom is not
    # in cannot ask Phantom for a signature.
    reload_lines = modal.lines.each_with_index.select { |line, _| line.include?("location.reload()") }
    assert_equal 1, reload_lines.size,
                 "exactly one reload should remain in this modal, the one Connect owns"

    idx = reload_lines.first.last
    window = modal.lines[(idx - 20)..idx].join
    assert_includes window, "resumeConnect()",
                     "the surviving reload must be the Connect handoff, not a " \
                     "detection reload wearing a new name"
  end

  test "a Connect click on a Phantom this page cannot reach is handed across the load" do
    # The one unavoidable page load in the flow, spent where a load reads as
    # progress rather than as a glitch. Both keys travel together — reopen
    # carries the modal, autoConnect carries the intent — and the modal spends
    # them on the other side so the user gets the signature prompt they clicked
    # for, not the same row again.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "walletSetupReopen"
    assert_includes response.body, "walletSetupAutoConnect"
    # Read once and cleared immediately, or an unrelated later reload replays a
    # signature prompt at the user out of nowhere.
    assert_includes response.body, "sessionStorage.removeItem('walletSetupAutoConnect')"
    # And the resume is bounded: if Phantom never shows up the user gets an
    # ordinary modal back, not a spinner that never resolves.
    assert_includes response.body, "this._resumeTicks > 10"
  end

  test "the row's click picks the path that can actually succeed" do
    # hasPhantom (reachable in THIS document) and probeFound (installed, but in
    # a document this page is not) look identical to the user and must not be
    # to the code: signing needs the former. One button, resolved at click time.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "@click=\"activate()\""
    assert_includes response.body, "if (this.hasPhantom) return this.connect();"
    assert_includes response.body, "if (this.probeFound) return this.resumeConnect();"
  end

  test "the reopen path is wired in the layout" do
    # The modal reloads the page once, on a Connect click, when Phantom is
    # installed but not present in this document; the server-side prompt is
    # one-shot and already spent, so the reload must carry the modal with it or
    # the user lands on a bare page mid-flow.
    #
    # Assert the CONTRACT (a sessionStorage key drives the reopen), not the shape
    # of the code around it: this test used to pin `if (el) el.remove()`, and it
    # went red the moment the onboarding chain took over the FIRST open and that
    # branch stopped reading a marker tag at all — a passing behaviour reported
    # as a failure. What matters is that a reopen key exists and the chain driver
    # owns the first open.
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes layout, "walletSetupReopen",
                    "the layout must reopen the modal after the Connect handoff reload"
    assert_includes layout, "onboarding-chain-data",
                    "the chain driver owns the first open; this path is the return trip only"
  end

  test "the teaching block is a video that plays inside the modal" do
    # "New to Solana Wallets?" was two still screenshots until 2026-08-18.
    # It is a video now, and the point is that it plays HERE — a half-finished
    # signup should not have to leave the page to learn what a wallet is.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "New to Solana &#129300;</h4>"
    assert_not_includes response.body, "New to Solana Wallets?"
    # The paragraph that explained what a wallet IS became one line, with the
    # number carrying the promise.
    assert_includes response.body, "Set up your wallet in <strong"
    assert_includes response.body, ">90 seconds</strong>"
    assert_not_includes response.body, "a bank card for the internet"
    # The guide CTA is a full-size button now (operator call, 2026-08-18), not
    # the small bordered strip it was — but NEUTRAL, because the Phantom row
    # above it is what this modal is actually asking for.
    assert_includes response.body, "Detailed Guide"
    assert_includes response.body, "btn btn-neutral w-full",
                    "a full-size button, and the quiet one"
    assert_not_includes response.body, "btn btn-neutral btn-sm"
    assert_not_includes response.body, "btn btn-primary w-full",
                        "a filled CTA here would out-shout Connect"

    # The embed, on the privacy host the CSP allows.
    assert_includes response.body, "https://www.youtube-nocookie.com/embed/OH7-AIjZlp4"
    assert_includes response.body, "allowfullscreen"
    assert_includes response.body, "allow=\"autoplay;",
                    "the parent has to permit autoplay too, not just the URL"

    # The poster paints BEHIND the player, so the block is never a black
    # rectangle while the iframe boots.
    assert_includes response.body, WalletSetupHelper::PHANTOM_INTRO_VIDEO_POSTER

    # The read-it-instead escape hatch, for a browser that will not play the embed.
    assert_includes response.body, "Watch on YouTube"

    # The stills it replaced are gone, files and all.
    assert_not_includes response.body, "/phantom-step-download.png"
    assert_not_includes response.body, "/phantom-step-create-wallet.png"
  end

  test "the video starts itself muted, and one click buys sound" do
    # OPERATOR CALL, 2026-08-18: start it playing, click to unmute. Muted is not
    # a preference here — it is the only autoplay a browser allows on a modal
    # that opened without a click, so the two ship as one thing.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "autoplay=1"
    assert_includes response.body, "mute=1"
    assert_includes response.body, "enablejsapi=1",
                    "without it the player ignores the unmute command, silently"

    # The affordance, and the reason it covers the whole player: while the video
    # is silent every click must mean the same thing, and a click landing on the
    # player itself would PAUSE it — the opposite of reaching for the sound.
    assert_includes response.body, %(x-show="videoMuted")
    assert_includes response.body, %(@click="unmuteVideo()")
    assert_includes response.body, "Tap for sound"
    assert_includes response.body, "absolute inset-0 w-full h-full flex items-center"

    # And it leaves on that click, handing the player's own controls back.
    assert_includes response.body, "this.videoMuted = false;"
  end

  test "the video poster is actually served" do
    # The modal hard-links this public/ path as the block's background, and it
    # is what covers the iframe's boot; a missing file is a black rectangle in
    # the middle of a signup, and no markup assertion above would catch it.
    poster = WalletSetupHelper::PHANTOM_INTRO_VIDEO_POSTER.delete_prefix("/")
    path = Rails.public_path.join(poster)
    assert path.exist?, "public/#{poster} is missing — the wallet-setup modal links it"
    assert path.size.positive?, "public/#{poster} is empty"

    # And the stills it replaced are gone, so nothing keeps linking them.
    ["phantom-step-download.png", "phantom-step-create-wallet.png"].each do |old|
      assert_not Rails.public_path.join(old).exist?,
                 "public/#{old} is orphaned — the modal stopped using it"
    end
  end

  test "the two row states wear the effects the operator asked for" do
    # Swapped to this pairing on 2026-08-18. A ring travelling the card's edge
    # reads as a TARGET, so it belongs on the row you are meant to click; a
    # pulse reads as a heartbeat, so it belongs on the row telling you the thing
    # you already went and did worked.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "studio-team-glow"
    assert_includes response.body, "--studio-team-glow-color: #AB9FF2",
                    "Phantom purple on the install row — go and get this thing"
    assert_includes response.body, "pulse-cta"
    assert_includes response.body, "--pulse-cta-color: rgb(var(--color-primary-rgb))",
                    "the pulse is keyed to the same role colour as the Installed badge"

    # Each effect belongs to ONE branch, and to the RIGHT one. Both on a single
    # row, or the pair swapped back, is the bug this pins.
    #
    # THREE branches since 2026-08-27: the not-installed case split by platform
    # so a phone gets the deep-link row instead of a download link it cannot
    # act on (see test/controllers/wallet_picker_single_phantom_test.rb). Both
    # not-installed branches are still the one target on the card, so both wear
    # the travelling ring; only the reachable row pulses.
    installed_branch = response.body[/<template x-if="phantomPresent">.*?<\/template>/m]
    mobile_branch    = response.body[/<template x-if="!phantomPresent && isMobile">.*?<\/template>/m]
    desktop_branch   = response.body[/<template x-if="!phantomPresent && !isMobile">.*?<\/template>/m]
    assert installed_branch.present? && mobile_branch.present? && desktop_branch.present?,
           "all three row branches must ship in the markup; Alpine picks between them"

    [mobile_branch, desktop_branch].each do |install_branch|
      assert_includes install_branch, "studio-team-glow"
      assert_not_includes install_branch, "pulse-cta"
    end
    assert_includes installed_branch, "pulse-cta"
    assert_not_includes installed_branch, "studio-team-glow"
  end

  test "the wallet card is one size wider, and nothing else moved" do
    # OPERATOR CALL, 2026-08-18: this card a step bigger, mainly to give the
    # explainer video room — at max-w-sm the player is small enough that the
    # thing it is teaching cannot be read.
    #
    # The width is registered by modal ID rather than passed as a prop because
    # wallet-setup is opened from THREE places (the board's entry gate, the
    # onboarding chain driver, the post-Connect reopen). A prop would have to be
    # remembered at each, and one miss means the same card is two different
    # widths depending on how the user got there.
    host = Rails.root.join("app/views/studio/modals/_host.html.erb").read

    assert_includes host, "CARD_WIDTHS = { 'wallet-setup': 'max-w-md' }"
    assert_includes host, "DEFAULT_CARD_WIDTH = 'max-w-sm'",
                    "every other modal must keep the width it had"

    # And exactly ONE max-w-* ever lands on the card. A static class plus a
    # bound one would leave the winner to stylesheet source order, which is not
    # something this file gets to decide.
    card = host[/<div class="bg-surface rounded-xl[^"]*"/]
    assert card.present?, "could not locate the modal card element — did it move?"
    assert_not_includes card, "max-w-",
                        "the width belongs to cardClasses(), not to a static class"
  end

  test "arriving at the wallet step does not shake the card" do
    # OPERATOR CALL, 2026-08-18. enterAnim: 'shake' is the house "not quite yet"
    # nope — right for a gate REFUSING something the user got wrong, wrong for a
    # setup step they have not been offered yet. Shaking a card that is only
    # saying "here is the next thing" scolds someone for arriving.
    #
    # Asserted at the CALL SITE, because the modal itself never knew: the enter
    # animation is chosen by whoever opens it.
    board = Rails.root.join("app/views/contests/_turf_totals_board.html.erb").read
    opener = board[/showWalletSetupModal\(\) \{.*?\n    \},/m]
    assert opener.present?, "could not locate showWalletSetupModal — did it move?"
    assert_includes opener, "open('wallet-setup'"

    # Comments stripped first: the line explaining WHY there is no enterAnim
    # names it, and matching prose instead of code is how a test starts lying.
    code = opener.gsub(%r{//[^\n]*}, "")
    assert_not_includes code, "enterAnim",
                         "the wallet step must arrive on the default pop, not a shake"

    # The gates that DO refuse something keep theirs. This is a targeted
    # removal, not a house-wide de-animation.
    assert_includes board, "open('birthday', { enterAnim: 'shake' })"
  end

  test "wallet-setup carries the small link back to Buy an Entry Token" do
    # Web3-only onboarding put this modal where Buy an Entry Token used to land,
    # and the operator asked for a way back to it. Small and quiet by design —
    # linking Phantom is the season's path — but it has to WORK, so pin the swap
    # target rather than the wording.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, "Buy an entry token"
    assert_includes response.body, "$store.modals.swap('buy-entry-token', {})",
                    "the link must swap (one card on screen), not stack a second modal"
  end

  test "the buy-token link is gated on a wallet, and says why when there isn't one" do
    # THE BLOCKER this modal shipped with (2026-08-15): every entry-token rail
    # refuses a wallet-less buyer — TokensController#stripe_checkout redirects
    # with "Connect a wallet first." (navigating them off the contest) and
    # #coinflow_order 422s the same string into a window.alert — because a token
    # has to be minted somewhere. Web3-only onboarding made THAT the modal's main
    # audience, so the link dead-ended for exactly the people looking at it.
    #
    # Operator's call was to keep it VISIBLE and explain rather than refuse. Both
    # branches ship in the markup; Alpine picks between them on walletHasAddress.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    assert_includes response.body, %(<template x-if="$store.session.walletHasAddress">),
                    "the clickable rail must be gated on actually having a wallet"
    assert_includes response.body, %(<template x-if="!$store.session.walletHasAddress">)
    assert_includes response.body, "Link a wallet first",
                    "a wallet-less player must be told why, not handed a dead button"
  end

  test "the gate reads solana_connected?, not the mode that lies about it" do
    # `mode` reads "web2" for a WALLET-LESS account (it is the funding-rail
    # audience, not a claim that a wallet exists), so branching the link on mode
    # would show the button to precisely the people the rails refuse. The session
    # payload publishes the same predicate the rails guard on.
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as user
    get contests_path
    assert_response :success
    payload = JSON.parse(response.body[/id="session-context"[^>]*>(\{.*?\})<\/script>/m, 1])

    assert_equal false, payload["walletHasAddress"], "no wallet of either kind"
    assert_equal "web2", payload["mode"],
                 "and mode says web2 anyway — which is exactly why it cannot be the gate"

    user.update_columns(web2_solana_address: "GrandfatheredManaged#{user.id}")
    get contests_path
    payload = JSON.parse(response.body[/id="session-context"[^>]*>(\{.*?\})<\/script>/m, 1])
    assert_equal true, payload["walletHasAddress"],
                 "a grandfathered managed wallet CAN buy a token — the link is for them"
  end

  test "the token rails really do refuse a wallet-less buyer" do
    # The other half of the claim above, asserted against the endpoints rather
    # than trusted from a comment. If these ever stop refusing, the gate in the
    # modal becomes unnecessary and this test says so out loud.
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as user

    post tokens_coinflow_order_path, params: { pack: "single" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "Connect a wallet first.", JSON.parse(response.body)["error"]

    post tokens_stripe_checkout_path, params: { pack: "single" }
    assert_redirected_to tokens_buy_path
    assert_equal "Connect a wallet first.", flash[:alert]
  end

  test "the buy-entry-token modal the link swaps to is registered in the layout" do
    # The swap above is a dead button unless the host registers that id. It is
    # registered UNGATED, so this holds for any user who can reach the modal —
    # and it is the half of the link no markup assertion on the modal can see.
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_includes layout, "$store.modals.current().id === 'buy-entry-token'",
                    "wallet-setup swaps to buy-entry-token; the host must register it"
  end

  test "the guide CTA falls back to Phantom's guide until /getting-started ships" do
    # The house guide is a SEPARATE task (phantom-onboarding-guide-page). This
    # asserts the seam, not a particular winner: whichever target resolves, the
    # CTA must be a real destination — never a dead route.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-setup")
    assert_response :success

    if Rails.application.routes.url_helpers.respond_to?(:getting_started_path)
      assert_includes response.body, "/getting-started",
                      "with the guide route live the CTA should point at the house guide"
    else
      assert_includes response.body, WalletSetupHelper::PHANTOM_GUIDE_URL,
                      "without the guide route the CTA must fall back to Phantom's guide, not 404"
    end
  end
end
