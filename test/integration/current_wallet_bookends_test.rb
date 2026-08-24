require "test_helper"

# THE BOOKENDS, driven through the real endpoints.
#
# The container is trivial on its own (test/services/solana/current_wallet_test).
# What is worth proving is that the session key is written and cleared at the
# three seams and nowhere else, because the failure modes all live there:
#
#   * set but never cleared  -> an email login inherits the last wallet's brand
#                               and paints a session Phantom-purple with no
#                               wallet behind it.
#   * cleared but never set  -> the feature silently does nothing.
#   * set outside a proven signature -> the app claims a wallet it never verified.
#
# These sign REAL messages rather than poking session[:wallet_brand], so the
# claim is about the endpoint a browser actually reaches.
class CurrentWalletBookendsTest < ActionDispatch::IntegrationTest
  KEY = Solana::CurrentWallet::SESSION_KEY

  def sign_in_wallet(user, provider:)
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
      wallet_provider: provider
    }, as: :json
  end

  test "a proven wallet signature remembers its brand" do
    sign_in_wallet(users(:alex), provider: "Phantom")

    assert_response :success
    assert_equal "phantom", session[KEY],
                 "the brand is stored NORMALISED, whatever spelling the browser sent"
  end

  # A wallet SWITCH re-auths through the same endpoint, which is exactly why the
  # set bookend lives there — the session follows the wallet with no second seam.
  test "switching wallets moves the brand with the session" do
    sign_in_wallet(users(:alex), provider: "phantom")
    assert_equal "phantom", session[KEY]

    sign_in_wallet(users(:sam), provider: "solflare")

    assert_response :success
    assert_equal "solflare", session[KEY], "the session must follow the wallet that just signed"
  end

  test "logout forgets the wallet" do
    sign_in_wallet(users(:alex), provider: "phantom")
    assert_equal "phantom", session[KEY]

    # GET, not DELETE — that is the verb the route declares, and the logout link
    # in the navbar is a plain link. A DELETE here never reaches #destroy, so the
    # test would pass or fail for a reason that has nothing to do with the bookend.
    get logout_path

    assert_redirected_to signin_path
    assert_nil session[KEY]
  end

  # The old brand must not outlive the wallet it belonged to, even when the new
  # wallet's brand is one the registry cannot name.
  #
  # CREDIT WHERE IT IS DUE: this passes because CurrentWallet.remember DELETES
  # the key for an unrecognised brand, not because of the clear in
  # set_app_session. That clear has no biting test — see the comment on it in
  # ApplicationController for the three paths that were built and rejected as
  # witnesses. This asserts the BEHAVIOUR a user experiences, which is the part
  # worth pinning either way.
  test "switching to an unrecognised wallet drops the previous brand" do
    sign_in_wallet(users(:alex), provider: "phantom")
    assert_equal "phantom", session[KEY]

    sign_in_wallet(users(:sam), provider: "metamask")

    assert_response :success
    assert_nil session[KEY],
               "the old brand must not outlive the wallet it belonged to"
  end

  test "a signature from an unrecognised brand remembers nothing" do
    sign_in_wallet(users(:alex), provider: "metamask")

    assert_response :success
    assert_nil session[KEY], "a value that can never match the registry is worse than none"
  end
end
