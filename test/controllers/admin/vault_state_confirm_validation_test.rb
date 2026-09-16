require "test_helper"
require "minitest/mock"

# Admin::VaultStateController#confirm — the pause/unpause confirmation, and the
# half of its validation that was missing.
#
# ── THE GAP ───────────────────────────────────────────────────────────────────
#
# It validated every extra signer it was GIVEN and never that it was given
# enough. On a v0.26 boot `unpause` needs THREE vault signatures, so a request
# naming zero extras proved ONE signature and was recorded as a confirmed
# unpause — a third of the claim written down as the whole of it. Its primary
# cosigner was not membership-checked either, while the sibling path
# (`Admin::PendingTransactionsController#require_multisig_cosigner!`) has always
# checked it.
#
# It is audit-record quality rather than a payout, but the four cosign
# confirmation paths must not disagree about how many wallets an action takes —
# and the count now comes from `CosignPlan#validate_extras!`, the same call
# `#unpause` sizes its BUILD from.
class Admin::VaultStateConfirmValidationTest < ActionDispatch::IntegrationTest
  VAULT_PDA_B58 = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze

  class StubVault
    # REAL 32-byte pubkey bytes, so `Keypair.encode_base58` runs for real.
    def vault_state_pda = [Solana::Keypair.decode_base58(VAULT_PDA_B58), 254]
  end

  setup do
    @admin = users(:alex)
    log_in_as(@admin)
  end

  def with_governance(on = true, &block) = Solana::Config.stub(:governance?, on, &block)

  def spare_signer
    (Solana::CosignPlan.eligible_cosigners - [Solana::Config::MULTISIG_COSIGNER]).first
  end

  def confirm(verifier: ->(**) { true }, **params)
    Solana::Vault.stub :new, StubVault.new do
      Solana::TxVerifier.stub :verify!, verifier do
        post admin_confirm_vault_state_path,
             params: { instruction: "unpause", tx_signature: "MockTxSignatureConfirm" }.merge(params),
             as: :json
      end
    end
  end

  def error_body = JSON.parse(response.body)["error"].to_s

  # THE REGRESSION. Against the code this replaces this returns 200 — one
  # proven signature recorded as a confirmed three-signature unpause.
  test "unpause confirmation refuses a claim that names too few signers" do
    with_governance do
      confirm(cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER, extra_cosigners: [])
    end

    assert_response :unprocessable_entity
    assert_match(/needs 3 vault signatures/, error_body)
  end

  test "unpause confirmation refuses an extra signer outside the vault set" do
    with_governance do
      confirm(cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
              extra_cosigners: ["NotAVaultSigner1111111111111111111111111111"])
    end

    assert_response :unprocessable_entity
    assert_match(/not in the vault signer set/, error_body)
  end

  # THE COUNT AND THE MEMBERSHIP ARE NOT THE SAME CHECK, and a set that passes
  # both must still be proven to have SIGNED what landed.
  test "unpause confirmation proves every named signer against the landed transaction" do
    skip "needs a spare vault signer" if spare_signer.blank?
    spare = spare_signer
    primary = Solana::Config::MULTISIG_COSIGNER
    verified = []
    recorder = lambda do |signature:, instruction_name:, signer_pubkey: nil, writable_pubkey: nil, client: nil|
      verified << signer_pubkey
      true
    end

    with_governance do
      confirm(verifier: recorder, cosigner_pubkey: primary, extra_cosigners: [spare])
    end

    assert_response :success
    assert_equal [primary, spare], verified,
                 "both the named cosigner and the extra must be proven to have signed"
  end

  # The half the sibling path always had and this one did not. A WELL-FORMED
  # pubkey on purpose: the shape check is not the membership check, and only a
  # decodable key reaches the one this test is about.
  test "confirmation refuses a primary cosigner outside the multisig set" do
    outsider = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9" # a mint, not a signer
    assert_not_includes Solana::Config::MULTISIG_SIGNERS, outsider

    with_governance do
      confirm(cosigner_pubkey: outsider, extra_cosigners: [])
    end

    assert_response :unprocessable_entity
    assert_match(/not in multisig set/, error_body)
  end

  # `pause` never rose above two signatures and is deliberately NOT a
  # CosignPlan action, so it reserves nothing — and may therefore have nothing
  # claimed against it either.
  test "a pause confirmation that names extra signers is refused, not ignored" do
    skip "needs a spare vault signer" if spare_signer.blank?

    with_governance do
      confirm(instruction: "pause", cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
              extra_cosigners: [spare_signer])
    end

    assert_response :unprocessable_entity
    assert_match(/reserves no extra cosigner slots/, error_body)
  end

  test "a pause confirmation with no extras still confirms" do
    with_governance do
      confirm(instruction: "pause", cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER)
    end

    assert_response :success
  end

  # The v0.25 shape is untouched: no extra slot, no new refusal. `pause` is 2
  # and `unpause` 3 only once governance is on, and the deployed clusters are
  # still v0.25 — a change that refused there would break the live page.
  test "governance off still confirms an unpause on two signatures" do
    with_governance(false) do
      confirm(cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER)
    end

    assert_response :success
  end
end
