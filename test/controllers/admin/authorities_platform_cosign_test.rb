require "test_helper"
require "minitest/mock"

# [unit] update_signers takes the platform cosigner only on the operator's
# tick (Mr. McRitchie, 2026-10-24), and the planner still leaves the last
# signature to one of his wallets.
class Admin::AuthoritiesPlatformCosignTest < ActiveSupport::TestCase
  GOV_3LTL = FakePlatformCosigner::GOV_3LTL

  def held(platform_param, platform: FakePlatformCosigner.new)
    controller = Admin::AuthoritiesController.new
    Solana::PlatformCosigner.stub(:current, platform) do
      Solana::Keypair.stub(:cosigners, []) do
        controller.send(:server_held_addresses, platform: platform_param)
      end
    end
  end

  test "the platform cosigner is held only when the operator asks" do
    assert_equal [], held(nil)
    assert_equal [], held("false")
    assert_equal [GOV_3LTL], held("true")
    assert_equal [], held("true", platform: FakePlatformCosigner.new(configured: false))
  end

  test "with the platform held the server signs twice and Alex once" do
    server = "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY"
    seated = Solana::Config::DEFAULT_MULTISIG_SIGNERS
    planner = Solana::SignerPlan.new(network: "mainnet-beta", governance: true, current: seated, required: 3,
                                     max_live_threshold: 3, server: server, server_held: [GOV_3LTL],
                                     connected: nil, nonce_ready: true)
    plan = planner.plan!(intent: "remove", remove: ["9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf"], add: [],
                         confirm_unknown: [])
    assert_equal [server, GOV_3LTL], plan[:authorizers].first(2)
    assert_equal 1, plan[:prompt_count], "one Phantom prompt: his wallet is the third signature"
    assert Solana::SignerRoster.default.operator?(plan[:authorizers].last)
  end
end
