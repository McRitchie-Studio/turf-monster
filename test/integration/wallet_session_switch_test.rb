require "test_helper"

# The rendered wallet-change card and the server boundary its CTA reaches.
class WalletSessionSwitchTest < ActionDispatch::IntegrationTest
  test "a web3 page identifies the wallet provider that authenticated the session" do
    user = users(:alex)
    user.update!(web3_wallet_provider: "phantom")
    log_in_as_onchain(user)

    get tokens_buy_path

    assert_response :success
    assert_select "body[data-wallet-provider='phantom']", 1
  end

  test "the wallet-change card explains the handoff and offers one session action" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "wallet-changed", props: {}.to_json)
    assert_response :success

    card = Nokogiri::HTML(response.body).css("template").find { |node|
      node["x-if"].to_s.include?("=== 'wallet-changed'")
    }
    assert card, "wallet-changed modal is not registered in the application layout"

    html = card.to_html
    assert_includes html, "It looks like you changed your wallet."
    assert_includes html, "Start New Session"
    assert_includes html, "continueSwitch()"
    assert_not_includes html, "Not now"
  end

  test "a selected wallet signature replaces the authenticated user session" do
    original = users(:alex)
    replacement = users(:sam)
    log_in_as_onchain(original)
    assert_equal original.id, session[:turf_user_id]

    replacement_key = Ed25519::SigningKey.generate
    replacement_address = Solana::Keypair.encode_base58(replacement_key.verify_key.to_bytes)
    replacement.update!(web3_solana_address: replacement_address)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body).fetch("nonce")
    message = "www.example.com wants you to sign in with your Solana account:\n" \
              "#{replacement_address}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"
    signature = Solana::Keypair.encode_base58(replacement_key.sign(message))

    post "/auth/solana/verify", params: {
      message: message,
      signature: signature,
      pubkey: replacement_address,
      wallet_provider: "phantom"
    }, as: :json

    assert_response :success
    assert JSON.parse(response.body).fetch("success")
    assert_equal replacement.id, session[:turf_user_id]
    assert_equal true, session[:onchain]
    assert_equal "phantom", replacement.reload.web3_wallet_provider
  end
end
