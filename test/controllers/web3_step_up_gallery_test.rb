require "test_helper"

# The web3 step-up modal's rendered states, and its place in /admin/modals.
#
# This is the COMPONENT tier: it renders the card in isolation through the
# gallery's preview route and asserts what a reviewer would look at. The
# behaviour that gets the card on screen belongs to the integration tier.
class Web3StepUpGalleryTest < ActionDispatch::IntegrationTest
  REMEMBERED = { provider: "phantom", providerLabel: "Phantom", walletHint: "7xKp…JZ2Q" }.freeze

  def preview(props)
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "web3-step-up", props: props.to_json)
    assert_response :success
  end

  # THIS card's markup only. The preview layout registers EVERY modal in the
  # page, so an assertion against the whole body reads every other card's markup
  # too — which is how a NEGATIVE assertion here ("no filled CTA") failed against
  # a filled CTA belonging to an unrelated modal. The onboarding gallery test
  # carries the same note for the same reason.
  def card
    node = Nokogiri::HTML(response.body).css("template").find { |t|
      t["x-if"].to_s.include?("=== 'web3-step-up'")
    }
    assert node, "no <template> registration found for web3-step-up"
    node.to_html
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
  # broke it. studio-engine 0.67.0, the version this app runs, ships neither the
  # card nor studio/solana. Resolution stays the right instrument now that only one
  # copy is left, for a reason the window merely made obvious: it is the only thing
  # that answers "what does THIS APP render", and the next competing copy will not
  # announce itself either. See ResolvedWeb3StepUp.

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

  # The layout must render the GEM partial. Asserting on the rendered card
  # rather than on the layout source, because what matters is which template
  # actually produced the markup a player sees.
  test "the layout renders the gem partial, with this app's own words" do
    preview(REMEMBERED)
    # The shared default names "on-chain actions"; this app names the two things
    # a player actually loses. If the local passed by the layout ever goes
    # missing, the copy silently reverts to the gem's — hence this assertion.
    assert_includes card, "entering contests",
                    "the app-supplied subtext local is missing — the card fell back to the " \
                    "gem's generic 'on-chain actions' wording"
    assert_includes card, "moving funds"
  end

  # help_url is a String local in the gem but a route helper here. The escape
  # hatch is not decoration: a self-custody wallet is the one credential this app
  # cannot reset for a user, so a card without it strands a locked-out owner.
  test "the help escape hatch survives the switch-over" do
    preview(REMEMBERED)
    assert_includes card, help_path,
                    "the help_url local is missing — the card renders no help line " \
                    "unless the host passes one"
  end

  # --- the remembered-wallet card (the common case) ---------------------------

  test "a remembered wallet gets ONE row naming that wallet" do
    preview(REMEMBERED)
    # The point of the whole provider column: the card offers the brand rather
    # than sending a returning Phantom user back through a three-way picker.
    assert_includes response.body, 'x-text="providerLabel"'
    assert_includes response.body, "'#se-wallet-' + provider",
                    "the row must paint the brand's own sprite icon"
  end

  # The STANDARD web3 auth button (operator call, 2026-08-21) — a wallet row, not
  # a filled CTA, so a wallet reads identically in this card, the connect picker
  # and the wallet-setup step. Asserted as the exact class string those three
  # share: a row that drifts off it is the drift this test exists to catch.
  ROW_CLASSES = "w-full flex items-center gap-3 p-3 rounded-xl bg-surface-alt border border-strong".freeze

  test "the wallet button is the standard wallet ROW, not a filled CTA" do
    preview(REMEMBERED)
    assert_includes card, ROW_CLASSES
    assert_not_includes card, "btn btn-primary btn-lg",
                        "the filled CTA was replaced by the standard wallet row"
    # The row's own furniture: the Installed badge and the chevron, the same two
    # the picker and the setup row carry.
    assert_includes card, 'x-show="!connecting &amp;&amp; detected"'
    assert_includes card, "Installed"
  end

  test "the wallet row glows, because it is the one thing to press" do
    preview(REMEMBERED)
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
    preview(REMEMBERED)
    # wallet_provider.js warns that available() fills in asynchronously as
    # wallets register, and this card auto-opens on the render right after auth —
    # the worst possible moment. A single early read would badge an installed
    # wallet as missing, with no way for the user to correct it.
    assert_includes card, "wallet-standard:register-wallet"
    assert_includes card, "setInterval"
  end

  test "the card shows which wallet it is asking for" do
    preview(REMEMBERED)
    # So signing with a DIFFERENT wallet is a visible choice rather than a
    # surprise account switch — see the partial's header comment.
    assert_includes response.body, 'x-text="walletHint"'
  end

  test "a remembered wallet still offers a way to use another one" do
    preview(REMEMBERED)
    assert_includes response.body, "Use a different wallet"
    assert_includes response.body, "openPicker()"
  end

  # --- the no-memory card (every wallet linked before the column existed) ------

  test "with no remembered wallet the primary action is the picker" do
    preview({})
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
    assert_includes response.body, "get canOneClick() { return !!this.provider && !this.providerMissing; }"
  end

  # --- the escape hatch (operator call) ---------------------------------------

  test "the card is dismissible and reaches a human" do
    preview(REMEMBERED)
    # Advisory, not a lock: a self-custody wallet is the one credential we cannot
    # reset for a user, so the card must never be a dead end.
    assert_includes response.body, "Not now"
    # The entity, not the character: ERB emits &rsquo; verbatim into the body.
    assert_includes response.body, "Can&rsquo;t access your wallet?"
    assert_includes response.body, help_path
  end

  test "dismissing reports to the chain driver rather than just closing" do
    preview(REMEMBERED)
    # The card must not know what follows it — it reports and closes, the same
    # contract the onboarding modal keeps.
    assert_includes response.body, "web3-step-up-dismissed"
  end

  # --- signing --------------------------------------------------------------

  test "signing runs the wallet LOGIN, not the account-link path" do
    preview(REMEMBERED)
    # linkMode posts to /account/link_solana, which binds to the current user but
    # never grants session[:onchain] — the thing this card exists to obtain.
    assert_includes response.body, "solanaConnectAndVerify(name, { linkMode: false })"
  end

  test "an unreachable remembered wallet falls back instead of dead-ending" do
    preview(REMEMBERED)
    # A user on a different machine has the brand remembered and the extension
    # absent. Pressing a button that cannot work is the failure this avoids.
    assert_includes response.body, "this.providerMissing = true"
    assert_includes response.body, "reachable(name)"
  end

  # --- registration ----------------------------------------------------------

  test "the modal is registered in BOTH layouts" do
    # The root cause of the once-blank age-verify card: the app layout and the
    # preview layout each keep their OWN registration list, so a modal added to
    # one renders blank in the other — and blank is indistinguishable from a
    # modal that simply has little in it.
    %w[application modal_preview].each do |layout|
      source = Rails.root.join("app/views/layouts/#{layout}.html.erb").read
      assert_includes source, "$store.modals.current().id === 'web3-step-up'",
                      "web3-step-up is not registered in #{layout}.html.erb"
    end
  end

  # The go-forward rule has to be VISIBLE where it applies, or it deprecates
  # nothing: an agent reading this page decides where to build before it reads
  # any doc. Pinned because a banner is the first thing a redesign drops.
  test "the gallery signposts the engine style guide as the go-forward home" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_includes response.body, "/admin/style#modals"
    assert_includes response.body, "Deprecated"
    # And it must say WHY the page still stands, naming a modal that has no
    # engine card — otherwise the notice reads as an unmade decision.
    assert_includes response.body, "wallet-setup"
  end

  # The gallery's two cards for this modal moved to the engine style guide, which
  # shows both states against the same partial this app renders. Their removal is
  # the "delete second" half of the banner's own port-first rule.
  test "the gallery no longer catalogues a card the engine style guide shows" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_empty AdminController::MODAL_VARIANTS.select { |v| v[:modal_id] == "web3-step-up" },
                 "the engine style guide shows both step-up states against the real partial; " \
                 "a card here is the duplicate"
    assert_empty AdminController::MODAL_FLOWS.select { |f| f[:key] == "web3-step-up" },
                 "the step-up flow's every step was one of those variants"
  end

  # A flow step whose variant was deleted renders the literal string
  # "MISSING VARIANT" on the page rather than failing — so a dangling step is
  # invisible to every other assertion in this file. This is the one that catches
  # it, and it guards the WHOLE registry, not just this modal's former steps.
  test "no flow step points at a variant that no longer exists" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_not_includes response.body, "MISSING VARIANT"
  end

  # A preview showing a shape the server never emits reviews a fiction. The two
  # gallery variants used to be what this guarded; now that the catalogue entries
  # are gone, the props THIS FILE previews are the ones that must stay honest.
  test "the previewed props are shapes the policy can actually produce" do
    emitted = Web3StepUpPolicy.new(nil, session_mode: :web2).to_h.keys
    assert_equal [], REMEMBERED.keys.map(&:to_sym) - emitted,
                 "the remembered-wallet preview passes a prop Web3StepUpPolicy#to_h never emits"
  end
end
