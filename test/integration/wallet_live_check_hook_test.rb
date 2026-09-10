# frozen_string_literal: true

require "test_helper"

# [integration] + [component] The wallet live-check HOOK must reach the page.
#
# WHY THIS EXISTS, and why it was written alongside the disconnect fix rather
# than after it. `app/javascript/solana_stores.js` drives the account page's
# signer indicator entirely through `[data-wallet-live-check]` — that attribute
# is the ONLY contract between the store and the markup. Nothing in the suite
# asserted it, so renaming or dropping it would leave the JS updating an element
# that no longer exists: the check would freeze green forever, claiming a signer
# that is gone, with every JS test still passing.
#
# That is the same failure the disconnect fix addresses from the other end — the
# store reaching for a channel that was not there — so the contract gets pinned
# in the same change.
class WalletLiveCheckHookTest < ActionDispatch::IntegrationTest
  HOOK = "data-wallet-live-check"

  # ANCHORED ON THE ATTRIBUTE BOUNDARY, not a substring. A plain
  # `assert_includes body, HOOK` passes against `data-wallet-live-checkX` — the
  # rename still CONTAINS the old name — so the first version of this test stayed
  # GREEN through a mutation that renamed the hook everywhere. Mutation is the
  # only reason I know that; the assertion looked fine.
  HOOK_ATTR = /data-wallet-live-check(?=[\s>=])/

  def sign_in_wallet(user)
    key = Ed25519::SigningKey.generate
    address = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update!(web3_solana_address: address)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body).fetch("nonce")
    message = "www.example.com wants you to sign in with your Solana account:\n" \
              "#{address}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"

    post "/auth/solana/verify", params: {
      message: message,
      signature: Solana::Keypair.encode_base58(key.sign(message)),
      pubkey: address,
      wallet_provider: "Phantom"
    }, as: :json
    address
  end

  # [integration] Across the request boundary: the hook must be in what the
  # server actually SENDS, not merely in a partial someone could render.
  test "the account page serves the wallet live-check hook" do
    sign_in_wallet(users(:alex))

    get "/account"
    assert_response :success
    assert_match HOOK_ATTR, response.body,
                 "the account page carries no [#{HOOK}] element, so solana_stores.js has " \
                 "nothing to drive — the signer indicator would freeze at whatever it " \
                 "rendered and keep claiming a wallet that may be gone"
  end

  # [component] The rendered partial itself, and the binding that makes the hook
  # MEAN something: the element must key its colour off the store's state. A hook
  # with no binding is an element the JS finds and cannot change.
  test "the rendered wallet section binds the check to the store state" do
    sign_in_wallet(users(:alex))
    get "/account"

    assert_match(/<svg[^>]*data-wallet-live-check(?=[\s>])/m, response.body,
                 "no <svg> carries the hook")

    assert_match(/\$store\.wallet/, response.body,
                 "the page never references \$store.wallet, so the live check cannot react to a " \
                 "disconnect at all")
  end
end
