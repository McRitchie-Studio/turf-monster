require "test_helper"
require "minitest/mock"

# [unit] The Treasury with the platform cosigner (Mr. McRitchie, 2026-10-24:
# "I'm only important if you need a third"). A settle's rebuild carries the
# server's and the platform's signatures and asks the browser for ONE wallet;
# the page says so; an absent cosigner leaves today's flow with a notice; a
# two-signature close can be completed by the platform on an admin click.
class Admin::PendingTransactionsPlatformCosignTest < ActionDispatch::IntegrationTest
  GOV_3LTL = "3LTLPG1s952sdNatZWtnfM7r9F3ivWSnPSqfhQLBepJ9".freeze
  ALEX_7ZDJ = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  ALEX_3QJ4 = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze

  Platform = FakePlatformCosigner

  setup do
    @admin = users(:alex)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_ptx")
    log_in_as(@admin)
  end

  def ptx(tx_type, metadata = {})
    @contest.update_columns(status: "settlement_pending") if tx_type == "settle_contest"
    PendingTransaction.create!(tx_type: tx_type, serialized_tx: "OLD_TX", status: "pending", target: @contest,
                               initiator_address: "init", metadata: metadata.to_json)
  end

  def with_platform(platform, governance: true, &block)
    Solana::Config.stub(:governance?, governance) do
      Solana::Vault.stub(:cached_vault_state, nil) do
        Solana::PlatformCosigner.stub(:current, platform, &block)
      end
    end
  end

  test "a settle rebuild carries two platform signatures and asks the browser for one wallet" do
    tx = ptx("settle_contest", settlements: [])
    vault = FakeVault.new
    platform = Platform.new

    with_platform(platform) do
      Solana::Vault.stub :new, vault do
        post rebuild_admin_pending_transaction_path(slug: tx.slug), params: { extra_cosigners: [ALEX_7ZDJ] }, as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal GOV_3LTL, vault.settle_calls.first[:cosigner], "the platform holds the named slot"
    assert_equal [ALEX_7ZDJ], vault.settle_calls.first[:extra_cosigners]
    assert_equal "PLATFORM_SIGNED(FAKE_TX_settle_#{@contest.slug})", body["serialized_tx"]
    assert_equal [ALEX_7ZDJ], body["signer_queue"], "exactly one wallet for Phantom"
    assert_equal GOV_3LTL, body["platform_cosigner_address"]
    assert_equal GOV_3LTL, tx.reload.platform_cosigner, "the row records who signed its named slot"
    assert_equal "PLATFORM_SIGNED(FAKE_TX_settle_#{@contest.slug})", tx.serialized_tx
  end

  test "the page says one signature is needed, from Alex's wallets" do
    ptx("settle_contest", settlements: [])
    with_platform(Platform.new) do
      Solana::Vault.stub :new, FakeVault.new do
        get admin_pending_transactions_path
      end
    end

    assert_response :success
    assert_includes response.body, "One signature needed"
    assert_match(/Alex, from 7ZDJ, 3Qj4 or 9gAC\./, response.body)
    assert_includes response.body, "Your wallet (the final signature)"
    refute_includes response.body, "Second Phantom wallet"
  end

  test "absent config: today's two-wallet flow, with a visible notice" do
    tx = ptx("settle_contest", settlements: [])
    absent = Solana::PlatformCosigner.load(env: {}, network: "mainnet-beta", admin_address: nil)
    vault = FakeVault.new

    with_platform(absent) do
      Solana::Vault.stub :new, vault do
        get admin_pending_transactions_path
        assert_response :success
        assert_includes response.body, "SOLANA_PLATFORM_COSIGNER_KEY is not set"
        assert_includes response.body, "Second Phantom wallet"

        post rebuild_admin_pending_transaction_path(slug: tx.slug), params: { extra_cosigners: [ALEX_3QJ4] }, as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal Solana::Config::MULTISIG_COSIGNER, vault.settle_calls.first[:cosigner]
    assert_nil body["signer_queue"], "the browser collects cosigner + extra, as before"
    assert_nil tx.reload.platform_cosigner
  end

  test "a cancel takes the platform's signature only when the operator ticks it" do
    meta = { creator: "Creator11111111111111111111111111111111111" }
    tx = ptx("cancel_contest", meta)
    vault = FakeVault.new
    with_platform(Platform.new) do
      Solana::Vault.stub :new, vault do
        post rebuild_admin_pending_transaction_path(slug: tx.slug), params: { extra_cosigners: [ALEX_3QJ4] }, as: :json
        assert_equal Solana::Config::MULTISIG_COSIGNER, vault.cancel_calls.last[:cosigner], "not without asking"

        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: [ALEX_3QJ4], platform_cosign: true }, as: :json
      end
    end
    assert_response :success
    assert_equal GOV_3LTL, vault.cancel_calls.last[:cosigner]
    assert_equal [ALEX_3QJ4], JSON.parse(response.body)["signer_queue"]
  end

  test "the broadcast records the platform as the named cosigner and Alex as the extra" do
    tx = ptx("settle_contest", settlements: [])
    tx.update!(metadata: { settlements: [], platform_cosigner: GOV_3LTL }.to_json)
    vault = FakeVault.new
    with_platform(Platform.new) do
      Solana::Vault.stub :new, vault do
        Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
                 params: { signed_tx: "SIGNED", cosigner_address: GOV_3LTL, extra_cosigners: [ALEX_7ZDJ] }, as: :json
          end
        end
      end
    end
    assert_response :success, response.body
    assert_equal [GOV_3LTL, ALEX_7ZDJ], tx.reload.cosigner_addresses
  end

  test "a close is completed by the server and the platform on an admin click, and recorded" do
    @contest.update_columns(status: "settled")
    tx = ptx("close_contest")
    vault = FakeVault.new
    posted = []
    poster = ->(**kw) { posted << kw; "posted" }

    with_platform(Platform.new) do
      Solana::Vault.stub :new, vault do
        Solana::TxVerifier.stub :verify!, true do
          Studio::PostActivity.stub :call, poster do
            post complete_with_platform_admin_pending_transaction_path(slug: tx.slug)
          end
        end
      end
    end

    assert_redirected_to admin_pending_transactions_path
    assert_equal({ slug: @contest.slug, cosigner: GOV_3LTL, extra_cosigners: [] }, vault.close_build_calls.first)
    assert_equal ["PLATFORM_SIGNED(FAKE_TX_close_#{@contest.slug})"], vault.broadcast_calls
    tx.reload
    assert_equal "confirmed", tx.status
    assert @contest.reload.onchain_closed
    completion = tx.parsed_metadata["platform_completion"]
    assert_equal @admin.email, completion["by_admin"]
    assert_includes completion["signers"], GOV_3LTL
    assert_equal "posted", completion["hub_activity"]
    assert_equal 1, posted.length
    assert_match(/completed on .* by the server and the platform cosigner/, posted.first[:description])
  end

  test "a three-signature settle is never completed by the platform alone" do
    tx = ptx("settle_contest", settlements: [])
    vault = FakeVault.new
    with_platform(Platform.new) do
      Solana::Vault.stub :new, vault do
        post complete_with_platform_admin_pending_transaction_path(slug: tx.slug)
      end
    end
    assert_redirected_to admin_pending_transactions_path
    assert_match(/cannot be completed by the platform alone/, flash[:alert])
    assert_empty vault.broadcast_calls
    assert_equal "pending", tx.reload.status
  end
end
