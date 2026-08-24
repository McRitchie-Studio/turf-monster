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
    assert_includes html, "Start New Session"
    assert_includes html, "continueSwitch()"
    assert_not_includes html, "Not now"

    # THE TWO ADDRESSES ARE THE MESSAGE, and they must be READABLE as a pair —
    # labelled rows, not a base58 string buried mid-sentence. Assert the labels
    # and both bindings, because a card that renders one address twice looks
    # entirely correct until you are the user staring at it.
    assert_includes html, ">Session<"
    assert_includes html, ">Wallet<"
    assert_includes html, "short(props.oldAddress)"
    assert_includes html, "short(props.newAddress)"

    # The subtitle restated the title; keeping both pushed the addresses down.
    assert_not_includes html, "It looks like you changed your wallet."

    # The card renders the CARD, not the source notes ABOUT the card. An ERB
    # comment that quotes ERB terminates on it and leaks the remaining prose into
    # the page as visible text — shipped and screenshotted 2026-08-24. The source
    # rule is guarded in test/lib/erb_comment_percent_test.rb; this is the same
    # claim asserted on what the user actually sees.
    assert_not_includes html, "block_given"
    assert_not_includes html, "LOAD-BEARING"

    # The escape hatch is the only way out of a card that cannot be dismissed,
    # so it belongs UNDER the action it is the alternative to. Position is the
    # claim here — "somewhere on the card" was already true before.
    assert_operator html.index("Start New Session"), :<, html.index("To keep this session"),
                    "the way out must sit below the primary action, not above the addresses"
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
