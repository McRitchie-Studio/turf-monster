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
      log_in_as(@user)
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

  test "the ✨ badge sits between the username and the avatar, not in the balance row" do
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
    end
  end

  test "the badge is a sparkle, not the retired ticket pill" do
    render_navbar(usdc: 12.0, tokens: 2) do |body|
      badge = body[body.index("data-free-entry-badge") - 900, 1200]
      assert_includes badge, "✨"
      refute_includes badge, "🎟️", "the ticket emoji was retired for the sparkle"
      refute_match(/>\s*Entry\s*</, badge, "the 'Entry' pill text was dropped")
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

  test "the stylesheet ships the glow and both label faces" do
    css = Rails.root.join("app/assets/tailwind/application.css").read
    assert_includes css, ".free-entry-glow {"
    assert_includes css, "@keyframes free-entry-glow"
    assert_includes css, ".free-entry-label.is-active { display: inline-flex; }"
    assert_includes css, ".fe-peek .free-entry-label:not(.is-active)"
    # A space-separated "R G B" var is silently dropped by rgba(var(...), A);
    # the glow must use the modern slash form or it renders no shadow at all.
    glow = css[css.index("@keyframes free-entry-glow"), 400]
    refute_includes glow, "rgba(var(",
      "legacy rgba(var(...), A) drops a space-separated RGB var — use rgb(var(...) / A)"
  end
end
