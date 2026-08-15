require "test_helper"

# [integration] The account shape this config exists for, PERSISTED.
#
# The unit guard beside this (test/initializers/studio_wallet_method_test.rb)
# works on unsaved records, so it proves what the configured method READS. It
# cannot prove the thing that makes the bug real: that an account with no email,
# no password and only a `web3_solana_address` is a LEGAL account here. If it
# were not, the engine refusing it a Google unlink would be correct and there
# would be nothing to fix.
#
# So this drives the model's own validations against the database and then asks
# the engine the same question, which is the seam the bug sat in — this app said
# "wallet is a sign-in method" in one file and never told the engine where to
# look in another.
class WalletOnlyAccountTest < ActionDispatch::IntegrationTest
  SIGNER = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU".freeze
  CUSTODIAL = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze

  # THE PREMISE. User#has_authentication_method permits an account whose only
  # credential is a web3 address. That is what makes the engine's over-refusal a
  # bug rather than a correct guard, so it is asserted rather than assumed —
  # if this app ever tightened that rule, the fix beside it would need revisiting.
  test "an account whose only credential is a signing wallet is valid here" do
    user = User.new(web3_solana_address: SIGNER)

    assert user.valid?, "expected a wallet-only account to be legal; errors: #{user.errors.full_messages}"
  end

  test "the engine sees the signing wallet of a persisted wallet-only account" do
    user = User.create!(web3_solana_address: SIGNER)

    assert_equal SIGNER, user.reload.public_send(Studio.wallet_address_method),
                 "the engine cannot see this account's only way back in, so it will refuse a " \
                 "Google unlink that this app's own validation permits"
  end

  # The other half, and the reason the config does not name :solana_address: a
  # CUSTODIAL-only account genuinely has no way to sign, so the engine must go on
  # seeing nothing for it. An unlink for this account really would orphan it.
  test "the engine sees no signing wallet on a custodial-only account" do
    user = User.create!(email: "custodial@example.com", web2_solana_address: CUSTODIAL)

    assert_nil user.reload.public_send(Studio.wallet_address_method),
               "a custodial address counted as a sign-in method permits an unlink that locks " \
               "the owner out — this account's only real credential is its email"
  end
end
