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

  # THE SERVER HALF OF THE SINGLE-VISIBLE-TAB RULE.
  #
  # solana_stores.js:253 lets only the VISIBLE tab re-auth, and that guard is
  # not politeness — the session has ONE nonce slot and it is deleted before
  # verify (OPSEC-018). Two tabs racing a re-auth overwrite each other's nonce,
  # so the prompt the user actually signs verifies against a dead one and 401s.
  #
  # The wallet-session refactor moved the code that calls this boundary, so the
  # boundary itself is pinned here: a nonce is spent EXACTLY ONCE. If this goes
  # green with the delete removed, the client guard is the only thing standing
  # between a multi-tab user and a signature they cannot spend.
  test "a nonce is spent exactly once, so a second tab's replay is refused" do
    user = users(:alex)
    key = Ed25519::SigningKey.generate
    address = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update!(web3_solana_address: address)
    log_in_as_onchain(user)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body).fetch("nonce")
    message = "www.example.com wants you to sign in with your Solana account:\n" \
              "#{address}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"
    signature = Solana::Keypair.encode_base58(key.sign(message))
    payload = { message: message, signature: signature, pubkey: address, wallet_provider: "phantom" }

    post "/auth/solana/verify", params: payload, as: :json
    assert_response :success
    assert JSON.parse(response.body).fetch("success"), "the first verify must succeed"

    # Same signed message, replayed — this is the second tab.
    post "/auth/solana/verify", params: payload, as: :json
    refute JSON.parse(response.body)["success"],
           "a nonce must not verify twice. Delete-before-verify is what makes the " \
           "client's single-visible-tab guard necessary AND sufficient; without it a " \
           "captured message replays."
  end

  # WHICH BRAND THE CLIENT RESOLVES AN ADAPTER FOR.
  #
  # Two facts answer this: session[:wallet_brand] (what signed into THIS
  # session, via Solana::CurrentWallet) and User#web3_wallet_provider (what the
  # ACCOUNT uses). Until 2026-08-25 the watcher's only source was
  # `data-wallet-provider` on <body>, which renders the COLUMN.
  #
  # SETUP NOTE, learned the hard way: log_in_as_onchain REWRITES the user's
  # web3_solana_address with a key of its own (test_helper.rb:258) and hands
  # that key back. A follow-up verify signed with a DIFFERENT key therefore
  # matches no existing row and quietly creates a SECOND user — every assertion
  # then describes a stray record rather than this one. Reuse the returned key.
  test "the client payload carries the brand that signed into THIS session" do
    user = users(:alex)
    key = log_in_as_onchain(user)
    address = user.reload.web3_solana_address

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body).fetch("nonce")
    message = "www.example.com wants you to sign in with your Solana account:\n" \
              "#{address}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"
    post "/auth/solana/verify", params: {
      message: message,
      signature: Solana::Keypair.encode_base58(key.sign(message)),
      pubkey: address,
      wallet_provider: "phantom"
    }, as: :json
    assert_response :success
    assert JSON.parse(response.body).fetch("success"), "the verify must actually succeed"
    assert_equal user.id, session[:turf_user_id], "the verify must land on THIS user, not a new one"

    get tokens_buy_path
    assert_response :success
    context = JSON.parse(Nokogiri::HTML(response.body).at_css("#session-context").text)
    assert_equal "phantom", context["walletBrand"],
                 "after a wallet login the payload carries the brand that signed"

    # THE HALF THAT ACTUALLY DISTINGUISHES THE TWO FACTS.
    #
    # The assertion above cannot, and that is not a nitpick — #verify calls
    # record_web3_authentication!, which writes the COLUMN too, so after a
    # wallet login the two facts AGREE and a payload reading either one passes.
    # Measured: a version of this test that stopped there went green against a
    # payload mutated to read the column.
    #
    # They diverge on a WEB2 login: no signature was produced, so no wallet
    # signed into this session, while the account's column still names one.
    assert_equal "phantom", user.reload.web3_wallet_provider,
                 "precondition: the DURABLE column now names phantom"

    # LOG OUT FIRST. A magic-link click by the SAME user is a CONTINUATION, not
    # a fresh session: magic_links_controller#reset_prior_session! is reached
    # only when the identity CHANGES, deliberately, so a second click does not
    # cost the visitor their onchain flag, geo override and picks in flight.
    # Measured: without this logout the session stays mode=web3 with
    # wallet_brand=phantom, and the assertion below is asserting nothing.
    get logout_path
    log_in_as user # web2 — no wallet signature at all
    get tokens_buy_path
    assert_response :success
    web2_context = JSON.parse(Nokogiri::HTML(response.body).at_css("#session-context").text)
    assert_predicate web2_context["walletBrand"].to_s, :empty?,
                     "a web2 session signed NO wallet, so it must carry no brand — even though " \
                     "the account column still names one. Reading the column here is exactly " \
                     "the bug: it resolves an adapter for a signer this session does not have."
  end
end
