require "test_helper"

# Every turf path that trusts a Solana signature for an address must refuse the
# small-order public keys in Solana::ForgeableSigninKeys, and must refuse them
# with the same response a bad signature gets.
#
# WHY verify! IS STUBBED. The refusal has to hold for a request whose signature
# VERIFIES, because that is the only request that reaches it. Making verify!
# pass for one of these keys for real would put signature vectors into this
# repo, so instead the stub accepts whatever it is handed. Each stubbed test has
# a control that the same stub, given a real address, goes on to create or link
# the account — so a refusal below is the guard's, not the stub's.
class ForgeableSigninKeysRefusalTest < ActionDispatch::IntegrationTest
  HOST = "www.example.com".freeze
  KEYS = Solana::ForgeableSigninKeys::ENCODINGS.keys.freeze

  def fresh_nonce
    get "/auth/solana/nonce"
    JSON.parse(response.body).fetch("nonce")
  end

  def sign_in_message(pubkey_b58, nonce, user_id: nil)
    binding_line = user_id ? "\n\nUser-ID: #{user_id}" : ""
    "#{HOST} wants you to sign in with your Solana account:\n#{pubkey_b58}#{binding_line}\n\nNonce: #{nonce}"
  end

  def real_address = Solana::Keypair.encode_base58(Ed25519::SigningKey.generate.verify_key.to_bytes)

  # Params whose signature verifies only because verify! is stubbed.
  def accepted_params(pubkey_b58, user_id: nil)
    { message: sign_in_message(pubkey_b58, fresh_nonce, user_id: user_id),
      signature: Solana::Keypair.encode_base58(("\x01" * 64).b),
      pubkey: pubkey_b58, age_attestation: "1" }
  end

  def with_verify_accepting(&block)
    Solana::AuthVerifier.stub(:verify!, ->(**kw) { kw.fetch(:pubkey_b58) }, &block)
  end

  # The response a real wallet gets for a signature made by a different key.
  def bad_signature_response(path, user_id: nil)
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    message = sign_in_message(pubkey_b58, fresh_nonce, user_id: user_id)
    forged_by_other = Solana::Keypair.encode_base58(Ed25519::SigningKey.generate.sign(message))

    post path, params: { message: message, signature: forged_by_other, pubkey: pubkey_b58, age_attestation: "1" }, as: :json
    assert_response :unauthorized, "control: a wrong signature must be refused"
    response.parsed_body
  end

  def email_user
    User.create!(email: "forgeable-#{SecureRandom.hex(4)}@example.com", email_verified_at: Time.current)
  end

  # --- sign-in ---------------------------------------------------------------

  test "sign-in refuses every forgeable key, creating no user and no session" do
    expected = bad_signature_response("/auth/solana/verify")

    with_verify_accepting do
      KEYS.each do |address|
        assert_no_difference "User.count", "sign-in with #{address} created a user" do
          post "/auth/solana/verify", params: accepted_params(address), as: :json
        end
        assert_response :unauthorized, address
        assert_equal expected, response.parsed_body, "#{address}: refusal must read as a bad signature"
        assert_nil session[:turf_user_id], "#{address}: no session may be established"
        assert_nil User.find_by(web3_solana_address: address)
      end

      # Control: the same stub, with a real address, creates the account.
      address = real_address
      assert_difference "User.count", 1 do
        post "/auth/solana/verify", params: accepted_params(address), as: :json
      end
      assert_response :success
    end
  end

  test "sign-in refuses a forgeable key even for an account that already holds it" do
    holder = email_user
    address = KEYS.last
    holder.update_columns(web3_solana_address: address)

    with_verify_accepting do
      assert_difference "ErrorLog.count", 1 do
        post "/auth/solana/verify", params: accepted_params(address), as: :json
      end
    end

    assert_response :unauthorized
    assert_nil session[:turf_user_id], "the holder's account must not be signed into"
    assert_includes ErrorLog.order(:id).last.message, address, "the attempt must be recorded"
  end

  # NOT stubbed. solana-studio 0.11.0 decoded "1" * 31 to the all-zero key, one
  # of the listed keys. 0.12.0 decodes it to 31 bytes, so the real verify!
  # refuses it on length, before the signature is checked, and nothing is made.
  test "sign-in refuses the old all-ones alias of the zero key on length" do
    address = "1" * 31

    assert_no_difference "User.count" do
      post "/auth/solana/verify", params: accepted_params(address), as: :json
    end
    assert_response :unauthorized
    assert_equal "Public key must be 32 bytes, got 31", response.parsed_body["error"]
    assert_nil session[:turf_user_id], "no session may be established"
    assert_nil User.find_by(web3_solana_address: address)
  end

  test "a real wallet still signs in" do
    key = Ed25519::SigningKey.generate
    address = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    message = sign_in_message(address, fresh_nonce)

    assert_difference "User.count", 1 do
      post "/auth/solana/verify",
           params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)),
                     pubkey: address, age_attestation: "1" },
           as: :json
    end
    assert_response :success
    assert_equal User.find_by!(web3_solana_address: address).id, session[:turf_user_id]
  end

  # --- wallet link -----------------------------------------------------------

  test "link refuses every forgeable key and leaves the account untouched" do
    user = email_user
    log_in_as(user)
    expected = bad_signature_response("/account/link_solana", user_id: user.id)

    with_verify_accepting do
      KEYS.each do |address|
        assert_no_difference "User.count", "link with #{address} changed the user count" do
          post "/account/link_solana", params: accepted_params(address, user_id: user.id), as: :json
        end
        assert_response :unauthorized, address
        assert_equal expected, response.parsed_body, "#{address}: refusal must read as a bad signature"
        assert_nil user.reload.web3_solana_address, "#{address} must not be linked"
      end

      # Control: the same stub, with a real address, links it.
      address = real_address
      post "/account/link_solana", params: accepted_params(address, user_id: user.id), as: :json
      assert_response :success
      assert_equal address, user.reload.web3_solana_address
    end
  end

  test "link refuses a forgeable key another account holds, so nothing merges" do
    holder = email_user
    address = KEYS.first
    holder.update_columns(web3_solana_address: address)

    linker = email_user
    log_in_as(linker)

    with_verify_accepting do
      assert_no_difference "User.count" do
        post "/account/link_solana", params: accepted_params(address, user_id: linker.id), as: :json
      end
    end

    assert_response :unauthorized
    assert_equal address, holder.reload.web3_solana_address, "the holder must survive unmerged"
    assert_nil linker.reload.web3_solana_address
  end

  test "a real wallet still links" do
    user = email_user
    log_in_as(user)

    key = Ed25519::SigningKey.generate
    address = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    message = sign_in_message(address, fresh_nonce, user_id: user.id)

    post "/account/link_solana",
         params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)), pubkey: address },
         as: :json
    assert_response :success
    assert_equal address, user.reload.web3_solana_address
  end

  # --- self-custody proof ----------------------------------------------------

  test "self-custody proof refuses a forgeable address with the bad-signature response" do
    user = email_user
    grant_managed_wallet!(user)
    user.update!(export_initiated_at: Time.current)
    token = Rails.application.message_verifier(AccountsController::WALLET_EXPORT_TOKEN_KEY).generate(
      { user_id: user.id, email: user.email, initiated_at: user.export_initiated_at.to_i }, expires_in: 30.minutes
    )
    signature = Solana::Keypair.encode_base58(("\x01" * 64).b)

    # Control: a wrong signature against the managed address, for real.
    post complete_wallet_export_path(token: token),
         params: { signature: signature, message: WalletExportsController.prove_message(token: token, address: user.solana_address) },
         as: :json
    assert_response :unprocessable_entity
    expected = response.parsed_body

    address = KEYS[4]
    user.update_columns(web3_solana_address: address)
    accepting = Object.new.tap { |verifier| verifier.define_singleton_method(:verify) { |*| true } }

    Ed25519::VerifyKey.stub(:new, ->(*) { accepting }) do
      post complete_wallet_export_path(token: token),
           params: { signature: signature, message: WalletExportsController.prove_message(token: token, address: address) },
           as: :json
    end

    assert_response :unprocessable_entity
    assert_equal expected, response.parsed_body
    assert_nil user.reload.self_custodied_at, "custody of a forgeable address must not be recorded"
  end

  # --- wiring ----------------------------------------------------------------

  # A future caller of either verifier must not skip the guard.
  test "every signature check in app/ is paired with the forgeable-key guard" do
    guarded = Dir[Rails.root.join("app/**/*.rb")].sum do |path|
      code = File.readlines(path).reject { |line| line.strip.start_with?("#") }.join
      checks = code.scan("verify_solana_signature!(").size + code.scan("Ed25519::VerifyKey.new(").size
      assert_equal checks, code.scan("ForgeableSigninKeys.refuse!(").size,
                   "#{path}: every signature check needs its own ForgeableSigninKeys.refuse!"
      checks
    end

    assert_operator guarded, :>=, 3, "control: the scan must find the sign-in, link and self-custody checks"
  end

  test "the sign-in route is served by this app's guarded controller" do
    file, = SolanaSessionsController.instance_method(:verify).source_location
    assert file.start_with?(Rails.root.to_s), "verify resolves to #{file}, not this app's controller"
  end
end
