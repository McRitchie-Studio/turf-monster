require "test_helper"

# The ✨ entry-token badge and the navbar balance SLOT.
#
# The badge used to be a "🎟️ Entry" pill wedged between the wallet amount and
# the gear icon, and a $0 balance held by a token-holder simply vanished. Both
# moved (task: sparkle-free-entry-badge):
#
#   1. the badge is a small ✨ circle immediately LEFT of the profile avatar,
#   2. the balance slot swaps that $0 for "✨ Free Entry" instead of hiding it,
#   3. hovering the badge peeks that same label OVER the amount (the answer to
#      "what is this sparkle?"), through `freeEntryHover` in the _user_nav
#      Alpine scope,
#   4. a level-up glows the badge (.free-entry-glow, armed from the layout's
#      navbar-seeds-update listener).
#
# Cache store: the test env runs :null_store (reads always nil), so both
# cache-first reads — display_balance and display_entry_token_count — would be
# permanently "loading" and the $0-with-token branch could never render. Each
# test injects a real, COLD MemoryStore and writes the same keys the controller
# reads, per the injected-store pattern in display_entry_token_count_test.rb.
class EntryTokenBadgePlacementTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
  end

  # Renders the contests index (navbar only, no on-chain body read) with the
  # navbar's three cache-first values pre-warmed to the given state.
  def render_navbar(usdc:, tokens:)
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      # These specimens warm the fixture's Phantom token cache, so establish the
      # matching signer session. A web2 session must now read its managed wallet
      # instead, which is covered by display_entry_token_count_test.
      log_in_as_onchain(@user)
      store.write("usdc_balance:#{@user.id}", usdc)
      store.write("usdt_balance:#{@user.id}", 0.0)
      store.write(
        Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address),
        Array.new(tokens) { { consumed: false } }
      )
      get contests_path
      assert_response :success
      yield response.body
    end
  end

  test "the ✨ badge tucks into the avatar corner, out of the row's flow" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      # Match the ATTRIBUTE form: the layout's gear-sidebar delegation script
      # names these same hooks as CSS selectors earlier in the document, and a
      # bare index() would find that string instead of the element.
      badge_at    = body.index('data-free-entry-badge="true"')
      username_at = body.index('data-username-display="true"')
      avatar_at   = body.index('data-profile-image-toggle="true"')
      balance_at  = body.index('data-balance-display="true"')

      assert badge_at, "the entry-token badge should render for a token holder"
      assert badge_at > username_at,
        "the badge moved out of the balance row — it must render AFTER the username"
      assert badge_at < avatar_at,
        "the badge must render immediately BEFORE the avatar toggle"
      assert balance_at < username_at,
        "sanity: the balance still leads the row"

      # The tuck is absolute, not a negative margin: the badge's .hidden lives
      # on the BUTTON, so a flow-positioned wrapper would survive a hidden
      # badge and drag the avatar left into the username. ml-3 on the cluster
      # reserves the 8px of badge that overhangs the avatar.
      cluster = body[username_at, (avatar_at - username_at) + 400]
      assert_includes cluster, %(class="relative ml-3 flex flex-shrink-0 items-center")
      assert_includes cluster, %(class="absolute -left-2 -top-1 z-20")
      assert_match(/dm-green relative z-10/, cluster,
        "the avatar keeps its own stacking rung under the badge")
    end
  end

  test "the badge wears the house legendary treatment, in theme colors" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      badge = body[body.index('data-free-entry-badge="true"') - 900, 1200]
      assert_includes badge, "free-entry-badge legendary-badge",
        "the disc wears the house legendary treatment"
      assert_includes badge, "w-5 h-5 rounded-full",
        ".legendary-badge is paint only — the caller brings the geometry"
    end
    css = Rails.root.join("app/assets/tailwind/application.css").read
    treatment = css[css.index(".legendary-badge {"), 900]
    # The whole point of the house version: THEME colors, not the engine's
    # fixed 8-stop rainbow. A literal hex here would be a re-forked spectrum.
    assert_includes treatment, "var(--color-primary-500"
    assert_includes treatment, "var(--color-warning"
    assert_includes treatment, "background-size: 300% 300%",
      "the gradient must overhang the element or there is nothing to pan"
    assert_includes css, "@keyframes legendary-pan"
    refute_includes treatment, "rgba(var(",
      "legacy rgba(var(...), A) drops a space-separated RGB var — use rgb(var(...) / A)"
    # Geometry stays OUT of the treatment so it drops onto a pill too.
    refute_match(/\bwidth:/, treatment)
    refute_match(/\bpadding:/, treatment)
  end

  test "the badge casts a contact shadow onto the avatar it overlaps" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    treatment = css[css.index(".legendary-badge {"), 1100]
    # The knob has to be CONSUMED by the treatment's own box-shadow, not just
    # declared: a --lb-contact nothing reads is a no-op that still reads as a
    # fix. And it must lead the list — a contact shadow behind the outer bloom
    # is washed out by it.
    assert_includes treatment, "--lb-contact:"
    shadow = treatment[treatment.index("box-shadow:"), 260]
    assert_includes shadow, "var(--lb-contact)"
    assert shadow.index("var(--lb-contact)") < shadow.index("rgba(255, 255, 255"),
      "the contact shadow must sit UNDER the white bloom in the stack, not over it"

    # The caller supplies the direction, because only the caller knows which way
    # the thing it sits on lies. Here: down and right, onto the avatar.
    #
    # COMPOUND — but not for the reason this comment first gave. The knob's
    # original home was ABOVE the treatment, where a bare one-class selector
    # ties .legendary-badge and loses on source order; the shadow computed to
    # the transparent default while the stylesheet read correct. Moving it
    # BELOW the treatment is what fixes that (mutation-tested: the bare form
    # there still paints). The compound is what keeps it fixed through a
    # reorder. Both halves are asserted because either one alone is a
    # one-edit-from-broken arrangement, and the paint proof lives in
    # e2e/entry_badge_sidebar.spec.js where a browser can see it.
    assert_match(/\.free-entry-badge\.legendary-badge \{ --lb-contact: \d+px \d+px/, css)
    knob_at = css.index(".free-entry-badge.legendary-badge { --lb-contact:")
    assert knob_at > css.index(".legendary-badge {"),
      "the knob must sit BELOW the treatment it overrides — above it, source order eats the value"
    knob = css[knob_at, 110]
    assert_includes knob, "rgba(0, 0, 0,", "a contact shadow is DARK — that is the whole job"
    # Redeclaring box-shadow on .free-entry-badge instead would silently drop
    # the treatment's rim and bloom, which is exactly the trap the knob avoids.
    refute_match(/\.free-entry-badge \{[^}]*box-shadow/m, css)
  end

  test "clicking the badge opens the settings sidebar, not a popover of its own" do
    render_navbar(usdc: 12.0, tokens: 2) do |body|
      badge = body[body.index('data-free-entry-badge="true"') - 1200, 1600]

      assert_includes badge, '@click.stop="$store.sidebars.gearOpen = !$store.sidebars.gearOpen"',
        "the badge joins the avatar and username in toggling one sidebar"
      # .stop is not decoration: the panel closes on @click.outside, and the
      # badge IS outside it, so an unstopped click opens and shuts in one go.
      assert_includes badge, "@click.stop=", "an unstopped click would reach the panel's @click.outside"
      assert_includes badge, 'aria-controls="gear-sidebar gear-sidebar-mobile"'
      # The label must carry NO server-rendered count. updateNavTokens writes
      # classList + dataset.tokenCount and nothing else, so a number baked in
      # here goes stale the moment the count moves — and because the badge is
      # HIDDEN at zero, a stale label is announced ONLY when it is wrong. The
      # accurate count lives in the sidebar chip this button opens.
      assert_includes badge, 'aria-label="Free entry tokens — open settings"'
      refute_match(/aria-label="[^"]*\d/, badge,
        "a count in the label is unreachable by updateNavTokens and goes stale")
      assert_includes badge, 'aria-haspopup="dialog"'
      assert_includes badge, ":aria-expanded="

      # The popover is gone — markup, factory mount, and all.
      refute_includes badge, 'x-show="open"'
      refute_includes badge, "toggle()"
      refute_includes badge, "Entry Token<span"
      refute_includes badge, "x-data=\"entryTokenBadge",
        "the badge stopped needing a scope when the popover left"
    end
  end

  test "hover still peeks the label after the click became a sidebar toggle" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      badge = body[body.index('data-free-entry-badge="true"') - 1200, 1600]
      assert_includes badge, '@mouseenter="freeEntryHover = true"'
      assert_includes badge, '@focus="freeEntryHover = true"'
    end
  end

  test "the sidebar carries a live free-entry chip in the same treatment" do
    render_navbar(usdc: 12.0, tokens: 2) do |body|
      assert_includes body, 'data-free-entry-chip="true"'
      chip = body[body.index('data-free-entry-chip="true"') - 300, 900]

      assert_includes chip, "legendary-badge", "chip and disc read as one prize"
      assert_includes chip, 'x-data="entryTokenBadge({ initialCount: 2 })"'
      assert_includes chip, 'x-show="count > 0"'
      # Server-rendered text under the x-text bindings, so the chip is right
      # before Alpine boots and right without JS at all.
      assert_includes chip, "Free Entries"
      assert_includes chip, "count === 1 ? 'Free Entry' : 'Free Entries'",
        "'2 Free Entrys' is what a bare plural suffix would have produced"

      # body_html is rendered into BOTH panels, so the chip mounts twice — two
      # Alpine scopes both subscribed to the same event. That is the reason the
      # count is not synced by querySelector: it would update only one.
      assert_equal 2, body.scan('data-free-entry-chip="true"').length,
        "desktop and mobile panels each get their own chip"
    end
  end

  test "the sidebar chip is pre-hidden for a zero-token user" do
    render_navbar(usdc: 12.0, tokens: 0) do |body|
      chip = body[body.index('data-free-entry-chip="true"') - 300, 500]
      assert_includes chip, "style=\"display: none;\"",
        "without the server pre-set there is a pre-Alpine flash of a chip promising nothing"
      assert_includes chip, 'x-show="count > 0"'
    end
  end

  test "the badge is a sparkle, not the retired ticket pill" do
    render_navbar(usdc: 12.0, tokens: 2) do |body|
      badge = body[body.index("data-free-entry-badge") - 900, 1200]
      assert_includes badge, "✨"
      refute_includes badge, "🎟️", "the ticket emoji was retired for the sparkle"
    end
  end

  test "a $0 balance with a token reads '✨ Free Entry' instead of vanishing" do
    render_navbar(usdc: 0.0, tokens: 1) do |body|
      assert_includes body, "data-free-entry-label"
      label = body[body.index("data-free-entry-label") - 400, 700]
      assert_match(/class="free-entry-label[^"]*\bis-active\b/, label,
        "the label must be the ACTIVE face of the slot at $0-with-token")
      assert_includes label, "Free Entry"

      balance = body[body.index("data-balance-display") - 500, 700]
      assert_includes balance, "hidden", "the redundant $0 amount stays hidden"
    end
  end

  test "a funded balance shows the amount and leaves the label dormant" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      assert_includes body, "$12"
      label = body[body.index("data-free-entry-label") - 400, 700]
      refute_includes label, "is-active",
        "the label only takes over the slot at $0-with-token"
    end
  end

  test "a $0 balance with NO token still shows the $0 amount" do
    render_navbar(usdc: 0.0, tokens: 0) do |body|
      label = body[body.index("data-free-entry-label") - 400, 700]
      refute_includes label, "is-active"
      assert_includes body, "$0"
    end
  end

  test "hovering the badge peeks the label over the amount" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      # One Alpine channel, three ends: declared on the _user_nav wrapper, set
      # by the badge, read by the balance slot.
      assert_includes body, 'x-data="{ freeEntryHover: false }"'
      assert_includes body, '@mouseenter="freeEntryHover = true"'
      assert_includes body, '@focus="freeEntryHover = true"',
        "keyboard focus must open the same explanation as hover"
      assert_includes body, %(x-bind:class="freeEntryHover ? 'fe-peek' : ''")
    end
  end

  test "the level-up listener arms the badge glow" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      assert_includes body, "window.armFreeEntryGlow && window.armFreeEntryGlow()",
        "a SEEDS_PER_LEVEL crossing must glow the badge the token landed in"
    end
  end

  # ── A ZERO-TOKEN USER MUST NOT SEE THE BADGE ────────────────────────────
  #
  # The badge's `.hidden` rides the BUTTON (so updateNavTokens can surface it
  # after a mint without a reload), and for a long time it did not hide
  # anything. `.hidden{display:none}` and `.inline-flex{display:inline-flex}`
  # are both single-class selectors inside Tailwind's `@layer utilities`: they
  # TIE on specificity, so source order decides, and Tailwind emits `.hidden`
  # first. The later `.inline-flex` won; a user holding zero entry tokens kept
  # a live 20x20 sparkle, and updateNavTokens(0) was inert.
  #
  # WHAT THIS TIER CAN AND CANNOT PROVE. It can prove the server puts `.hidden`
  # on the right element, and that the stylesheet ships a rule which OUT-RANKS
  # the tying utilities rather than merely joining them. It CANNOT prove the
  # paint — no browser here, and a class list is exactly the evidence that was
  # true throughout the bug. The paint is measured in
  # e2e/navbar_layout.spec.js, "a zero-token user's ✨ badge paints nothing at
  # all", which diffs the badge's slot against the same slot with the badge
  # deleted from the DOM. Read the two together; neither stands alone.
  test "[component] a zero-token user's badge renders hidden, on the button" do
    render_navbar(usdc: 12.0, tokens: 0) do |body|
      at = body.index('data-free-entry-badge="true"')
      assert at, "the badge must still RENDER at zero tokens — updateNavTokens " \
        "surfaces it after a mint, and it cannot surface an element that is absent"
      button = body[at - 900, 1200]
      klass  = button[/class="(free-entry-badge[^"]*)"/, 1]
      assert klass, "could not find the badge button's class list"
      assert_includes klass.split, "hidden",
        "a zero-token render must carry .hidden on the button itself"
    end
  end

  test "[component] a token holder's badge renders without .hidden" do
    render_navbar(usdc: 12.0, tokens: 1) do |body|
      at = body.index('data-free-entry-badge="true"')
      klass = body[at - 900, 1200][/class="(free-entry-badge[^"]*)"/, 1]
      assert klass, "could not find the badge button's class list"
      refute_includes klass.split, "hidden",
        "a token holder must see the badge"
    end
  end

  # THE CASCADE HALF. The button carries a Tailwind display utility
  # (`inline-flex`) alongside `hidden`, and two single-class utilities in the
  # same layer cannot settle that by specificity. So the stylesheet must carry
  # an override that OUT-RANKS both, and this asserts the two properties that
  # make it out-rank them rather than just asserting the text is present:
  #
  #   1. COMPOUND — `.free-entry-badge.hidden` is (0,2,0) against the
  #      utilities' (0,1,0), so it wins no matter which order Tailwind emits.
  #   2. UNLAYERED — it sits outside `@layer`, and an unlayered rule beats
  #      every layered one regardless of specificity.
  #
  # Belt and braces, but NOT two independent guarantees — they are checked
  # together because each covers the other's blind spot. Unlayered alone wins
  # at any specificity. Compound alone wins only against rules in the SAME
  # layer: move this rule into `@layer components` and its (0,2,0) LOSES to
  # the utilities' (0,1,0), because layer order outranks specificity. That is
  # why assertion 2 is not decoration.
  #
  # WHAT THIS TEST DOES NOT PROVE. It proves the override out-ranks the two
  # utilities NAMED above; it does not prove nothing out-ranks the OVERRIDE.
  # Another unlayered rule at (0,2,0) or higher that sets `display` and is
  # emitted later — `.free-entry-badge.legendary-badge { display: inline-flex }`,
  # say — reopens the bug with this test still green. The `refute_match` below
  # only guards `.free-entry-badge` itself. The net for that case is the e2e
  # paint spec, which measures pixels and cannot be fooled by a cascade the
  # source-level checks did not anticipate.
  #
  # A future edit that drops the override, or moves it inside a @layer, or
  # weakens it to a bare `.hidden`, reddens here.
  test "[component] the stylesheet out-ranks the tying display utilities" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    rule = css[/^\s*(\.free-entry-badge\.hidden|\.hidden\.free-entry-badge)\s*\{[^}]*\}/]
    assert rule, "application.css must ship a compound override that makes .hidden " \
      "beat the .inline-flex beside it — a bare .hidden cannot, they tie"
    assert_match(/display:\s*none/, rule,
      "the override must resolve display to none")

    # UNLAYERED: no `@layer` block encloses it. Counted rather than grepped —
    # `@layer` appears in this file for other reasons.
    #
    # COMMENTS ARE STRIPPED BEFORE COUNTING, and that is not cosmetic. This
    # file's prose is full of braces — `{_blobs,_circles,_gradient}`,
    # `:class="{ 'email-reject': _rejecting }"`, `.dm-{color}`, `{ direction:
    # 'back' }` — and today they happen to balance at 9 open against 9 close,
    # so the naive count landed on the right answer by luck. One unmatched
    # brace in a future comment (this file's style already DISCUSSES `@layer`
    # in prose) flips this to a verdict about punctuation wearing the words
    # "nested N levels deep", which is the same species of lie the whole PR
    # exists to correct.
    before = css[0...css.index(rule)].gsub(%r{/\*.*?\*/}m, "")
    depth  = before.count("{") - before.count("}")
    assert_equal 0, depth,
      "the override must sit OUTSIDE any @layer block (found it nested #{depth} " \
      "level(s) deep); a layered rule can be out-ranked by an unlayered one"

    # ...and .free-entry-badge itself must still not declare a display, or it
    # would beat .hidden from the unlayered side and re-open the bug the other
    # way round.
    base = css[/^\.free-entry-badge\s*\{[^}]*\}/]
    assert base, "could not find the .free-entry-badge base rule"
    refute_match(/display:/, base,
      ".free-entry-badge must not set display — unlayered, it would out-rank " \
      ".hidden and pin the badge visible at zero tokens")
  end

  test "the stylesheet ships the glow and both label faces" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_includes css, ".free-entry-glow {"
    assert_includes css, "@keyframes free-entry-glow"
    # The peek FADES rather than pops: it must rest laid-out-but-invisible (a
    # display toggle cannot transition), and visibility carries a delay so it
    # flips only after the fade-out finishes.
    peek = css[css.index(".free-entry-label {"), 1000]
    assert_includes peek, "visibility: hidden"
    assert_includes peek, "visibility 0s linear"
    assert_match(/transition:[^;]*opacity/m, peek)
    assert_includes css, ".fe-peek .free-entry-label {"
    # ...and the ACTIVE face returns to the flow, or the slot collapses.
    active = css[css.index(".free-entry-label.is-active {"), 400]
    assert_includes active, "position: static"
    assert_includes active, "visibility: visible"
    # A space-separated "R G B" var is silently dropped by rgba(var(...), A);
    # the glow must use the modern slash form or it renders no shadow at all.
    glow = css[css.index("@keyframes free-entry-glow"), 400]
    refute_includes glow, "rgba(var(",
      "legacy rgba(var(...), A) drops a space-separated RGB var — use rgb(var(...) / A)"
  end
end
