require "test_helper"

class Cdp::OfframpSendsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:jordan)
    # The off-ramp sends FROM a custodial wallet, so this user needs one.
    # generate_managed_wallet! alone no longer provides it — web3-only onboarding
    # (default ON since 2026-08-15) makes it a no-op.
    grant_managed_wallet!(@user)
    @to_address = Solana::Keypair.generate.address
  end

  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def create_ramp(user: @user, wallet_mode: "web2", wallet_address: nil, **attrs)
    CdpRampTransaction.create!({
      user: user,
      direction: "offramp",
      wallet_address: wallet_address || (wallet_mode == "web2" ? user.web2_solana_address : Solana::Keypair.generate.address),
      wallet_mode: wallet_mode,
      status: "cdp_created",
      to_address: @to_address,
      sell_amount_value: BigDecimal("19"),
      sell_amount_currency: "USDC",
      cashout_deadline_at: 25.minutes.from_now
    }.merge(attrs))
  end

  # Full get_account_info envelope (FakeSolanaClient returns account_infos
  # values verbatim, mirroring the real RPC's { "value" => ... } shape).
  def token_account_info
    mint_bytes = Solana::Keypair.decode_base58(Solana::Config::USDC_MINT)
    { "value" => {
      "owner" => Cdp::OfframpDestination::TOKEN_PROGRAM_ID_B58,
      "data" => [Base64.strict_encode64(mint_bytes + ("\x00" * 133).b), "base64"]
    } }
  end

  # NB: FakeSolanaClient defines #call (the raw JSON-RPC passthrough), and
  # Minitest's stub INVOKES a callable value — wrap in a lambda so the stub
  # returns the fake instead of calling it.
  def stub_solana_client(fake_client, &block)
    Solana::Client.stub :new, ->(*) { fake_client }, &block
  end

  # ── Gates shared by all three endpoints ────────────────────────────────────

  test "404s when the flag is off" do
    with_cdp_ramp(nil) do
      post cdp_offramp_confirm_send_path, params: { partner_user_ref: "tm-x" }, as: :json
      assert_response :not_found
    end
  end

  test "requires authentication (JSON 401)" do
    with_cdp_ramp do
      post cdp_offramp_confirm_send_path, params: { partner_user_ref: "tm-x" }, as: :json
      assert_response :unauthorized
    end
  end

  test "404s another user's ramp and unknown refs" do
    with_cdp_ramp do
      other = create_ramp(user: users(:sam), wallet_mode: "web3")
      log_in_as @user

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: other.partner_user_ref }, as: :json
      assert_response :not_found

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: "tm-nope" }, as: :json
      assert_response :not_found
    end
  end

  # ── confirm_send (managed) ─────────────────────────────────────────────────

  test "confirm_send stamps confirmed_at and enqueues the send job" do
    with_cdp_ramp do
      ramp = create_ramp
      log_in_as @user

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
      assert_response :success

      ramp.reload
      assert ramp.confirmed_at.present?, "confirm_send must stamp the fresh confirmation"
      job = enqueued_jobs.find { |j| j[:job] == Cdp::OfframpSendJob }
      assert job, "expected Cdp::OfframpSendJob to be enqueued"
      assert_equal ramp.id, job[:args].first["ramp_id"]
    end
  end

  test "confirm_send rejects a Phantom-mode ramp" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
      assert_response :unprocessable_entity
      assert_empty enqueued_jobs.select { |j| j[:job] == Cdp::OfframpSendJob }
    end
  end

  test "confirm_send rejects rows that aren't cdp_created or are past the window" do
    with_cdp_ramp do
      log_in_as @user

      early = create_ramp(status: "returned", cashout_deadline_at: nil)
      post cdp_offramp_confirm_send_path, params: { partner_user_ref: early.partner_user_ref }, as: :json
      assert_response :unprocessable_entity

      late = create_ramp(cashout_deadline_at: 2.minutes.from_now)
      post cdp_offramp_confirm_send_path, params: { partner_user_ref: late.partner_user_ref }, as: :json
      assert_response :unprocessable_entity
      assert_nil late.reload.confirmed_at

      assert_empty enqueued_jobs.select { |j| j[:job] == Cdp::OfframpSendJob }
    end
  end

  test "confirm_send is idempotent for an in-flight send (no duplicate job)" do
    with_cdp_ramp do
      ramp = create_ramp(status: "sending", sent_signature: "SigX")
      log_in_as @user

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
      assert_response :success
      assert_equal "sending", JSON.parse(response.body)["status"]
      assert_empty enqueued_jobs.select { |j| j[:job] == Cdp::OfframpSendJob }
    end
  end

  # ── prepare_send (Phantom) ─────────────────────────────────────────────────

  test "prepare_send resolves the destination, builds the unsigned tx, and stamps confirmed_at" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_prepare_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
        end
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert body["serialized_tx"].present?
      assert_equal ramp.wallet_address, body["wallet_address"]
      assert_equal @to_address, body["destination_token_account"]
      assert_equal 19_000_000, body["amount_base_units"]
      assert ramp.reload.confirmed_at.present?

      build = vault.offramp_unsigned_calls.first
      assert_equal ramp.wallet_address, build[:wallet]
      assert_equal 19_000_000, build[:amount]
    end
  end

  test "prepare_send fails closed when the destination can't be resolved" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      fake_client = FakeSolanaClient.new({}) # nothing on-chain
      stub_solana_client(fake_client) do
        post cdp_offramp_prepare_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
      end

      assert_response :unprocessable_entity
      assert_match(/paused for safety/, JSON.parse(response.body)["error"])
    end
  end

  test "prepare_send rejects managed-mode ramps" do
    with_cdp_ramp do
      ramp = create_ramp # web2
      log_in_as @user

      post cdp_offramp_prepare_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
      assert_response :unprocessable_entity
    end
  end

  # ── sent (Phantom signature report) ────────────────────────────────────────

  test "sent verifies the signature on-chain, records it, and nudges the poll" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      # MockTxSignature… routes through the test stub in
      # config/initializers/test_solana_stubs.rb (permissive verified shape).
      post cdp_offramp_sent_path,
           params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "MockTxSignature_offramp_1" },
           as: :json

      assert_response :success
      ramp.reload
      assert ramp.sent?
      assert_equal "MockTxSignature_offramp_1", ramp.sent_signature
      assert enqueued_jobs.any? { |j| j[:job] == Cdp::OfframpPollJob }, "poll reconciliation re-scheduled"
    end
  end

  test "sent rejects a blank signature and a mismatched re-report" do
    with_cdp_ramp do
      log_in_as @user

      ramp = create_ramp(wallet_mode: "web3")
      post cdp_offramp_sent_path, params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "" }, as: :json
      assert_response :unprocessable_entity

      recorded = create_ramp(wallet_mode: "web3", status: "sent", sent_signature: "MockTxSignature_old")
      post cdp_offramp_sent_path,
           params: { partner_user_ref: recorded.partner_user_ref, tx_signature: "MockTxSignature_new" },
           as: :json
      assert_response :unprocessable_entity
      assert_equal "MockTxSignature_old", recorded.reload.sent_signature
    end
  end

  test "sent rejects a signature that can't be verified on-chain" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      fake_client = FakeSolanaClient.new({}) # get_transaction → nil (not found)
      stub_solana_client(fake_client) do
        post cdp_offramp_sent_path,
             params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "UnknownSig111" },
             as: :json
      end

      assert_response :unprocessable_entity
      ramp.reload
      assert ramp.cdp_created?, "an unverified signature must not advance the row"
      assert_nil ramp.sent_signature
    end
  end

  test "sent rejects a confirmed tx that was NOT signed by the ramp's wallet" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      foreign_tx = {
        "meta" => { "err" => nil },
        "transaction" => {
          "message" => {
            "header" => { "numRequiredSignatures" => 1 },
            "accountKeys" => [Solana::Keypair.generate.address, ramp.wallet_address]
          }
        }
      }
      fake_client = FakeSolanaClient.new({}, transactions: { "ForeignSig111" => foreign_tx })
      stub_solana_client(fake_client) do
        post cdp_offramp_sent_path,
             params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "ForeignSig111" },
             as: :json
      end

      assert_response :unprocessable_entity
      assert_match(/not signed by/, JSON.parse(response.body)["error"])
      assert ramp.reload.cdp_created?
    end
  end

  test "sent rejects managed-mode ramps (server owns that send)" do
    with_cdp_ramp do
      ramp = create_ramp # web2
      log_in_as @user

      post cdp_offramp_sent_path,
           params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "MockTxSignature_x" },
           as: :json
      assert_response :unprocessable_entity
    end
  end

  # ── cosign_send (Phantom, house pays the fee) ──────────────────────────────
  #
  # phantom-cashout-needs-sol: the cash-out wire names the HOUSE as fee payer,
  # so Phantom's signature alone does not make it broadcastable. These pin the
  # hop that fills the admin slot — and the guard that keeps the house's
  # signature from being spent on anything but this cash-out.

  test "cosign_send validates against the server's OWN destination and amount, then cosigns" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_cosign_send_path,
               params: { partner_user_ref: ramp.partner_user_ref, signed_tx: "PHANTOM_SIGNED_WIRE" },
               as: :json
        end
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "COSIGNED_PHANTOM_SIGNED_WIRE", body["signed_tx"]
      assert_equal "FakeOfframpSendSig", body["tx_signature"]

      guard = vault.offramp_cosign_guard_calls.first
      assert_equal "PHANTOM_SIGNED_WIRE", guard[:wire]
      assert_equal ramp.wallet_address, guard[:wallet]
      assert_equal @to_address, guard[:destination],
                   "the destination is re-resolved server-side, never read off the request"
      assert_equal 19_000_000, guard[:amount],
                   "the amount comes from the ramp row, never from the client"

      ramp.reload
      assert ramp.sending?, "the row leaves cdp_created the moment the house signs (one cosign per row)"
      assert_equal "FakeOfframpSendSig", ramp.sent_signature,
                   "the signature is persisted BEFORE the signed bytes leave the server"
    end
  end

  test "cosign_send refuses a wire the guard rejects, and says nothing about why" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      vault.offramp_cosign_raises = "token_accounts_mismatch: ix 0 accounts=attacker..."
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_cosign_send_path,
               params: { partner_user_ref: ramp.partner_user_ref, signed_tx: "TAMPERED" },
               as: :json
        end
      end

      assert_response :unprocessable_entity
      error = JSON.parse(response.body)["error"]
      assert_match(/didn't match your cash-out/, error)
      assert_no_match(/token_accounts_mismatch/, error,
                      "the guard's forensic reason is logged server-side, never returned")
      assert_empty vault.offramp_cosign_calls, "validate-then-cosign: nothing is signed on reject"
      assert ramp.reload.cdp_created?, "a rejected wire must not advance the row"
    end
  end

  test "cosign_send refuses a SECOND cosign once the first send landed on-chain" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3", status: "sending", sent_signature: "LandedSig111")
      log_in_as @user

      landed = { "meta" => { "err" => nil }, "transaction" => { "message" => {} } }
      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info },
                                             transactions: { "LandedSig111" => landed })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_cosign_send_path,
               params: { partner_user_ref: ramp.partner_user_ref, signed_tx: "SECOND_WIRE" },
               as: :json
        end
      end

      assert_response :unprocessable_entity
      assert_match(/already sent/, JSON.parse(response.body)["error"])
      assert_empty vault.offramp_cosign_calls,
                   "the house must not fund a second transfer for a cash-out that already sent"
      assert_equal "LandedSig111", ramp.reload.sent_signature
    end
  end

  test "cosign_send RE-ARMS when the recorded send never landed" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3", status: "sending", sent_signature: "NeverLanded111")
      log_in_as @user

      # get_transaction → nil: the browser never managed to broadcast.
      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_cosign_send_path,
               params: { partner_user_ref: ramp.partner_user_ref, signed_tx: "RETRY_WIRE" },
               as: :json
        end
      end

      assert_response :success
      assert_equal ["RETRY_WIRE"], vault.offramp_cosign_calls
      assert ramp.reload.sending?
      assert_equal "FakeOfframpSendSig", ramp.sent_signature, "the dead signature is replaced, not kept"
    end
  end

  test "sent still accepts the wallet now that it sits in signer slot 1 behind the house" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3")
      log_in_as @user

      # The post-fix shape: two signers, house at 0 (fee payer), wallet at 1.
      house_paid = {
        "meta" => { "err" => nil },
        "transaction" => {
          "message" => {
            "header" => { "numRequiredSignatures" => 2 },
            "accountKeys" => [Solana::Keypair.admin.address, ramp.wallet_address]
          }
        }
      }
      fake_client = FakeSolanaClient.new({}, transactions: { "HousePaidSig111" => house_paid })
      stub_solana_client(fake_client) do
        post cdp_offramp_sent_path,
             params: { partner_user_ref: ramp.partner_user_ref, tx_signature: "HousePaidSig111" },
             as: :json
      end

      assert_response :success
      assert ramp.reload.sent?
      assert_equal "HousePaidSig111", ramp.sent_signature
    end
  end

  # ── the $0.99 withdrawal floor ─────────────────────────────────────────────

  test "prepare_send refuses a withdrawal below the $0.99 floor, naming the floor" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3", sell_amount_value: BigDecimal("0.40"))
      log_in_as @user

      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_prepare_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
        end
      end

      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_match(/Minimum withdrawal is \$0\.99/, body["error"],
                   "someone with $0.40 stuck must read a FLOOR, not a generic validation failure")
      assert_equal "0.99", body["minimum_usd"]
      assert_empty vault.offramp_unsigned_calls, "no transaction is built below the floor"
      assert_nil ramp.reload.confirmed_at, "a refused cash-out is not stamped as confirmed"
    end
  end

  test "confirm_send refuses a managed withdrawal below the $0.99 floor" do
    with_cdp_ramp do
      ramp = create_ramp(sell_amount_value: BigDecimal("0.40")) # web2
      log_in_as @user

      post cdp_offramp_confirm_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json

      assert_response :unprocessable_entity
      assert_match(/Minimum withdrawal is \$0\.99/, JSON.parse(response.body)["error"])
      assert_empty enqueued_jobs.select { |j| j[:job] == Cdp::OfframpSendJob },
                   "the send job is never enqueued for a sub-floor cash-out"
      assert ramp.reload.cdp_created?
    end
  end

  test "a cash-out at exactly $0.99 is above the floor and proceeds" do
    with_cdp_ramp do
      ramp = create_ramp(wallet_mode: "web3", sell_amount_value: BigDecimal("0.99"))
      log_in_as @user

      fake_client = FakeSolanaClient.new({}, account_infos: { @to_address => token_account_info })
      vault = FakeVault.new
      stub_solana_client(fake_client) do
        Solana::Vault.stub :new, vault do
          post cdp_offramp_prepare_send_path, params: { partner_user_ref: ramp.partner_user_ref }, as: :json
        end
      end

      assert_response :success
      assert_equal 990_000, vault.offramp_unsigned_calls.first[:amount]
    end
  end
end
