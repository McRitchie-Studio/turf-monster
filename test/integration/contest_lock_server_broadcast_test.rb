require "test_helper"

# [integration] THE LOCK FLOW END TO END, SERVER-BROADCAST
# (server-broadcasts-contest-lock).
#
# Production 2026-10-03: "Set lock time with Phantom" on the admin contest edit
# page died with `403 Access forbidden`, because lock_contest.js broadcast the
# signed transaction from the browser and on mainnet the browser can only reach
# the free public RPC. The flow is now: prepare_lock_time builds the wire with
# the house's fee-payer slot EMPTY; Phantom signs its own slot; the page POSTs
# the signed wire to confirm_lock_time; the server judges it, house-signs,
# simulates, broadcasts over ITS client, confirms, verifies what landed, and
# mirrors starts_at.
#
# This drives the REAL Solana::Vault and the REAL Cosign::Completer through the
# controller — only the RPC (a recorder) and the post-landing chain read
# (TxVerifier) are stubbed. The controller tests go through FakeVault and never
# reach the wire; the vault unit tests never reach the controller. This is the
# seam between them, for both set and clear.
class ContestLockServerBroadcastTest < ActionDispatch::IntegrationTest
  class RecordingRpc
    attr_reader :sent_wires

    def initialize
      @sent_wires = []
      @blockhash = Solana::Keypair.generate.to_base58
      CosignFakeClient.teach(self)
    end

    def get_latest_blockhash(**_opts) = @blockhash
    def get_block_height(**_opts) = 1
    def simulate_transaction(_wire, **_opts) = { "err" => nil, "logs" => [] }

    def send_transaction(wire, **_opts)
      @sent_wires << wire
      nil
    end

    def confirm_transaction(_signature)
      { "value" => [{ "err" => nil, "confirmationStatus" => "confirmed" }] }
    end
  end

  setup do
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_srv_#{SecureRandom.hex(4)}", season_id: 1,
                     starts_at: 1.hour.from_now)
    SeasonConfig.set_current!(1)
    @admin = users(:alex)
    # The operator's Phantom key: log_in_as_onchain links it to the admin and
    # hands it back, so this test can sign exactly as Phantom would.
    @phantom = Solana::Keypair.new(log_in_as_onchain(@admin))
    @rpc = RecordingRpc.new
    @vault = Solana::Vault.new(client: @rpc)
    @vault.define_singleton_method(:cosign_completer) do
      Solana::Cosign::Completer.new(client: client, fee_payer: Solana::Keypair.admin,
                                    poll_interval: 0, sleeper: ->(_s) { })
    end
    @verified = []
  end

  # prepare -> Phantom signs -> confirm, against the real vault.
  def run_flow(prepare_params, ts_from_prepare: true)
    Solana::Vault.stub :new, @vault do
      post prepare_lock_time_contest_path(@contest), params: prepare_params, as: :json
      assert_response :success, response.body
      prep = JSON.parse(response.body)

      unsigned = Solana::WireMessage.parse(Base64.strict_decode64(prep["serialized_tx"]))
      assert unsigned.signature_slot_empty?(0),
             "the page must never hold a wire it could broadcast — the house signs only on confirm"

      signed = Solana::Transaction.cosign_wire_base64(prep["serialized_tx"], signer: @phantom,
                                                                             require_complete: false)
      verifier = ->(**kw) { @verified << kw; true }
      Solana::TxVerifier.stub :verify!, verifier do
        post confirm_lock_time_contest_path(@contest),
             params: { signed_tx: signed, lock_timestamp: yield(prep) }, as: :json
      end
    end
    JSON.parse(response.body)
  end

  test "LOCK: the page posts the signed wire and the server broadcasts, confirms and mirrors starts_at" do
    lock_at = 3.days.from_now.to_i
    body = run_flow({ lock_timestamp: lock_at }) { |prep| prep["lock_timestamp"] }

    assert_response :success, body.inspect
    assert_equal 1, @rpc.sent_wires.length, "the SERVER's client sent it — once"
    sent = @rpc.sent_wires.first
    assert_equal @vault.signature_for_wire(sent), body["tx_signature"]
    refute Solana::WireMessage.parse(Base64.strict_decode64(sent)).signature_slot_empty?(0),
           "the house filled the fee payer's slot"
    assert_equal "set_contest_lock_time", @verified.first[:instruction_name]
    assert_equal @phantom.address, @verified.first[:signer_pubkey]
    assert_equal lock_at, @contest.reload.starts_at.to_i
  end

  test "CLEAR: lock_timestamp 0 rides the same server broadcast and re-opens entries" do
    body = run_flow({ lock_timestamp: 0 }) { |prep| prep["lock_timestamp"] }

    assert_response :success, body.inspect
    assert_equal 1, @rpc.sent_wires.length
    assert_nil @contest.reload.starts_at
  end

  test "a confirm that names a DIFFERENT time than the signed wire is refused and nothing is sent" do
    original = @contest.reload.starts_at
    body = run_flow({ lock_timestamp: 3.days.from_now.to_i }) { |prep| prep["lock_timestamp"] + 86_400 }

    assert_response :unprocessable_entity
    assert_match(/did not match what this server prepared/, body["error"])
    assert_empty @rpc.sent_wires
    assert_empty @verified
    assert_equal original.to_i, @contest.reload.starts_at.to_i
  end

  # The page half of the contract. lock_contest.js must post the signed wire
  # and must not broadcast — the 403 came from the page calling the RPC itself.
  test "lock_contest.js posts signed_tx and never broadcasts from the browser" do
    src = File.read(Rails.root.join("app/javascript/lock_contest.js"))
    code = src.lines.reject { |l| l.strip.start_with?("//") }.join

    refute_match(/sendRawTransaction|sendTransaction\(|new solanaWeb3\.Connection|pollConfirmation/, code)
    assert_match(/signed_tx:\s*signedB64/, code)
    assert_match(/requireAllSignatures:\s*false/, code,
                 "the fee payer's slot is empty until the server fills it; a strict serialize throws after the operator approved")
  end
end
