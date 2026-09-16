require "test_helper"

# [component] The account card tells the reader when the connected wallet is not
# the wallet this session signed in with.
#
# WHAT THIS PINS AND WHY IT WAS MISSING. $store.wallet has resolved a
# 'mismatched' state since the live-signer work landed, and until now exactly
# ONE thing in the entire UI bound to it: the grey check above the address
# (measured — `grep -rn '$store.wallet.state' app/views app/javascript` returned
# that one binding and two comments). Everything else on this card went on
# presenting the session wallet's address and the session wallet's balances at
# full confidence while the browser held a different account. That is the
# disagreement that strands value: a reader cannot tell, from a confident
# address over a confident $40, that neither belongs to the wallet Phantom is
# now offering.
#
# THE MARKUP SHAPE IS THE ASSERTION, not merely the presence of a class.
#   * MOUNTED AND EMPTY. x-show, never `template x-if` — a status region
#     inserted alongside its own content is not reliably announced, because
#     assistive tech has to be observing the region before the text lands in it.
#     Same rule, same reason as test/views/error_live_regions_test.rb.
#   * THE WORDS CARRY IT, not the dim. Dimming the balance tiles is invisible to
#     a screen reader and means nothing on its own, so the notice must state the
#     fact in text and the tiles must never be the only signal.
#
# WHAT THIS TIER CANNOT PROVE: that the state actually flips at runtime. The
# four-cell matrix in e2e/wallet_session_switch.spec.js proves that end, across
# both provider interfaces and both arrival paths.
class WalletMismatchNoticeTest < ActionView::TestCase
  # Renders the real partial. entry_token_balance is stubbed because it is
  # Rails.cache-backed with a Solana::Vault call on a MISS — a chain round-trip
  # has no business in a markup assertion.
  def render_section(user)
    user.define_singleton_method(:entry_token_balance) { 0 }
    render partial: "accounts/solana_wallet_section", locals: { user: user }
  end

  # ActionView::TestCase#rendered ACCUMULATES across renders in one test, so an
  # absence read off it would pass vacuously against the union of every render
  # in the file. Always assert on the return value.
  def fragment(html) = Nokogiri::HTML5.fragment(html)

  def phantom_user = users(:sam)

  test "the notice is mounted and empty rather than inserted when the error occurs" do
    node = fragment(render_section(phantom_user)).css("[data-wallet-mismatch-notice]").first

    assert node, "the mismatch notice must render for a Phantom account"
    assert_equal "status", node["role"]
    assert_equal "polite", node["aria-live"]
    assert node.key?("x-show"),
      "visibility must move, not existence — x-show keeps the region observable before it fills"
    assert_includes node["x-show"], "mismatched"
    assert node.key?("x-cloak"),
      "without x-cloak the notice paints for everyone until Alpine initialises"
  end

  # THE WORDS. A reader who cannot see a 50% opacity change still has to learn
  # that the balances below are not the connected wallet's.
  test "the notice says in text that the connected wallet differs" do
    node = fragment(render_section(phantom_user)).css("[data-wallet-mismatch-notice]").first

    # Squished: the copy is line-wrapped in the ERB, so a raw match would pin
    # the wrapping rather than the sentence.
    text = node.text.gsub(/\s+/, " ").strip

    assert_match(/different wallet is connected/i, text)
    assert_match(/balances below are not that account's/i, text)
    assert_equal 1, node.css("[data-live-wallet-address]").length,
      "the notice must name the wallet that is actually connected, not just that one is"
  end

  # THE TILES FOLLOW THE SAME FACT — and are never the only carrier of it.
  test "the balance tiles dim on the same condition the notice shows on" do
    html = render_section(phantom_user)
    tiles  = fragment(html).css("[data-wallet-tiles]").first
    notice = fragment(html).css("[data-wallet-mismatch-notice]").first

    assert tiles, "the tiles grid must be addressable"
    binding = tiles[":class"] || tiles["x-bind:class"]
    assert binding, "the tiles must bind their dim to the store, not paint it server-side"
    assert_includes binding, "mismatched"
    assert_includes notice["x-show"], "mismatched",
      "tiles and notice must key on ONE fact — two conditions drift and the dim outlives the words"
  end

  # The session's own address stays server-rendered. Pre-auth the new wallet is
  # NOT this account's identity, and repainting the address as though it were
  # would assert an identity the server has not authenticated.
  test "the session address is still rendered server-side" do
    node = fragment(render_section(phantom_user)).css("[data-session-wallet-address]").first

    assert node
    assert_equal phantom_user.solana_address, node.text.strip
  end

  # THE CONTROL. A managed (custodial) account has no browser signer and cannot
  # mismatch — the server holds its key, so there is no wallet for Phantom to
  # switch away from. Without this, every assertion above would pass for a
  # notice rendered unconditionally on every account in the app.
  #
  # BUILT INLINE, NOT FIXTURED. This suite has no managed-only user: jordan and
  # alex carry no wallet at all (so they render the CONNECT branch and would
  # pass this for the wrong reason — no notice because no card), while sam and
  # casey both resolve :phantom. Adding a fixture to close that gap would rewrite
  # every sibling test that counts users, so the control is constructed here. It
  # is never saved; the partial only reads.
  test "a managed-wallet account renders the card but no mismatch notice" do
    managed = User.new(name: "Managed", username: "managed_test",
                       email: "managed@mcritchie.studio",
                       web2_solana_address: "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin")
    assert_equal :managed, managed.wallet_kind, "the control must actually be custodial"

    html = render_section(managed)

    assert_equal 1, fragment(html).css("[data-wallet-tiles]").length,
      "the card itself must still render — otherwise the absence below proves nothing"
    assert_empty fragment(html).css("[data-wallet-mismatch-notice]"),
      "a custodial account has no browser signer, so it can never be mismatched"
  end
end
