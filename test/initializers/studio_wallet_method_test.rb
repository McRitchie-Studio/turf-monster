require "test_helper"

# Regression guard for `config.wallet_address_method` in
# config/initializers/studio.rb.
#
# THE BUG. This app declares `config.auth_methods = %i[magic_link google wallet]`
# but never told the engine WHICH column a wallet signs in with. The engine
# refuses to guess, deliberately: `Studio::OauthIdentity.wallet_present?` returns
# false unless the column is named explicitly.
#
# What that costs here is an over-refusal, not a lockout. An account with no
# email, a real `web3_solana_address` and Google linked reports NO remaining
# sign-in method, so unlinking Google is refused as account-orphaning — while
# this app's own `has_authentication_method` validation (app/models/user.rb)
# explicitly permits exactly that account shape. The wallet IS a way back in;
# the engine simply had not been told where to look.
#
# WHY THE ENGINE REFUSES TO GUESS, which is the whole reason this file exists.
# The obvious guess is `:solana_address`, and it is WRONG here. This app's
# `User#solana_address` reads `web3_solana_address || web2_solana_address`, and
# only the web3 one has a signer — the web2 address is CUSTODIAL, held by the
# platform, and nobody can sign a wallet challenge with it. Guessing
# `:solana_address` would count a custodial address as a way back into the
# account and permit an unlink that orphans it. That is a lockout, and it is
# strictly worse than the over-refusal above.
#
# So these tests assert the PROPERTY, not the spelling: whatever method is
# configured must report an address only for someone who can actually sign with
# it. `assert_equal :web3_solana_address, Studio.wallet_address_method` would
# pass just as happily on a future rename that quietly reintroduced the
# custodial fallback.
class StudioWalletMethodTest < ActiveSupport::TestCase
  SIGNER = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU".freeze
  CUSTODIAL = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze

  test "the engine is told which column signs in" do
    assert Studio.wallet_address_method.present?,
           "config.wallet_address_method is unset, so Studio::OauthIdentity.wallet_present? is " \
           "always false and a wallet-only account is refused a Google unlink it is entitled to"
  end

  # THE ONE THAT BITES. Point this config at :solana_address — the obvious,
  # wrong guess — and this test fails, because that reader falls through to the
  # custodial address.
  test "the configured method reports nothing for a custodial-only account" do
    custodial_only = User.new(web2_solana_address: CUSTODIAL, web3_solana_address: nil)

    assert_nil custodial_only.public_send(Studio.wallet_address_method),
               "the configured method reported a CUSTODIAL address as a wallet. Nobody can sign " \
               "a wallet challenge with it, so counting it as a sign-in method permits an unlink " \
               "that locks the owner out of their own account."

    # The trap, stated as a fact rather than as a warning: this is what the
    # obvious guess would have returned for the same account.
    assert_equal CUSTODIAL, custodial_only.solana_address,
                 "User#solana_address falls through to the custodial address — which is exactly " \
                 "why :solana_address is not a safe value for this config"
  end

  test "the configured method reports the signing address for a wallet account" do
    signer = User.new(web3_solana_address: SIGNER)

    assert_equal SIGNER, signer.public_send(Studio.wallet_address_method),
                 "a wallet-only account must report its signing address, or the engine still " \
                 "sees no remaining sign-in method"
  end

  # An account holding BOTH must report the one that can sign. Worth its own test
  # because it is the shape a custodial user is in AFTER they connect a real
  # wallet, and a config that returned the custodial address here would be wrong
  # in a way the two tests above cannot see.
  test "an account with both addresses reports the signing one" do
    both = User.new(web2_solana_address: CUSTODIAL, web3_solana_address: SIGNER)

    assert_equal SIGNER, both.public_send(Studio.wallet_address_method)
  end

  # Studio.user_wallet_address tries [wallet_address_method, :wallet_address,
  # :solana_address] in order, so naming a column PROMOTES it above the two
  # fallbacks for every reader of that helper — SessionContext and the SSO
  # handoff both use it. Asserted rather than assumed: `wallet_address` is a
  # column on this app's PAYMENT tables only and User does not answer it, and a
  # blank web3 address falls through to :solana_address exactly as before. So
  # this config changes what wallet_present? decides and nothing else.
  test "naming the column does not change what the wallet helper resolves to" do
    refute User.new.respond_to?(:wallet_address),
           "User now answers :wallet_address, which sits between the configured method and " \
           ":solana_address in Studio.user_wallet_address — re-check that precedence"

    custodial_only = User.new(web2_solana_address: CUSTODIAL, web3_solana_address: nil)
    assert_equal CUSTODIAL, Studio.user_wallet_address(custodial_only),
                 "a custodial-only account must still resolve to its address for display and SSO; " \
                 "only the SIGN-IN question changed"
  end
end
