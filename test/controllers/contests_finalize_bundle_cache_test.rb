# frozen_string_literal: true

require "test_helper"

# ContestsController#finalize_bundle MUST DROP THE NAVBAR BALANCE CACHE.
#
# Same bug as the one pinned for #finalize in
# contests_finalize_write_ordering_test.rb, reached by a different route — and
# the route is why it was missed. #finalize broadcasts `create_contest` itself,
# so the spend has an obvious line in the SERVER to sit behind. #finalize_bundle
# broadcasts nothing, which reads like "no money moves here". It does not.
#
# THE CLIENT BROADCASTS FIRST. contests/generator.html.erb runs
# `connection.sendRawTransaction` and then `connection.confirmTransaction` on
# the operator-signed prize-pool transfer, and only THEN POSTs to
# finalize_bundle. The USDC is on-chain and out of the wallet before this action
# is entered, so the whole body — and both rescues — are already post-spend.
#
# And it is reachable end to end:
#   - finalize_bundle renders `redirect: generator_contests_path`
#   - generator.html.erb assigns that to window.location.href (a full load)
#   - ContestsController#generator sets no @wallet_balances, so
#     #display_balance takes its cache-first branch and reads the still-warm
#     pre-spend USDC and USDT for the rest of the 60s TTL.
#
# Per contest_bundle.rb's header, finalize_phantom! "funds the prize pool from
# their USDC" and is "the only path that works on prod" — so this is the
# production provisioning path, not a corner.
#
# Raised by review on PR #592 (acceptance 2). Task: finalize-busts-balance-cache.
class ContestsFinalizeBundleCacheTest < ActionDispatch::IntegrationTest
  # The "survivor" bundle carries `slate_name: nil`, so it needs no slate
  # fixture — the bundle token, not the slate, is what this file is about.
  BUNDLE_KEY = "survivor"

  setup do
    # #generate_bundle refuses to build an on-chain contest without an active
    # season, and #finalize_bundle re-checks it via ensure_onchain_season_ready!.
    SeasonConfig.set_current!(1)
  end

  def operator
    @operator ||= User.create!(
      name: "Bundle Operator", username: "bundle_operator", role: :admin,
      email: "bundle_operator@mcritchie.studio",
      # Base58 excludes 0/O/I/l — an address carrying one is rejected upstream
      # of anything this file is testing.
      web3_solana_address: "BuNDLeoperator11111111111111111111111111111"
    )
  end

  # Step 1 of the bundle flow — the real action, so the params_token the
  # finalize leg verifies is the genuine server-issued one.
  def run_generate_bundle
    json = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        post generate_bundle_contests_path, params: { key: BUNDLE_KEY }, as: :json
        json = JSON.parse(response.body)
      end
    end
    assert_equal true, json["success"], "generate_bundle step failed: #{json.inspect}"
    json
  end

  # Step 3 — the action under test. `verifier` stands in for the whole leg after
  # the invalidate, so a caller can inject a fault.
  def run_finalize_bundle(generate_json, verifier: true)
    body = {
      params_token: generate_json["params_token"],
      contest_pda:  generate_json["contest_pda"],
      tx_signature: "FAKE_SIG_bundle_create"
    }

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, verifier do
          post finalize_bundle_contests_path, params: body, as: :json
        end
      end
    end
  end

  def warm_balance_cache_for(user)
    Rails.cache.write("usdc_balance:#{user.id}", 1284.0, expires_in: 60.seconds)
    Rails.cache.write("usdt_balance:#{user.id}", 7.0, expires_in: 60.seconds)
  end

  def balance_cache_for(user)
    [Rails.cache.read("usdc_balance:#{user.id}"), Rails.cache.read("usdt_balance:#{user.id}")]
  end

  # ACCEPTANCE 2 — the success path. The redirect this render hands back lands
  # on a page that reads the cache, so the cache must be cold by then.
  test "finalize_bundle drops BOTH balance cache keys once the prize pool has moved" do
    # The test env runs :null_store (every read is nil), so a real store is
    # required for "was it deleted?" to mean anything at all.
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      log_in_as(operator)
      generate_json = run_generate_bundle
      warm_balance_cache_for(operator)
      assert_equal [1284.0, 7.0], balance_cache_for(operator), "precondition: cache is warm"

      run_finalize_bundle(generate_json)

      assert_response :success
      assert_equal true, response.parsed_body["success"], "precondition: this finalize must have SUCCEEDED"
      assert_equal generator_contests_path, response.parsed_body["redirect"],
        "the redirect is the mechanism — it lands on #generator, which reads the cache"
      assert_equal [nil, nil], balance_cache_for(operator),
        "both keys must be dropped — USDC alone leaves USDT warm and renders $7 as the wallet total"
    end
  end

  # THE PLACEMENT, not merely the presence — and here it is load-bearing in a
  # way it was not for #finalize. The client already spent the money, so a
  # finalize that fails ANYWHERE still owes the drop. Put the call beside the
  # render and this test fails while the one above still passes.
  test "a finalize_bundle that RAISES after entry still drops the balance cache" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      log_in_as(operator)
      generate_json = run_generate_bundle
      warm_balance_cache_for(operator)

      # The OPSEC-010 read-back flakes: the money is on-chain, the request
      # fails, nothing is persisted. The operator must not be shown their
      # pre-spend balance for the rest of the TTL.
      run_finalize_bundle(generate_json, verifier: ->(*) { raise "read-back flaked" })

      assert_not response.parsed_body["success"], "precondition: this finalize must have FAILED"
      assert_equal [nil, nil], balance_cache_for(operator),
        "the client spent the money before this action was entered, so a failed finalize " \
        "owes the drop too — this is why the call sits above the body and not beside the render"
    end
  end
end
