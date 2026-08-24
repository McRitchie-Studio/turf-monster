require "test_helper"

# Unit — the per-session "which wallet is signed in right now" container.
#
# The distinction it exists to hold: User#web3_wallet_provider is DURABLE (which
# brand an account last authenticated with, kept across logout so a returning
# user is offered the right wallet); this is the narrower per-session fact. A
# test that blurs them would let a logged-out browser keep claiming a wallet.
class Solana::CurrentWalletTest < ActiveSupport::TestCase
  KEY = Solana::CurrentWallet::SESSION_KEY

  test "a remembered brand reads back with its own avatar and colour" do
    wallet = Solana::CurrentWallet.from_session({ KEY => "phantom" })

    assert_predicate wallet, :known?
    assert_equal "phantom", wallet.key
    assert_equal "Phantom", wallet.label
    assert_equal "se-wallet-phantom", wallet.avatar
    assert_equal "#AB9FF2", wallet.colour
  end

  test "an empty session still paints — the default, never nil" do
    wallet = Solana::CurrentWallet.from_session({})

    assert_not wallet.known?, "no wallet is signed in, so nothing may be NAMED"
    assert_nil wallet.key
    assert_equal "Wallet", wallet.label
    assert_equal Solana::WalletProvider::DEFAULT_SPRITE, wallet.avatar,
                 "an avatar is always safe to render; that is the point of the default"
    assert_equal Solana::WalletProvider::DEFAULT[:colour], wallet.colour
  end

  test "a nil session is as safe as an empty one" do
    assert_not Solana::CurrentWallet.from_session(nil).known?
  end

  # A stored value that no longer matches the registry — a brand retired between
  # the signature and this request. It must degrade to the default, not raise and
  # not keep naming a wallet the app no longer knows.
  test "a brand the registry has since forgotten degrades to the default" do
    wallet = Solana::CurrentWallet.from_session({ KEY => "metamask" })

    assert_not wallet.known?
    assert_equal Solana::WalletProvider::DEFAULT_SPRITE, wallet.avatar
  end

  # --- the bookend primitives ------------------------------------------------

  test "remember stores the NORMALISED key, whatever spelling the browser sent" do
    session = {}

    assert_equal "phantom", Solana::CurrentWallet.remember(session, " Phantom ")
    assert_equal "phantom", session[KEY],
                 "one canonical value, or a later lookup can never match what was stored"
  end

  test "remembering an unrecognised brand stores NOTHING" do
    session = { KEY => "phantom" }

    assert_nil Solana::CurrentWallet.remember(session, "metamask")
    assert_not session.key?(KEY),
               "a value that can never match is worse than none — it would paint a wallet we cannot name"
  end

  test "forget clears the session key" do
    session = { KEY => "phantom" }
    Solana::CurrentWallet.forget(session)

    assert_not session.key?(KEY)
    assert_not Solana::CurrentWallet.from_session(session).known?
  end

  test "to_h carries everything a surface needs in one read" do
    assert_equal({ key: "solflare", label: "Solflare",
                   avatar: "se-wallet-solflare", colour: "#FFEE00", known: true },
                 Solana::CurrentWallet.new("solflare").to_h)
  end
end
