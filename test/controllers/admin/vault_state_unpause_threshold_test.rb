require "test_helper"
require "minitest/mock"

# `unpause` — the sixth raised path, and the only one that does not go through
# the PendingTransaction queue.
#
# ── WHY IT IS THE ODD ONE OUT ─────────────────────────────────────────────
#
# The other five raised actions queue a row and are cosigned from the treasury
# page. `unpause` renders its wire straight to the browser from a synchronous
# endpoint, so it has its own build, its own inline signing flow and its own
# confirm — and therefore its own copy of every mistake. It broke the same way
# as the rest (two signatures against a threshold of three, 6046
# InsufficientSigners) and had to be fixed separately.
#
# ── AND WHY PAUSE MUST NOT MOVE WITH IT ───────────────────────────────────
#
# `pause` is 2 and FLOORED at 1; `unpause` is 3 and FLOORED at 3. That gap is
# the program's stated asymmetry: a brake must be easier to pull than the
# attack it stops, and nothing an agent can reach on its own may lift a brake
# its own capture would have triggered. A change that raised both — the natural
# thing to do when "the vault page" is treated as one surface — would hand the
# higher cost to the brake, which is the inversion the floors exist to prevent.
class Admin::VaultStateUnpauseThresholdTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
  end

  def with_governance(on = true, &block)
    Solana::Config.stub(:governance?, on, &block)
  end

  def spare_signer
    (Solana::CosignPlan.eligible_cosigners - [Solana::Config::MULTISIG_COSIGNER]).first
  end

  # A vault that reports PAUSED, so `unpause` gets past its precondition.
  class PausedVault
    attr_reader :unpause_calls

    def initialize
      @unpause_calls = []
    end

    def read_vault_state
      { paused: true }
    end

    def build_unpause_vault(cosigner_pubkey:, extra_cosigners: [])
      @unpause_calls << { cosigner: cosigner_pubkey, extra_cosigners: extra_cosigners }
      { serialized_tx: "FAKE_TX_unpause" }
    end
  end

  # THE REGRESSION. Against the code this replaces, `build_unpause_vault` was
  # called with no `extra_cosigners:` at all and this assertion fails.
  test "unpause reserves the third signer slot" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    vault = PausedVault.new
    spare = spare_signer
    primary = Solana::Config::MULTISIG_COSIGNER

    with_governance do
      Solana::Vault.stub :new, vault do
        post admin_unpause_vault_state_path,
             params: { cosigner_pubkey: primary, extra_cosigners: [spare] }, as: :json
      end
    end

    assert_response :success
    assert_equal [spare], vault.unpause_calls.first[:extra_cosigners],
                 "unpause is floored at three signatures and must reserve the third slot"

    body = JSON.parse(response.body)
    assert_equal 3, body["required_signatures"]
    assert_equal [spare], body["extra_cosigners"]
  end

  test "unpause refuses to build with no third signer named" do
    log_in_as(@admin)

    with_governance do
      Solana::Vault.stub :new, PausedVault.new do
        post admin_unpause_vault_state_path,
             params: { cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
                       extra_cosigners: [] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/needs 3 vault signatures/, JSON.parse(response.body)["error"].to_s)
  end

  test "unpause refuses a third signer outside the vault signer set" do
    log_in_as(@admin)

    with_governance do
      Solana::Vault.stub :new, PausedVault.new do
        post admin_unpause_vault_state_path,
             params: { cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
                       extra_cosigners: ["NotAVaultSigner1111111111111111111111111111"] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/not in the vault signer set/, JSON.parse(response.body)["error"].to_s)
  end

  # THE ASYMMETRY, ASSERTED. If a future change "tidies" the two forms into one
  # threshold, this is what notices.
  test "pause stays at two signatures while unpause needs three" do
    assert_equal 2, Solana::CosignPlan.new(tx_type: "unpause").required_signatures - 1,
                 "unpause needs two BROWSER signatures beyond the server's admin key"

    with_governance do
      assert_equal 1, Solana::CosignPlan.new(tx_type: "unpause").extra_cosigners_needed
    end

    # `pause` is not a cosign-queue tx_type at all — it never rose, so it has no
    # plan and reserves nothing. Asserted through the mirror instead.
    assert_equal 2, Solana::Governance.required_signatures("pause")
    assert_operator Solana::Governance.required_signatures("pause"), :<,
                    Solana::Governance.required_signatures("unpause")
  end

  # The v0.25 shape is untouched: no extra slot, no new refusal.
  test "governance off still unpauses on two signatures" do
    log_in_as(@admin)
    vault = PausedVault.new

    with_governance(false) do
      Solana::Vault.stub :new, vault do
        post admin_unpause_vault_state_path,
             params: { cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER }, as: :json
      end
    end

    assert_response :success
    assert_equal [], vault.unpause_calls.first[:extra_cosigners]
  end
end
