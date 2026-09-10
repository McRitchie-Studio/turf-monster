require "test_helper"

# A wallet LINK is a wallet SIGNATURE, so it must promote the session exactly as
# a wallet LOGIN does.
#
# THE BUG THIS PINS (prod, 2026-09-06). An account created by Google sign-in
# linked Phantom from the wallet-setup modal — POST /account/link_solana. That
# path wrote every DURABLE fact (web3_solana_address, web3_wallet_provider) and
# none of the SESSION facts, so onchain_session? stayed false and SessionContext
# rendered mode :web2 for a user who had just proved a wallet.
#
# For an account whose ONLY wallet is self-custody that is not a downgrade, it is
# a DEAD END: web2 entry server-signs from #web2_solana_address, which the
# account does not have. The board therefore offered "Buy an Entry Token" to a
# user holding more than the entry fee in USDC, and no amount of topping up
# could ever clear it.
#
# The assertions below are deliberately on the RENDERED mode rather than on the
# session key alone — mode is what the whole UI branches on, and it is what the
# operator actually saw go wrong.
class WalletLinkPromotesSessionTest < ActionDispatch::IntegrationTest
  # Sign a User-ID-bound link message (OPSEC-005) for `user` and POST it.
  # Returns the wallet address that signed.
  def link_wallet_as(user, key: Ed25519::SigningKey.generate, wallet_provider: "phantom")
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    message = <<~MSG.strip
      www.example.com wants you to sign in with your Solana account:
      #{pubkey_b58}

      Sign in to Turf Monster (User-ID: #{user.id})

      Nonce: #{nonce}
    MSG

    post link_solana_account_path,
         params: {
           message: message,
           signature: Solana::Keypair.encode_base58(key.sign(message)),
           pubkey: pubkey_b58,
           wallet_provider: wallet_provider
         },
         as: :json

    pubkey_b58
  end

  def rendered_session_context
    get tokens_buy_path
    assert_response :success
    JSON.parse(Nokogiri::HTML(response.body).at_css("#session-context").text)
  end

  test "linking a wallet turns a web2 session into a web3 one" do
    user = users(:jordan)
    assert_nil user.web3_solana_address, "precondition: no wallet yet — the Google-signup shape"
    assert_nil user.web2_solana_address,
               "precondition: no MANAGED wallet either, so a web2 session cannot fund an entry at all"

    log_in_as user # magic link — a signature-free session, exactly like Google

    assert_equal "web2", rendered_session_context["mode"],
                 "precondition: an email/Google login is a web2 session"

    address = link_wallet_as(user)
    assert_response :success

    assert_equal address, user.reload.web3_solana_address,
                 "precondition: the link itself landed"

    context = rendered_session_context
    assert_equal "web3", context["mode"],
                 "the session just proved a wallet, so it can sign on-chain NOW — which is " \
                 "SessionContext's definition of web3. Rendering web2 here is what put the " \
                 "web2 'Buy an Entry Token' wall in front of a funded Phantom user."
    assert_equal "phantom", context["walletBrand"],
                 "the brand that signed must ride the session, so a step-up asks the wallet " \
                 "that can actually sign — not whichever one the account column happens to name"
  end

  test "a merge that KEEPS the caller leaves the survivor holding the wallet" do
    absorbed = users(:sam)
    survivor = users(:jordan)
    assert_operator survivor.id, :<, absorbed.id,
                    "precondition: this test only exercises the NO-SWAP ordering while jordan outranks sam"

    # Give the absorbed account an address we hold the key for, so the signature
    # verifies and link_solana takes its MERGE branch (a separate early return,
    # which is exactly how a fix applied to one branch misses the other).
    key = Ed25519::SigningKey.generate
    absorbed.update!(web3_solana_address: Solana::Keypair.encode_base58(key.verify_key.to_bytes))

    log_in_as survivor
    assert_equal "web2", rendered_session_context["mode"], "precondition: web2 before the link"

    address = link_wallet_as(survivor, key: key)
    assert_response :success
    assert_equal "Accounts merged.", JSON.parse(response.body)["notice"],
                 "precondition: this must be the MERGE branch, not the plain link branch"

    # THE ASSERTION THIS TEST EXISTED WITHOUT, and the reason it certified a bug.
    # merge_users! copies only email / name / provider+uid and then DESTROYS the
    # absorbed row — the row that held the wallet. Asserting the session mode
    # alone passes for a survivor holding nothing, which is strictly worse than
    # the bug this PR set out to fix: the account then CLAIMS a wallet it does
    # not have, and a survivor with a managed wallet loses both entry doors.
    # The invariant is "web3 session AND the account holds the wallet", never
    # the flag on its own.
    assert_equal address, survivor.reload.web3_solana_address,
                 "the survivor must actually HOLD the wallet the merge just proved"
    assert_not User.exists?(absorbed.id), "precondition: the absorbed row is gone"

    context = rendered_session_context
    assert_equal "web3", context["mode"],
                 "the merge branch proved the same signature and returns early — it owes the " \
                 "same promotion, or a merging user is stranded in a web2 session"
    assert_equal "phantom", context["walletBrand"]
  end

  test "a merge that DESTROYS the caller still stamps the surviving account" do
    # merge_users! keeps the LOWER id, so signing in as the HIGHER-id account
    # makes current_user the row that gets destroyed. Nothing covered this
    # ordering, and it is where the durable brand stamp was silently dropped:
    # record_web3_authentication! bails on a destroyed object.
    caller_user = users(:sam)
    keeper      = users(:jordan)
    assert_operator caller_user.id, :>, keeper.id,
                    "precondition: this test only exercises the SWAP ordering while sam outranks jordan"

    key = Ed25519::SigningKey.generate
    address = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    keeper.update!(web3_solana_address: address, web3_wallet_provider: nil, web3_authenticated_at: nil)
    caller_user.update!(web3_solana_address: nil)

    log_in_as caller_user
    link_wallet_as(caller_user, key: key)
    assert_response :success
    assert_equal "Accounts merged.", JSON.parse(response.body)["notice"]

    assert_not User.exists?(caller_user.id), "precondition: the caller's row is the one destroyed here"
    keeper.reload
    assert_equal address, keeper.web3_solana_address, "the keeper must still hold its wallet"
    assert_equal "phantom", keeper.web3_wallet_provider,
                 "the DURABLE brand stamp must land on the survivor — writing it through " \
                 "current_user no-ops here, because that object was just destroyed"
    assert_not_nil keeper.web3_authenticated_at

    context = rendered_session_context
    assert_equal "web3", context["mode"]
    assert_equal keeper.id, context["userId"], "the session must follow the row that survived"
  end
end
