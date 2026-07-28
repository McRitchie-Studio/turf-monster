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

  # The default guards the three PayPal/modal call sites that never pass a
  # provider — they must keep rendering the Stripe form exactly as before.
  test "provider defaults to stripe when the caller omits it" do
    html = render_pack("single")
    assert_includes html, "stripe_checkout"
    assert_includes html, "provider-badge-stripe"
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
end
