require "test_helper"
require "minitest/mock"

# [unit] WHEN the platform cosigner signs (Solana::CosignPlan#platform_cosign?,
# #platform_completes?) and the settle it builds at grade time
# (Solana::PlatformCosign.build_settle). Mr. McRitchie's 2026-10-24 ruling:
# the platform supplies two signatures and his wallet is always the third.
class Solana::PlatformCosignPlanTest < ActiveSupport::TestCase
  GOV_3LTL = "3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9".freeze
  ALEX_7ZDJ = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze

  Platform = FakePlatformCosigner

  def with_governance(on = true, &block)
    Solana::Config.stub(:governance?, on) do
      Solana::Vault.stub(:cached_vault_state, nil, &block)
    end
  end

  def plan(tx_type) = Solana::CosignPlan.new(tx_type: tx_type)

  test "a settle takes the platform's signature automatically on a three-signature chain" do
    with_governance do
      assert plan("settle_contest").platform_cosign?(platform: Platform.new)
    end
  end

  test "never when no extra slot is left for Alex: a v0.25 boot is two signatures in all" do
    with_governance(false) do
      refute plan("settle_contest").platform_cosign?(platform: Platform.new),
             "two platform signatures would complete a v0.25 settle with no wallet of his"
    end
  end

  test "never when absent, refused, or not seated" do
    with_governance do
      refute plan("settle_contest").platform_cosign?(platform: Platform.new(configured: false))
      refute plan("settle_contest").platform_cosign?(platform: Platform.new("NotSeated11111111111111111111111111111111111"))
    end
  end

  test "the other three-signature actions only when the operator asks" do
    with_governance do
      %w[cancel_contest sweep_operator_revenue register_currency deactivate_currency update_signers].each do |type|
        refute plan(type).platform_cosign?(platform: Platform.new), "#{type} must not cosign by default"
        assert plan(type).platform_cosign?(requested: "true", platform: Platform.new), "#{type} cosigns on request"
      end
    end
  end

  test "unpause has no platform path: lifting the brake keeps two of his wallets" do
    with_governance do
      refute plan("unpause").platform_cosign?(requested: "true", platform: Platform.new)
    end
  end

  test "a two-signature close may be completed by the server and the platform alone" do
    with_governance do
      assert plan("close_contest").platform_completes?(platform: Platform.new)
      refute plan("settle_contest").platform_completes?(platform: Platform.new), "three signatures never complete alone"
      refute plan("close_contest").platform_completes?(platform: Platform.new(configured: false))
    end
    with_governance(false) do
      refute plan("close_contest").platform_completes?(platform: Platform.new), "v0.25 has no two-signature table"
    end
  end

  # ── the settle built at grade time ────────────────────────────────────────

  test "grade time builds the settle with the platform in the named slot and Alex's wallet in the extra" do
    vault = FakeVault.new
    platform = Platform.new
    result = with_governance do
      Solana::PlatformCosign.build_settle(vault: vault, slug: "c1", settlements: [], platform: platform, nonce: nil)
    end

    call = vault.settle_calls.first
    assert_equal GOV_3LTL, call[:cosigner], "the platform cosigner holds the named slot"
    assert_equal [ALEX_7ZDJ], call[:extra_cosigners], "the third slot is his highest-priority wallet"
    assert_equal "PLATFORM_SIGNED(FAKE_TX_settle_c1)", result[:serialized_tx], "the platform signed the queued bytes"
    assert_equal GOV_3LTL, result[:platform_cosigner]
  end

  test "absent config builds exactly today's settle" do
    vault = FakeVault.new
    result = with_governance do
      Solana::PlatformCosign.build_settle(vault: vault, slug: "c1", settlements: [],
                                          platform: Platform.new(configured: false), nonce: nil)
    end

    call = vault.settle_calls.first
    assert_equal Solana::Config::MULTISIG_COSIGNER, call[:cosigner]
    assert_equal [], call[:extra_cosigners]
    assert_equal "FAKE_TX_settle_c1", result[:serialized_tx]
    assert_nil result[:platform_cosigner]
  end

  test "the roster names the platform row as automatic and his wallet as the final signature" do
    rows = with_governance do
      plan("settle_contest").roster(extras: [ALEX_7ZDJ], platform_cosigner: GOV_3LTL)
    end
    platform_row = rows.find { |r| r[:role] == "platform" }
    assert_equal GOV_3LTL, platform_row[:address]
    assert platform_row[:signs_automatically]
    assert_equal ["Your wallet (the final signature)"], rows.select { |r| r[:role] == "extra" }.map { |r| r[:label] }
    assert_equal 1, rows.count { |r| !r[:signs_automatically] }, "exactly one wallet to sign"
  end
end
