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

  # Same failure mode the onboarding and wallet-setup modals each carry a guard
  # for: a double quote inside the double-quoted x-data closes the attribute
  # early and Alpine mounts the component as a SILENT no-op — the markup still
  # renders, so every assert_includes below still passes while the modal is dead
  # in a browser. It has bitten this codebase twice, so every new step-machine
  # modal gets this test.
  test "the x-data attribute contains no double quotes" do
    source = Rails.root.join("app/views/modals/_web3_step_up.html.erb").read
    x_data = source[/x-data="(\{.*?\})"\s*\n/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside the double-quoted x-data closes it early and " \
                        "silently kills the modal in the browser (markup assertions won't catch it)"
    assert_not_includes x_data, "`",
                        "a backtick in an ERB-rendered attribute is the other way this dies"
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
    assert_includes card, "--pulse-cta-color: rgb(var(--color-primary-rgb))"
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

  test "the gallery lists the step-up flow with both of its states" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_includes response.body, "Web3 step-up (web2 auth by a wallet account)"
    assert_not_includes response.body, "MISSING VARIANT"
  end

  test "both variants carry props the policy can actually produce" do
    # A gallery variant showing a shape the server never emits reviews a fiction.
    variants = AdminController::MODAL_VARIANTS.select { |v| v[:modal_id] == "web3-step-up" }
    assert_equal 2, variants.length, "the two halves of the provider memory are both worth reviewing"
    variants.each do |variant|
      assert_equal [], variant[:props].keys.map(&:to_sym) - Web3StepUpPolicy.new(nil, session_mode: :web2).to_h.keys,
                   "variant #{variant[:key]} passes a prop Web3StepUpPolicy#to_h never emits"
    end
  end
end
