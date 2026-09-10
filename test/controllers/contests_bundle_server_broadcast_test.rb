# frozen_string_literal: true

require "test_helper"

# [integration] THE BUNDLE PROVISION IS NOW A SERVER BROADCAST.
#
# WHAT CHANGED AND WHY. contests/generator.html.erb used to sign in the browser,
# call sendRawTransaction + confirmTransaction ITSELF, and POST only the
# resulting signature. That half cannot run on the redirect transport: the
# document that would broadcast is destroyed while the wallet signs, and
# studio-engine's callback page — where the finalize POST is now made — loads no
# solanaWeb3 at all. So #generate_bundle leaves the admin slot EMPTY and
# #finalize_bundle cosigns and broadcasts, exactly as #finalize does.
#
# WHAT THAT BUYS BESIDES MOBILE, and it is the reason this file leads with it:
# the bundle path now runs assert_create_contest_cosign_safe!, which it never
# did. The server used to co-sign nothing and verify the signature after the
# fact — a wire that was not this bundle's create_contest had already moved
# money by the time anyone looked.
class ContestsBundleServerBroadcastTest < ActionDispatch::IntegrationTest
  BUNDLE_KEY = "survivor"

  # Records the ORDER of the two vault calls, because "both happened" is not the
  # invariant — "the check happened FIRST" is. A safety check that runs after the
  # broadcast is not a safety check.
  class SequenceVault < FakeVault
    def sequence = @sequence ||= []

    def assert_create_contest_cosign_safe!(*, **)
      sequence << :checked
      super
    end

    def cosign_and_broadcast_create_contest(wire)
      sequence << :broadcast
      super
    end
  end

  setup { SeasonConfig.set_current!(1) }

  def operator
    @operator ||= User.create!(
      name: "Broadcast Operator", username: "broadcast_operator", role: :admin,
      email: "broadcast_operator@mcritchie.studio",
      web3_solana_address: "BrdcstpeRaTr11111111111111111111111111111111"
    )
  end

  def run_generate_bundle(vault: FakeVault.new(usdc_balance: 100_000.0))
    json = nil
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        post generate_bundle_contests_path, params: { key: BUNDLE_KEY }, as: :json
        json = JSON.parse(response.body)
      end
    end
    assert_equal true, json["success"], "generate_bundle step failed: #{json.inspect}"
    json
  end

  def run_finalize_bundle(generate_json, vault: FakeVault.new, body: {})
    payload = {
      params_token: generate_json["params_token"],
      contest_pda:  generate_json["contest_pda"],
      signed_tx:    "SIGNED_BUNDLE_WIRE"
    }.merge(body)

    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_bundle_contests_path, params: payload, as: :json
        end
      end
    end
  end

  test "the bundle transaction is built with the admin slot EMPTY" do
    log_in_as(operator)
    vault = FakeVault.new(usdc_balance: 100_000.0)
    run_generate_bundle(vault: vault)

    # cosign_and_broadcast patches the admin signature IN. A transaction the
    # admin already signed has no empty slot to patch, so an admin-signed build
    # here makes the whole server-broadcast path unreachable — and leaves the
    # browser as the only thing that could send it.
    assert_equal false, vault.create_contest_calls.last[:params][:admin_signs],
                 "the server cosigns this later; building it admin-signed is the old browser-broadcast shape"
  end

  test "finalize_bundle checks the wire BEFORE it broadcasts" do
    log_in_as(operator)
    generate_json = run_generate_bundle
    vault = SequenceVault.new

    run_finalize_bundle(generate_json, vault: vault)

    assert_response :success
    assert_equal %i[checked broadcast], vault.sequence,
                 "a cosign-safety check that runs after the money has moved is not a check"
  end

  test "an unsafe wire is refused and nothing is broadcast" do
    log_in_as(operator)
    generate_json = run_generate_bundle
    vault = FakeVault.new
    vault.create_cosign_safe_raises = "instruction is not create_contest"

    run_finalize_bundle(generate_json, vault: vault)

    assert_equal false, response.parsed_body["success"]
    assert_empty vault.create_cosign_broadcast_calls,
                 "a refused wire must cost nothing — this is the guard the bundle path never had"
    assert_match(/did not match this bundle/i, response.parsed_body["error"],
                 "and the operator is told what to do about it, not shown a parser message")
    assert_nil Contest.find_by(slug: "world-cup-survivor-free-roll"),
               "no row may exist for a provision that never funded"
  end

  test "a body carrying a signature instead of a signed wire is refused before any spend" do
    log_in_as(operator)
    generate_json = run_generate_bundle
    vault = FakeVault.new

    # The OLD client's body. It must fail loudly rather than reach the vault with
    # nothing to cosign.
    run_finalize_bundle(generate_json, vault: vault,
                        body: { signed_tx: nil, tx_signature: "FAKE_SIG_bundle_create" })

    assert_equal false, response.parsed_body["success"]
    assert_empty vault.create_cosign_broadcast_calls
    assert_match(/Missing signed transaction/i, response.parsed_body["error"])
  end

  test "the contest is stamped with the signature the BROADCAST returned" do
    log_in_as(operator)
    generate_json = run_generate_bundle
    vault = FakeVault.new
    vault.create_cosign_broadcast_signature = "REAL_BROADCAST_SIG"

    # A client-supplied signature is present in the body and must be ignored: the
    # only signature that means anything is the one the server's own broadcast
    # answered with.
    run_finalize_bundle(generate_json, vault: vault, body: { tx_signature: "CLIENT_CLAIMED_SIG" })

    assert_response :success
    contest = Contest.find_by!(slug: "world-cup-survivor-free-roll")
    assert_equal "REAL_BROADCAST_SIG", contest.onchain_tx_signature,
                 "the row must carry the signature the chain actually got, never one the client asserted"
  end
end
