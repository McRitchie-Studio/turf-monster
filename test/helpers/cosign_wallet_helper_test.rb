require "test_helper"

# [unit] CosignWalletHelper — a co-sign picker names whose wallet each option
# is, so an agent key can never pass for one of Mr. McRitchie's.
class CosignWalletHelperTest < ActionView::TestCase
  test "his wallet is labelled with its roster name" do
    assert_equal "3Qj4…ZboA · Alex, second wallet",
                 cosign_wallet_option_label("3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA")
  end

  test "an agent key is marked as an agent key, break-glass" do
    assert_equal "3LTL…epJ9 · Governance key v2 (agent key, break-glass)",
                 cosign_wallet_option_label("3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9")
  end

  test "a key the roster does not know says so" do
    address = Solana::Keypair.generate.address
    assert_match(/ · Unknown key\z/, cosign_wallet_option_label(address))
  end
end
