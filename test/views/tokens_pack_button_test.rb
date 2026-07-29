require "test_helper"

# Component tier for tokens/_pack_button (task: unify-buy-page-payment-cards).
#
# /tokens/buy straddles two axes — how many entry tokens, and which payment rail
# — and this partial is the only place that crossing is expressed. The three
# things a buyer relies on, and which a careless edit silently breaks:
#
#   1. The card ACTS on the right rail. A Coinflow card must call
#      tmCoinflowBuyOne (hosted checkout); a Stripe card must post the Stripe
#      checkout form. Swap those and the buyer pays through the wrong provider.
#   2. The card SAYS which rail it is. The badge is the only on-card tell once
#      both rails render the same orb-glow shape.
#   3. The pack id RIDES THROUGH. TokenPurchaseJob mints pack[:quantity], so a
#      trio card that posts `single` charges $49 and mints 1.
#
# Rendered markup, not a proxy: assert the actual onclick/action strings.
class TokensPackButtonTest < ActionView::TestCase
  # Returns THIS render's markup. ActionView::TestCase#rendered accumulates
  # across calls, so a test that renders both providers would see the union and
  # every refute_includes would pass vacuously — use the render return value.
  def render_pack(pack_id, **locals)
    render partial: "tokens/pack_button",
           locals: { pack_id: pack_id, pack: StripePurchase.pack(pack_id) }.merge(locals)
  end

  # ── Provider routing: the card must act on the rail it advertises ──────────

  test "coinflow card invokes the hosted-checkout JS with its own pack id" do
    html = render_pack("trio", provider: "coinflow")
    assert_includes html, "tmCoinflowBuyOne('trio')",
                    "coinflow card must drive the hosted checkout for ITS pack"
    refute_includes html, "stripe_checkout",
                    "coinflow card must not post the Stripe checkout form"
  end

  test "stripe card posts the Stripe checkout form for its own pack" do
    html = render_pack("trio", provider: "stripe")
    assert_includes html, "pack=trio"
    assert_includes html, "stripe_checkout"
    refute_includes html, "tmCoinflowBuyOne",
                    "stripe card must not drive Coinflow's checkout"
  end

  # A caller that names no rail must claim NO rail. The first cut defaulted to
  # "stripe", which badged the PayPal/Venmo picker "Stripe" on the buy page —
  # a badge that lies about who takes the money is worse than no badge. Assert
  # the ABSENCE of any badge, not that some particular default was chosen.
  test "an unnamed provider renders no badge at all" do
    html = render_pack("single")
    assert_includes html, "stripe_checkout", "routing still defaults to the Stripe form"
    refute_includes html, "provider-badge", "an unnamed rail must not claim one"
  end

  # select_js mode is rail-agnostic on ROUTING, but must still be able to SAY
  # which rail it is. The original branch order (`if select_js` before
  # `elsif provider ==`) made that structurally impossible.
  test "select mode still honours its provider badge" do
    html = render_pack("single", provider: "paypal", select_js: "selectPack('single')")
    assert_includes html, "provider-badge-paypal"
    assert_includes html, "PayPal"
    # ERB escapes the quotes inside the attribute, so match the call, not the
    # literal source spelling.
    assert_match(/x-on:click="selectPack\(&#39;single&#39;\)"/, html,
                 "the caller's click expression still owns routing")
    refute_includes html, "tmCoinflowBuyOne", "select mode must not route through Coinflow"
    refute_includes html, "provider-badge-stripe"
  end

  # ── The badge: the only on-card tell of which rail this is ─────────────────

  test "each provider renders its own badge and glow skin" do
    coinflow = render_pack("single", provider: "coinflow")
    assert_includes coinflow, "provider-badge-coinflow"
    assert_includes coinflow, "Coinflow"
    assert_includes coinflow, "glow-coinflow"
    refute_includes coinflow, "provider-badge-stripe"

    stripe = render_pack("single", provider: "stripe")
    assert_includes stripe, "provider-badge-stripe"
    assert_includes stripe, "Stripe"
    assert_includes stripe, "glow-brand"
    refute_includes stripe, "glow-coinflow"
  end

  # ── Pack economics survive the provider split ─────────────────────────────

  test "both rails price and label the same pack identically" do
    %w[stripe coinflow].each do |provider|
      html = render_pack("trio", provider: provider)
      assert_includes html, "$49",     "#{provider}: trio must show the pack price"
      assert_includes html, "3",       "#{provider}: trio must show its quantity"
      assert_includes html, "Entries", "#{provider}: plural label for a multi-pack"
      assert_includes html, "Save",    "#{provider}: trio carries a savings badge"
    end
  end

  test "a single pack reads as one entry with no savings badge" do
    html = render_pack("single", provider: "coinflow")
    assert_includes html, "Entry"
    assert_includes html, "Single contest entry"
    refute_includes html, "Save ", "a single pack has nothing to save against"
  end

  # Every call site of this partial, asserted where it LANDS rather than in the
  # abstract — the defect was never in the partial's logic, it was that one
  # caller's badge named the wrong company.
  #
  # DISCOVERS its render sites by globbing app/views rather than trusting a
  # hardcoded list. The first cut enumerated four paths and only checked those,
  # which was blind to a render site in a NEW file — precisely the vector that
  # produced the PayPal-badged-Stripe defect. The expectation below is the
  # allow-list; anything found outside it fails, so adding a render site forces
  # a deliberate provider decision here.
  EXPECTED_RENDER_SITES = {
    "app/views/tokens/buy.html.erb"                 => %w[coinflow stripe],
    "app/views/tokens/_paypal_buttons.html.erb"     => %w[paypal],
    "app/views/modals/auth/_tokens.html.erb"        => %w[stripe],
    "app/views/modals/auth/_paypal_tokens.html.erb" => %w[stripe]
  }.freeze

  # Matches any quoting style and both render forms — "tokens/pack_button",
  # 'tokens/pack_button', and partial: "tokens/pack_button".
  RENDER_CALL = /render\s*\(?\s*(?:partial:\s*)?["']tokens\/pack_button["'](.{0,600}?)%>/m

  def discovered_render_sites
    Dir.glob(Rails.root.join("app/views/**/*.erb")).each_with_object({}) do |abs, found|
      rel = Pathname.new(abs).relative_path_from(Rails.root).to_s
      calls = File.read(abs).scan(RENDER_CALL).flatten
      found[rel] = calls if calls.any?
    end
  end

  test "no pack_button render site exists outside the reviewed allow-list" do
    unexpected = discovered_render_sites.keys - EXPECTED_RENDER_SITES.keys
    assert_empty unexpected,
                 "new pack_button render site(s) #{unexpected.inspect} — each card must " \
                 "name the rail that takes the money, or omit provider deliberately. " \
                 "Add them to EXPECTED_RENDER_SITES with their rail."

    missing = EXPECTED_RENDER_SITES.keys - discovered_render_sites.keys
    assert_empty missing, "expected render site(s) vanished: #{missing.inspect}"
  end

  test "each render site of the partial names its own rail" do
    discovered = discovered_render_sites
    EXPECTED_RENDER_SITES.each do |path, expected|
      calls = discovered.fetch(path, [])
      assert_equal expected.length, calls.length,
                   "#{path}: expected #{expected.length} pack_button render(s)"
      calls.each_with_index do |call, i|
        assert_match(/provider:\s*["']#{expected[i]}["']/, call,
                     "#{path} render ##{i + 1} must name the #{expected[i]} rail explicitly")
      end
    end
  end

  # An unknown provider is a developer typo, and silently falling back to Stripe
  # would route a buyer through the wrong rail — fail loudly instead.
  test "an unknown provider raises rather than defaulting to a payment rail" do
    # The KeyError surfaces wrapped in the template error; assert the cause so
    # this stays about the provider lookup, not about which layer re-raised it.
    error = assert_raises(ActionView::Template::Error) do
      render_pack("single", provider: "bogus")
    end
    assert_match(/key not found: "bogus"/, error.message)
  end

  # ── theme legibility ──────────────────────────────────────────────────────
  #
  # The entry count is the most important number on the card, and it sat at
  # 1.10:1 in light theme — invisible — because it was hard-coded text-white on
  # a bg-primary/5 surface that is near-white there. Light is a real user choice
  # (the navbar toggle writes localStorage theme=light), not a hypothetical.
  #
  # Assert the TOKEN, because that is the property that makes it correct in
  # BOTH themes; asserting a literal colour would just re-pin one theme. The
  # painted-pixel ratios are verified separately in a browser, both themes.

  test "the entry numeral and label use theme tokens, never literal white" do
    %w[stripe coinflow].each do |provider|
      html = render_pack("trio", provider: provider)
      column = html[/<div class="w-16 text-center">.*?<\/div>\s*<\/div>/m]
      refute_nil column, "#{provider}: could not find the entry-count column"

      assert_match(/text-heading/, column,
                   "#{provider}: the numeral must use text-heading (var(--color-text))")
      # text-body, not text-secondary — at 10px the label is small text, and
      # text-secondary measured 4.07:1 in light theme, under AA's 4.5:1.
      assert_match(/text-body/, column,
                   "#{provider}: the Entry/Entries label must use text-body")
      refute_match(/text-white/, column,
                   "#{provider}: literal white is invisible on the light-theme card")
    end
  end

  # A disabled card must LOOK disabled. `disabled: true` alone makes it
  # unclickable while rendering identically to a live card, so a buyer sees a
  # full-price pack that silently does nothing.
  #
  # Assert on the OPENING BUTTON TAG, not on the whole document. The first cut
  # matched /disabled="disabled"|disabled/ against the full html, and that bare
  # second alternative matches inside the CLASS NAME `disabled:opacity-50` —
  # which is emitted whether or not the card is disabled. The test passed with
  # `disabled: false` and guarded nothing. The `disabled:` variant classes are
  # always present by design (a CSS variant only fires when the attribute is
  # set), so the attribute is the only thing that discriminates — which makes
  # the negative case below the load-bearing half of this test.
  def button_tag_for(**locals)
    render_pack("single", provider: "stripe", **locals)[/<button[^>]*>/]
  end

  test "a disabled card carries the disabled attribute AND the visual affordance" do
    tag = button_tag_for(disabled: true)
    assert_match(/\sdisabled="disabled"/, tag, "the button must actually be disabled")
    assert_match(/disabled:opacity-50/, tag, "and must visibly read as disabled")
    assert_match(/disabled:cursor-not-allowed/, tag)
  end

  test "an enabled card carries NO disabled attribute" do
    tag = button_tag_for(disabled: false)
    refute_match(/\sdisabled="disabled"/, tag,
                 "a live card must not be marked disabled — this is the assertion the " \
                 "original substring match could not make")
  end
end
