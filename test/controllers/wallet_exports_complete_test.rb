require "test_helper"

class WalletExportsCompleteTest < ActionDispatch::IntegrationTest
  setup do
    @managed = User.create!(
      name: "Maggie Managed", username: "maggie-managed-#{SecureRandom.hex(2)}",
      email: "managed-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    grant_managed_wallet!(@managed)
    assert @managed.reload.managed_wallet?

    # Pin export_initiated_at and mint the token the magic email would have
    # carried — same shape as AccountsController#initiate_wallet_export.
    @managed.update!(export_initiated_at: Time.current)
    @token = Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: @managed.id, email: @managed.email, initiated_at: @managed.export_initiated_at.to_i },
      expires_in: 30.minutes
    )

    @keypair = @managed.solana_keypair
    @message = WalletExportsController.prove_message(token: @token, address: @managed.solana_address)
  end

  test "valid signature flips self_custodied_at" do
    sig = @keypair.sign(@message)
    sig_b58 = Solana::Keypair.encode_base58(sig)

    assert_nil @managed.self_custodied_at

    post complete_wallet_export_path(token: @token),
         params: { signature: sig_b58, message: @message },
         as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal account_path, body["redirect"]

    @managed.reload
    assert_not_nil @managed.self_custodied_at
    assert @managed.self_custodied?
  end

  test "signature from a different keypair is rejected" do
    foreign_kp = Solana::Keypair.generate
    sig        = foreign_kp.sign(@message)
    sig_b58    = Solana::Keypair.encode_base58(sig)

    post complete_wallet_export_path(token: @token),
         params: { signature: sig_b58, message: @message },
         as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_not body["success"]
    assert_match(/didn't verify/i, body["error"])

    @managed.reload
    assert_nil @managed.self_custodied_at
  end

  test "submitted message must match the canonical prove-custody string exactly" do
    sig = @keypair.sign("attacker-chosen content not the expected message")
    sig_b58 = Solana::Keypair.encode_base58(sig)

    post complete_wallet_export_path(token: @token),
         params: { signature: sig_b58, message: "attacker-chosen content not the expected message" },
         as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/unexpected message format/i, body["error"])

    @managed.reload
    assert_nil @managed.self_custodied_at
  end

  test "complete on an already-self-custodied user fails at the token-verify gate" do
    @managed.update!(self_custodied_at: 1.minute.ago)

    sig = @keypair.sign(@message)
    sig_b58 = Solana::Keypair.encode_base58(sig)

    post complete_wallet_export_path(token: @token),
         params: { signature: sig_b58, message: @message },
         as: :json
    assert_response :gone
    assert_match(/already self-custodied/i, response.body)
  end

  test "missing signature param returns 422" do
    post complete_wallet_export_path(token: @token),
         params: { message: @message },
         as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/missing signature/i, body["error"])
  end

  test "signature param with garbage base58 returns 422 without crashing" do
    post complete_wallet_export_path(token: @token),
         params: { signature: "!!!not_valid_base58!!!", message: @message },
         as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_not body["success"]
    # Don't assert exact wording — could be ArgumentError from decode_base58
    # or VerifyError, both surface a friendly message.
  end
end
