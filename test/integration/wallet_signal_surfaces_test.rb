require "test_helper"

# Where the wallet signal actually lands, and what the server binds under it.
#
# ── WHY THE THREE ADMIN PAGES ARE NAMED ONE BY ONE ────────────────────────
#
# A cosign ceremony walks the operator through the vault's signers on purpose,
# so all three of these pages suppress the non-dismissible wallet-changed card.
# The suppression is correct and must stay. What it left behind was silence: the
# page could not say which account Phantom was on, mid-ceremony or after an
# accidental switch.
#
# Only TWO of the three are obvious. /admin/pending_transactions and
# /admin/vault_state each carry their own cosign script; /admin/authorities
# reaches the same suppression through the GLOBAL cosignTransaction that its
# eviction console's button calls, and nothing on that page says so. A signal
# built for the two obvious ones would leave the console that rewrites the
# vault's signer set bare — the page where signing from the wrong account costs
# the most. So the third is asserted by name, not by a loop over a list someone
# would have to remember to widen.
class WalletSignalSurfacesTest < ActionDispatch::IntegrationTest
  CEREMONY_PATHS = {
    "/admin/pending_transactions" => "the treasury cosign queue",
    "/admin/vault_state" => "the vault unpause flow",
    "/admin/authorities" => "the eviction console, which reaches the suppression through cosignTransaction"
  }.freeze

  def signal_nodes(variant: nil)
    selector = "[data-wallet-signal]"
    selector += "[data-wallet-signal-variant=#{variant}]" if variant
    css_select(selector)
  end

  CEREMONY_PATHS.each do |path, what|
    test "#{path} carries a page-level wallet signal" do
      log_in_as_onchain(users(:alex))

      get path
      assert_response :success

      panels = signal_nodes(variant: "panel")
      assert_equal 1, panels.length,
                   "#{what} suppresses the wallet-changed card and must say what is live instead; " \
                   "found #{panels.length} panels"

      # The state is on the element, so an operator and a browser test read the
      # same answer.
      assert panels.first[":data-wallet-signal-state"].to_s.include?("walletSignal"),
             "#{path} renders a signal that never publishes its state"
    end
  end

  test "the navbar carries the signal on an ordinary page, signed in" do
    log_in_as_onchain(users(:alex))

    get contests_path
    assert_response :success

    chips = signal_nodes(variant: "chip")
    refute_empty chips, "the navbar is the one piece of chrome every page gets, and it has no wallet signal"
  end

  # THE PRE-AUTH STATE, which is the requirement most easily lost. The ask was
  # for the context to EXIST before anyone signs in — the navbar needs it on
  # every page — not for the UI to be absent when signed out.
  test "the navbar carries the signal signed OUT, and the store resolves without a session" do
    get contests_path
    assert_response :success

    chips = signal_nodes(variant: "chip")
    refute_empty chips, "a signed-out page must still mount the wallet signal"

    # It is hidden until it has something to say, but MOUNTED — x-show, never
    # absent, so the state resolves and is readable either way.
    assert chips.first["x-show"].to_s.include?("walletSignal")
  end

  test "the layout ships the identity source the signal is built on" do
    get contests_path
    assert_response :success

    assert_match %r{solana_studio/wallet_identity[^"]*\.js}, response.body,
                 "solana-studio's wallet identity source is not on the page; the signal has nothing to read. " \
                 "A gem asset missing from config.assets.precompile 404s in production with no local warning."

    assert_match %r{studio/session[^"]*\.js}, response.body,
                 "studio-engine's session store is not on the page; there is nothing to register a source with"
  end

  # ── The server half ─────────────────────────────────────────────────────

  def stamp
    tag = css_select('meta[name="studio-session"]').first
    refute_nil tag, "no studio-session stamp on the page"
    JSON.parse(tag["content"])
  end

  test "a live-signature session binds its wallet into the session stamp" do
    key = log_in_as_onchain(users(:alex))
    address = users(:alex).reload.web3_solana_address
    refute_nil key

    get contests_path
    assert_response :success

    # The key must be exactly "wallet": the engine matches an identity source by
    # NAME, and solana-studio's source registers as "wallet".
    assert_equal({ "wallet" => address }, stamp["identities"],
                 "the session stamp does not name the wallet this session signed in with")

    # And it must be the same address the body tag carries, because that is what
    # the browser compares against. Two answers to "which wallet signed in" is
    # the disagreement this whole change exists to end.
    assert_select "body[data-wallet-address=?]", address
  end

  test "a signed-out visitor binds nothing, and that is a state rather than an error" do
    get contests_path
    assert_response :success

    assert_equal({}, stamp["identities"],
                 "a visitor who never claimed a wallet must not be bound to one")
    assert_equal "anonymous", stamp["state"]
  end

  test "an email session binds no wallet, so a browser wallet can never mismatch it" do
    user = users(:alex)
    log_in_as(user)

    get contests_path
    assert_response :success

    # The account may well HAVE a wallet address; this session did not
    # authenticate with one, so nothing in the browser is accountable to it. An
    # unbound source still reports what it sees and never raises a mismatch.
    assert_equal({}, stamp["identities"],
                 "a managed/email session must not be warned about a wallet it never signed in with")
  end

  test "re-binding the session to another wallet changes the fingerprint" do
    log_in_as_onchain(users(:alex))
    get contests_path
    first = stamp["fingerprint"]

    log_in_as_onchain(users(:alex))
    get contests_path
    second = stamp["fingerprint"]

    refute_equal first, second,
                 "the bound wallet is in the fingerprint, so another tab can learn the session moved"
  end
end
