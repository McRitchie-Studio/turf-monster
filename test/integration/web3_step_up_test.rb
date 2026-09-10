require "test_helper"

# The web3 step-up, end to end across the auth boundary.
#
# What this tier owns — the behaviour the unit tier cannot see, because it only
# exists once a real session has been established:
#   1. a wallet account signing in by MAGIC LINK is armed with the card;
#   2. an ordinary web2 account is not;
#   3. the prompt is ONE-SHOT (it must not re-open on every later page);
#   4. a wallet signature CLEARS it, and stamps which wallet signed;
#   5. the card holds the onboarding chain rather than racing it.
class Web3StepUpTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
    Rails.cache.clear
  end

  teardown do
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
    Rails.cache.clear
  end

  MARKER = 'id="web3-step-up-data"'.freeze

  # The payload the layout handed the driver on this render.
  def rendered_prompt
    json = response.body[/id="web3-step-up-data">\s*(\{.*?\})\s*<\/script>/m, 1]
    json ? JSON.parse(json) : nil
  end

  # A self-custody account that already signs in by email — the exact user the
  # operator hit. `sam` holds a web3 address in the fixtures.
  def wallet_user(provider: "phantom")
    user = users(:sam)
    user.update!(email: "wallet-user@example.com", email_verified_at: Time.current)
    user.update_columns(web3_wallet_provider: provider)
    user
  end

  # --- who gets armed ---------------------------------------------------------

  test "a wallet account signing in by magic link is asked to step up" do
    user = wallet_user
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_response :success

    assert_includes response.body, MARKER,
                    "a self-custody account on a web2 session must be asked to sign"
    assert_equal "phantom", rendered_prompt["provider"]
    assert_equal "Phantom", rendered_prompt["providerLabel"]
  end

  test "the payload carries the wallet hint so the user knows which wallet" do
    user = wallet_user
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    hint = rendered_prompt["walletHint"]
    assert hint.present?
    assert_equal user.web3_solana_address.first(4), hint.split("…").first
    assert_equal user.web3_solana_address.last(4),  hint.split("…").last
  end

  test "an ordinary web2 account is never asked to step up" do
    user = users(:jordan)
    user.update_columns(web3_solana_address: nil,
                        web2_solana_address: "managedaddr1111111111111111111111111111111")
    user.update!(email_verified_at: Time.current)

    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_response :success
    assert_not_includes response.body, MARKER,
                        "a managed-wallet player has no second credential to reach for"
  end

  test "a wallet account with no remembered brand still gets the card" do
    # Every account linked before the provider column existed is in this state,
    # so the card must open on a null provider rather than being skipped.
    user = wallet_user(provider: nil)
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_includes response.body, MARKER
    assert_nil rendered_prompt["provider"]
  end

  # --- one-shot ---------------------------------------------------------------

  test "the prompt does not re-open on the next page" do
    user = wallet_user
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_includes response.body, MARKER

    get root_path
    follow_redirects!
    assert_response :success
    assert_not_includes response.body, MARKER,
                        "the card must be a one-shot — a dismissed card that returns on " \
                        "every page view is a nag, not a prompt"
  end

  # --- the signature clears it ------------------------------------------------

  test "a wallet login clears an armed prompt instead of flashing the card" do
    user = wallet_user
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_includes response.body, MARKER, "armed by the web2 login"

    log_in_as_onchain(user)
    get root_path
    follow_redirects!
    assert_response :success
    assert_not_includes response.body, MARKER,
                        "a wallet signature IS the step-up — the card must not appear after it"
  end

  # --- the brand stamp --------------------------------------------------------

  test "a wallet signature records which wallet signed" do
    user = users(:sam)
    user.update_columns(web3_wallet_provider: nil, web3_authenticated_at: nil)
    key = log_in_as_onchain(user)
    assert key.present?

    sign_in_with_wallet(user, provider: "Solflare")
    user.reload
    assert_equal "solflare", user.web3_wallet_provider,
                 "the brand is normalised on the way in, never stored as the browser sent it"
    assert user.web3_authenticated_at.present?
  end

  test "an unknown brand leaves the column alone but still stamps the time" do
    user = users(:sam)
    user.update_columns(web3_wallet_provider: "phantom", web3_authenticated_at: nil)

    sign_in_with_wallet(user, provider: "keypair")
    user.reload
    assert_equal "phantom", user.web3_wallet_provider,
                 "an unrecognised brand must not clobber a good one"
    assert user.web3_authenticated_at.present?,
           "we still learned WHEN the wallet signed, even without learning its name"
  end

  # --- ordering against the onboarding chain ----------------------------------

  test "the step-up is emitted alongside the chain, and before it in the DOM" do
    # Both cards auto-open on the same render. The driver holds the chain until
    # the step-up reports done; this asserts the SERVER half — that the chain
    # payload is still delivered rather than suppressed, so nothing is lost when
    # the user dismisses.
    #
    # The AGE step is what puts a chain on this user, deliberately. A wallet
    # account cannot owe the wallet step, and it cannot be made to owe the
    # first-name step either: claim_parked_username! runs before the chain is
    # resolved and fills a blank first name in, so a test that blanked the column
    # would be asserting against a state the sign-in path erases on its way past.
    ENV["ENABLE_AGE_GATE"] = "true"
    user = wallet_user
    user.update_columns(age_attested_at: nil)

    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_response :success

    step_up_at = response.body.index(MARKER)
    chain_at   = response.body.index('id="onboarding-chain-data"')
    assert step_up_at, "the step-up payload must be delivered"
    assert chain_at, "the chain the user still owes must not be dropped"
    assert step_up_at < chain_at, "the step-up is asked first"
  ensure
    ENV.delete("ENABLE_AGE_GATE")
  end

  private

  # POST a real signature to /auth/solana/verify with a brand attached, the way
  # the browser now does.
  def sign_in_with_wallet(user, provider:)
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update!(web3_solana_address: pubkey_b58)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]
    message = "#{host}#{" wants you to sign in with your Solana account:\n"}#{pubkey_b58}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"
    signature = Solana::Keypair.encode_base58(key.sign(message))

    post "/auth/solana/verify", params: {
      message: message, signature: signature, pubkey: pubkey_b58, wallet_provider: provider
    }, as: :json
  end

  def host
    "www.example.com"
  end
end
