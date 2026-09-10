require "test_helper"

# Wallet auth signup boundary (SolanaSessionsController#verify is
# create-or-login). The legal-age attestation (underwriting compliance) must
# accompany any verify that would CREATE an account; existing wallets are a
# plain login and are unaffected. (The existing-user login path itself is
# exercised constantly via test_helper's log_in_as_onchain.)
class SolanaSessionsControllerTest < ActionDispatch::IntegrationTest
  # These tests exercise the legal-age attestation gate as designed (ON).
  # The flag is parked off by default for the first contest; the off state
  # is covered in age_attestation_flag_test.rb.
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  # Build a fresh keypair + signed SIWS message for a wallet that has NO user
  # row yet — the signup side of verify (log_in_as_onchain covers login).
  def signed_verify_params
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nNonce: #{nonce}"
    sig_b58 = Solana::Keypair.encode_base58(key.sign(message))

    { message: message, signature: sig_b58, pubkey: pubkey_b58 }
  end

  test "verify creates an account for a new wallet WITH the legal-age attestation" do
    params = signed_verify_params
    assert_difference "User.count", 1 do
      post "/auth/solana/verify", params: params.merge(age_attestation: "1"), as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]

    user = User.find_by(web3_solana_address: params[:pubkey])
    assert user.age_attested_at.present?, "wallet signup must stamp the legal-age attestation"
    assert_equal user.id, session[:turf_user_id]
  end

  test "verify REFUSES to create an account for a new wallet without the attestation" do
    params = signed_verify_params
    assert_no_difference "User.count" do
      post "/auth/solana/verify", params: params, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/legal age/i, JSON.parse(response.body)["error"])
    assert_nil session[:turf_user_id], "no session may be established"
  end

  # --- consolidated sign-in (solana:signIn) -----------------------------------
  #
  # With signIn the WALLET composes the message and the client posts the exact
  # bytes it signed, which carry optional SIWS fields our hand-rolled message
  # never had. These prove the endpoint takes that shape end-to-end — the
  # verifier-level version lives in
  # test/services/solana/auth_verifier_siws_format_test.rb.

  # Mirrors what a Wallet Standard wallet emits for our signIn input.
  def wallet_composed_verify_params(statement: "Sign in to Turf Monster")
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = <<~MSG.strip
      #{host} wants you to sign in with your Solana account:
      #{pubkey_b58}

      #{statement}

      URI: https://#{host}
      Version: 1
      Chain ID: solana:mainnet
      Nonce: #{nonce}
      Issued At: #{Time.current.utc.iso8601}
    MSG

    { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)), pubkey: pubkey_b58 }
  end

  test "verify accepts a wallet-composed signIn message and establishes the session" do
    params = wallet_composed_verify_params

    assert_difference "User.count", 1 do
      post "/auth/solana/verify", params: params.merge(age_attestation: "1"), as: :json
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]

    user = User.find_by(web3_solana_address: params[:pubkey])
    assert_equal user.id, session[:turf_user_id], "a wallet-composed message must log the user in"
    assert session[:onchain], "signIn must still grant the on-chain session privilege"
  end

  test "verify consumes the nonce on a wallet-composed message, so it cannot replay" do
    params = wallet_composed_verify_params
    post "/auth/solana/verify", params: params.merge(age_attestation: "1"), as: :json
    assert_response :success

    # Same signature, same message, fresh request — the nonce is spent.
    reset!
    post "/auth/solana/verify", params: params.merge(age_attestation: "1"), as: :json
    assert_response :unauthorized, "a spent nonce must not authenticate a replay"
  end

  test "link_solana accepts the single-line User-ID statement signIn produces" do
    user = users(:sam)
    log_in_as(user)

    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    # The inline form — SIWS `statement` is one line, unlike the fallback
    # message's own "User-ID: <id>" paragraph. OPSEC-005 checks `include?`.
    host = "www.example.com"
    message = <<~MSG.strip
      #{host} wants you to sign in with your Solana account:
      #{pubkey_b58}

      Sign in to Turf Monster (User-ID: #{user.id})

      Nonce: #{nonce}
    MSG

    post "/account/link_solana",
         params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)), pubkey: pubkey_b58 },
         as: :json

    assert_response :success
    assert_equal pubkey_b58, user.reload.web3_solana_address,
                 "the inline User-ID binding must satisfy OPSEC-005 and link the wallet"
  end

  test "link_solana still refuses a message with no User-ID binding" do
    user = users(:sam)
    address_before = user.web3_solana_address # the fixture ships one
    log_in_as(user)

    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    host = "www.example.com"
    message = "#{host} wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nSign in to Turf Monster\n\nNonce: #{nonce}"

    post "/account/link_solana",
         params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)), pubkey: pubkey_b58 },
         as: :json

    assert_response :unauthorized
    assert_equal address_before, user.reload.web3_solana_address,
                 "an unbound signature must not repoint the account's wallet"
  end

  test "verify still logs in an existing wallet user without any attestation (grandfathered)" do
    user = users(:sam)
    key = log_in_as_onchain(user) # creates the address + logs in via verify
    assert_equal user.id, session[:turf_user_id]
    assert_nil user.reload.age_attested_at, "login must not stamp attestation"
    assert key, "helper returns the signing key"
  end
end
