require "test_helper"

# Solana::WalletProvider — the one list of self-custody wallet brands.
#
# The whole reason this registry exists is that a brand name is now PERSISTED
# (users.web3_wallet_provider), and a persisted name that does not round-trip is
# a value that can never match again. So every test here is really one question:
# does what we store come back?
class Solana::WalletProviderTest < ActiveSupport::TestCase
  test "normalize accepts the brands the picker offers, in the picker's casing" do
    # These three strings are what the browser actually sends: the connect modal
    # reads them off the Wallet Standard registration, which uses display casing.
    assert_equal "phantom",  Solana::WalletProvider.normalize("Phantom")
    assert_equal "solflare", Solana::WalletProvider.normalize("Solflare")
    assert_equal "backpack", Solana::WalletProvider.normalize("Backpack")
  end

  test "normalize is tolerant of casing and stray whitespace" do
    assert_equal "phantom", Solana::WalletProvider.normalize("phantom")
    assert_equal "phantom", Solana::WalletProvider.normalize("PHANTOM")
    assert_equal "phantom", Solana::WalletProvider.normalize("  Phantom  ")
  end

  test "an unknown brand normalizes to nil rather than storing junk" do
    # An unknown wallet is not an error — it is a user on a brand we have no
    # artwork for. nil is what makes the step-up modal fall back to the picker,
    # so this IS the fallback path, not a failure path.
    assert_nil Solana::WalletProvider.normalize("MetaMask")
    assert_nil Solana::WalletProvider.normalize("")
    assert_nil Solana::WalletProvider.normalize(nil)
  end

  test "the test-only keypair provider is not a brand" do
    # wallet_provider.js exposes a KeypairProvider named 'keypair' for Playwright
    # and bot agents. It signs real signatures, so it reaches the same stamp path
    # a human does — and must leave no brand behind, or e2e runs would teach the
    # modal to offer users a wallet that does not exist.
    assert_nil Solana::WalletProvider.normalize("keypair")
  end

  test "every registered brand round-trips through normalize" do
    # The property that matters: nothing in the registry can be a value the
    # registry itself rejects.
    Solana::WalletProvider::REGISTRY.each do |wallet|
      assert_equal wallet[:key], Solana::WalletProvider.normalize(wallet[:key]),
                   "#{wallet[:key]} does not survive its own normalizer"
      assert_equal wallet[:key], Solana::WalletProvider.normalize(wallet[:label]),
                   "#{wallet[:label]} (the label the browser sends) does not normalize to its key"
    end
  end

  test "label and install_url resolve for known brands and nil otherwise" do
    assert_equal "Phantom", Solana::WalletProvider.label("phantom")
    assert_equal "Solflare", Solana::WalletProvider.label("SOLFLARE")
    assert_nil Solana::WalletProvider.label("metamask")
    assert_match %r{\Ahttps://}, Solana::WalletProvider.install_url("backpack")
    assert_nil Solana::WalletProvider.install_url(nil)
  end

  test "the keys match the engine wallet-sprite symbol suffixes" do
    # The step-up modal paints its brand icon with <use href="#se-wallet-<key>">,
    # and studio-engine's _wallet_brand_sprite defines exactly these three
    # symbols. A key added here without artwork paints an empty box, which no
    # markup assertion elsewhere would catch.
    sprite = Rails.root.join("../../../studio-engine/app/views/studio/modals/blocks/_wallet_brand_sprite.html.erb")
    skip "engine checkout not present" unless sprite.exist?

    source = sprite.read
    Solana::WalletProvider::KEYS.each do |key|
      assert_includes source, %(id="se-wallet-#{key}"),
                      "no engine sprite symbol for #{key} — its icon would render empty"
    end
  end
end
