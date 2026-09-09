require "test_helper"

# The web3 step-up modal's rendered states, off the layout that renders them.
#
# This is the COMPONENT tier: it reads the card's own markup out of a real page
# and asserts what a reviewer would look at. The behaviour that gets the card on
# screen belongs to the integration tier (test/integration/web3_step_up_test.rb).
#
# THE SEAM CHANGED ON 2026-09-09. These drove /admin/modals/preview/web3-step-up
# with a props hash until that seam was retired. The props were doing nothing:
# every branch of this card is a client-side x-if over the SAME server render,
# and its locals come from Web3StepUpHelper rather than from the request — so
# the remembered-wallet preview and the no-memory preview returned byte-identical
# HTML, and both are simply the page now. What the props DID buy — proof that the
# shapes reviewed are shapes the server emits — is asserted where the server
# emits them: test/integration/web3_step_up_test.rb reads provider,
# providerLabel and walletHint out of the real #web3-step-up-data payload after a
# real magic-link sign-in.
#
# THE FILE'S NAME IS OLDER THAN ITS SUBJECT. There is no gallery; renaming it is
# a separate chore, deliberately not folded into a deletion that already touches
# four open PRs' worth of the same files.
class Web3StepUpGalleryTest < ActionDispatch::IntegrationTest
  # ONE RENDER, read by every assertion here. The card is a static registration
  # in layouts/application, identical for every viewer, so re-fetching per test
  # would buy nothing.
  def step_up_page
    @step_up_page ||= modal_host_page
  end

  # THIS card's markup only. The layout registers EVERY modal in the page, so an
  # assertion against the whole body reads every other card's markup too — which
  # is how a NEGATIVE assertion here ("no filled CTA") once failed against a
  # filled CTA belonging to an unrelated modal, on a page carrying a THIRD of the
  # cards this one does. The onboarding test carries the same note for the same
  # reason.
  #
  # RAW, not parsed: the x-data assertions in this file are about delimiters, and
  # re-serialising a mangled attribute hides exactly the damage being looked for.
  def card
    cards = modal_registration_sources(step_up_page, "web3-step-up")
    assert_equal 1, cards.length,
                 "expected exactly one web3-step-up registration on layouts/application; found " \
                 "#{cards.length}"
    cards.first
  end

  # THE PARTIAL LIVES IN solana-studio NOW (2026-09-01). studio-engine lifted
  # this card out of this app on 2026-08-21, this app kept rendering a second copy
  # until 2026-08-24, and /tasks/turf-rides-gem-modals then moved the shared copy
  # on to solana-studio as `solana_studio/modals/_web3_step_up`. This app keeps
  # the guard rather than handing it entirely to the owning gem because THIS app
  # is what renders the card to a real player.
  #
  # RESOLVED, NOT PATH-JOINED. This used to read a fixed path into Studio::Engine.
  # A fixed path answers "what does that gem ship?", not "what does this app
  # render", and the two diverged the moment the card moved: studio-engine went on
  # shipping its copy until /tasks/drop-engine-web3-modals deleted it in 0.66.2, so
  # the old join would have kept PASSING against a partial this app no longer
  # renders, then died with ENOENT at that release rather than at the change that
  # broke it. This app runs above that floor, so studio-engine hands it neither the
  # card nor a studio/solana directory. Resolution stays the right instrument now
  # that only one copy is left, for a reason the window merely made obvious: it is
  # the only thing that answers "what does THIS APP render", and the next competing
  # copy will not announce itself either. See ResolvedWeb3StepUp.

  # Same failure mode the onboarding and wallet-setup modals each carry a guard
  # for: a double quote inside the double-quoted x-data closes the attribute
  # early and Alpine mounts the component as a SILENT no-op — the markup still
  # renders, so every assert_includes below still passes while the modal is dead
  # in a browser. It has bitten this codebase twice, so every new step-machine
  # modal gets this test.
  test "the x-data attribute contains no double quotes" do
    source = ResolvedWeb3StepUp.source
    x_data = source[/x-data="(\{.*?\})"\s*\n/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside the double-quoted x-data closes it early and " \
                        "silently kills the modal in the browser (markup assertions won't catch it)"
    assert_not_includes x_data, "`",
                        "a backtick in an ERB-rendered attribute is the other way this dies"
  end

  # --- the switch-over itself -------------------------------------------------

  # The duplicate is what this change exists to remove, so its absence is the
  # assertion. A reintroduced app-local copy would render fine and pass every
  # markup assertion in this file while quietly restoring the drift.
  test "this app carries no second copy of the partial" do
    assert_not Rails.root.join("app/views/modals/_web3_step_up.html.erb").exist?,
               "app/views/modals/_web3_step_up.html.erb is back — solana-studio owns this " \
               "card (solana_studio/modals/_web3_step_up); two files for one modal is the " \
               "drift this removed"
  end

  # The card this app renders must be the GEM's, and it must not resolve inside
  # this app's own app/views. Install-agnostic on purpose — see ResolvedWeb3StepUp
  # for why asserting on "/gems/" is the wrong shape.
  test "the step-up card resolves to the gem, not to a copy in this app" do
    assert_not ResolvedWeb3StepUp.shadowed_by_app?,
               "solana_studio/modals/web3_step_up resolved to " \
               "#{ResolvedWeb3StepUp.identifier}, which is inside this app's own app/views — " \
               "the fork is back as a shadow at the gem's virtual path"
  end

  # A bare object carrying the helper and this app's routes. The SEAM is the
  # tier that can see a local being added back; the rendered card cannot,
  # because the gem's default and an app override land in the same slot and the
  # markup looks the same either way — which is exactly how the `subtext`
  # override survived a copy change nobody could see on screen.
  class LocalsProbe
    include Rails.application.routes.url_helpers
    include Web3StepUpHelper
  end

  # THE CARD'S WORDS ARE THE GEM'S NOW (2026-09-06). This app used to pass its
  # own four-line `subtext:`, so when solana-studio cut the body to one line the
  # shared default changed and the card a player actually met did not — it kept
  # the long copy AND gained the new address line, which is more copy rather
  # than less. The override is gone.
  #
  # Asserted as ONE LOCAL and an ABSENCE, never as the gem's current sentence:
  # the gem owns those words and will change them again, and pinning them here
  # rebuilds the fork inside the test suite. This is also why the assertion is
  # version-agnostic — the release sweep bumps this app's lock without touching
  # this file, so anything pinned to one release's copy breaks at the bump.
  test "the step-up seam passes this app's help route and nothing else" do
    locals = LocalsProbe.new.web3_step_up_locals

    assert_equal [:help_url], locals.keys,
                 "every other local is a gem default that already matches this app; a second " \
                 "one here is a second place for the card to drift"
    assert_equal help_path, locals[:help_url]
  end

  test "the rendered card carries no forked copy of the gem's body" do
    assert_not_includes card, "entering contests",
                        "this app's forked subtext is back — the card's copy belongs to the gem"
    assert_not_includes card, "moving funds"
  end

  # help_url is a String local in the gem but a route helper here. The escape
  # hatch is not decoration: a self-custody wallet is the one credential this app
  # cannot reset for a user, so a card without it strands a locked-out owner.
  test "the help escape hatch survives the switch-over" do
    assert_includes card, help_path,
                    "the help_url local is missing — the card renders no help line " \
                    "unless the host passes one"
  end

  # --- the remembered-wallet card (the common case) ---------------------------

  test "a remembered wallet gets ONE row naming that wallet" do
    # The point of the whole provider column: the card offers the brand rather
    # than sending a returning Phantom user back through a three-way picker.
    assert_includes step_up_page, 'x-text="providerLabel"'
    assert_includes step_up_page, "'#se-wallet-' + provider",
                    "the row must paint the brand's own sprite icon"
  end

  # The STANDARD web3 auth button (operator call, 2026-08-21) — a wallet row, not
  # a filled CTA, so a wallet reads identically in this card, the connect picker
  # and the wallet-setup step. Asserted as the exact class string those three
  # share: a row that drifts off it is the drift this test exists to catch.
  ROW_CLASSES = "w-full flex items-center gap-3 p-3 rounded-xl bg-surface-alt border border-strong".freeze

  test "the wallet button is the standard wallet ROW, not a filled CTA" do
    assert_includes card, ROW_CLASSES
    assert_not_includes card, "btn btn-primary btn-lg",
                        "the filled CTA was replaced by the standard wallet row"
    # The row's own furniture: the Installed badge and the chevron, the same two
    # the picker and the setup row carry.
    # SPELLED AS THE PAGE SPELLS IT. This read `&amp;&amp;` until 2026-09-09, and
    # that was an artefact of how the slice was taken rather than a fact about
    # the card: the old `card` helper parsed the body with Nokogiri and
    # re-serialised the node, which re-escapes a bare `&`. The response itself
    # carries `&&`, which is also what Alpine needs — so the entity form was a
    # string the browser never receives, and only a parser round-trip could
    # produce it. Reading the raw registration made the difference visible.
    assert_includes card, 'x-show="!connecting && detected"'
    assert_includes card, "Installed"
  end

  test "the wallet row glows, because it is the one thing to press" do
    # pulse-cta is the engine's attention beat (engine-motion.css). Tuned to the
    # same values the wallet-setup connect row uses so the two beat alike.
    assert_includes card, "pulse-cta"
    # The engine spells this var(--color-primary); this app's own copy of the
    # card spelled the same colour rgb(var(--color-primary-rgb)). Both resolve —
    # Studio::ThemeResolver emits BOTH names unconditionally (theme_resolver.rb
    # :110-111, from one primary), so the switch-over changed the spelling and
    # not the pixel. Asserted because a glow that silently stops rendering is
    # exactly the kind of loss a markup test is here to catch.
    assert_includes card, "--pulse-cta-color: var(--color-primary)"
  end

  test "presence is polled, never read once at mount" do
    # wallet_provider.js warns that available() fills in asynchronously as
    # wallets register, and this card auto-opens on the render right after auth —
    # the worst possible moment. A single early read would badge an installed
    # wallet as missing, with no way for the user to correct it.
    assert_includes card, "wallet-standard:register-wallet"
    assert_includes card, "setInterval"
  end

  test "the card shows which wallet it is asking for" do
    # So signing with a DIFFERENT wallet is a visible choice rather than a
    # surprise account switch — see the partial's header comment.
    assert_includes step_up_page, 'x-text="walletHint"'
  end

  # A REMEMBERED WALLET CAN STILL BE THE WRONG ONE, and the card must let the
  # user say so — otherwise naming the wallet makes a mismatch visible without
  # making it actionable, which is worse than not naming it.
  #
  # THE ROUTE IS THE INVARIANT; ITS SPELLING IS THE GEM'S AND IT MOVED. Up to
  # solana-studio 0.6.0 it was a full-width "Use a different wallet" row; the
  # next release replaces that row with a quiet "Not your wallet?" link beside
  # the address (operator call). This app renders whichever its LOCK resolves,
  # and the release sweep bumps that lock without touching this file — so an
  # assertion pinned to one spelling is red on one side of the bump or the
  # other. The handler is what does not move, and the gem's own render tier
  # pins the new link tightly; re-asserting it here would only re-couple the
  # repos, which is the mistake ResolvedWeb3StepUp's own note warns about.
  test "a remembered wallet still offers a way to use another one" do
    assert_includes step_up_page, "openPicker()"
    assert_match(/Use a different wallet|Not your wallet\?/, card,
                 "the remembered-wallet card offers no route to the picker at all")
  end

  # ...and the route lands somewhere this app actually registers. The gem swaps
  # by ID, so a picker id this layout never registered opens nothing and the
  # user is left on a card whose correction path silently does nothing.
  test "the picker the card swaps to is one this app registers" do
    assert_includes step_up_page, "swap('wallet-connect'"
    assert_includes step_up_page, "backTo: 'web3-step-up'",
                    "or the picker's Back button strands the user instead of returning"
    assert_includes step_up_page, "$store.modals.current().id === 'wallet-connect'",
                    "the preview layout must register the modal the card swaps to"
  end

  # --- the no-memory card (every wallet linked before the column existed) ------

  test "with no remembered wallet the primary action is the picker" do
    assert_includes card, "Connect your wallet"
    # Same row shape as the remembered half, so the two look like one card.
    assert_includes card, ROW_CLASSES
    # ...and its mark is a DRAWN wallet, not an emoji. The first pass used
    # U+1F45B PURSE, which renders as a pink handbag inches from Phantom's real
    # brand mark — the one thing on the card belonging to no design system.
    # Pinned by codepoint because the next well-meaning emoji looks fine in a
    # commit diff and wrong on screen.
    assert_not_includes card, "\u{1F45B}"
    assert_not_includes card, "&#128091;"
    assert_includes card, "<svg", "the fallback tile draws its own wallet mark"
    # canOneClick is what switches the two halves; assert the rule itself, since
    # both branches render into the same document as <template>s.
    assert_includes step_up_page, "get canOneClick() { return !!this.provider && !this.providerMissing; }"
  end

  # --- the escape hatch (operator call) ---------------------------------------

  test "the card is dismissible and reaches a human" do
    # Advisory, not a lock: a self-custody wallet is the one credential we cannot
    # reset for a user, so the card must never be a dead end.
    assert_includes step_up_page, "Not now"
    # The entity, not the character: ERB emits &rsquo; verbatim into the body.
    assert_includes step_up_page, "Can&rsquo;t access your wallet?"
    assert_includes step_up_page, help_path
  end

  test "dismissing reports to the chain driver rather than just closing" do
    # The card must not know what follows it — it reports and closes, the same
    # contract the onboarding modal keeps.
    assert_includes step_up_page, "web3-step-up-dismissed"
  end

  # --- signing --------------------------------------------------------------

  test "signing runs the wallet LOGIN, not the account-link path" do
    # linkMode posts to /account/link_solana, which binds to the current user but
    # never grants session[:onchain] — the thing this card exists to obtain.
    assert_includes step_up_page, "solanaConnectAndVerify(name, { linkMode: false })"
  end

  test "an unreachable remembered wallet falls back instead of dead-ending" do
    # A user on a different machine has the brand remembered and the extension
    # absent. Pressing a button that cannot work is the failure this avoids.
    assert_includes step_up_page, "this.providerMissing = true"
    assert_includes step_up_page, "reachable(name)"
  end

  # --- registration ----------------------------------------------------------

  test "every layout that mounts the modal host registers this card" do
    # THE ROOT CAUSE OF THE ONCE-BLANK AGE-VERIFY CARD: two layouts each kept
    # their OWN registration list, so a modal added to one rendered blank in the
    # other — and blank is indistinguishable from a modal that simply has little
    # in it. layouts/modal_preview was deleted on 2026-09-09, which is what
    # actually retired that failure mode. The property survives it and does not
    # depend on there being two: a layout that mounts the host and does not
    # register this id serves an empty card.
    #
    # DERIVED FROM THE GLOB, not from a named pair. The old form listed
    # `application` and `modal_preview` by name, so it could only ever check the
    # layouts someone remembered to add — a third layout mounting the host would
    # have slipped past it silently, which is the same shape of miss as the
    # second list it was written about.
    mounting = Dir[Rails.root.join("app/views/layouts/*.html.erb").to_s].select do |path|
      File.read(path).gsub(/<%#.*?%>/m, "").include?(%(render "studio/modals/host"))
    end

    assert_operator mounting.length, :>=, 1,
                    "no layout in this app mounts the modal host, so the scan below matched " \
                    "nothing and this assertion is vacuous"

    offenders = mounting.reject do |path|
      File.read(path).include?("$store.modals.current().id === 'web3-step-up'")
    end

    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
                 "these layouts mount the modal host without registering web3-step-up, so the " \
                 "card opens EMPTY there"
  end

  # FOUR GALLERY TESTS LEFT HERE, and a fifth followed the preview seam.
  #
  # Three went with /admin/modals on 2026-09-09: they asserted the gallery's
  # deprecation banner named the style guide, that its registry no longer carded
  # web3-step-up, and that no flow step rendered "MISSING VARIANT". All three were
  # about the SHOWROOM, and the showroom is gone.
  #
  # The fourth ("the previewed props are shapes the policy can actually produce")
  # went with /admin/modals/preview on the same day, and it is worth saying where
  # it landed rather than only that it left. It pinned this file's REMEMBERED
  # constant against Web3StepUpPolicy#to_h — a guard against reviewing a shape
  # the server never emits. With no preview there are no previewed props, and a
  # constant pinned only to its own mirror-check asserts nothing. The question it
  # was reaching for is answered one tier up and against the real payload:
  # test/integration/web3_step_up_test.rb signs a wallet account in by magic link
  # and reads provider, providerLabel and walletHint out of the
  # #web3-step-up-data blob the layout actually emits.
end
