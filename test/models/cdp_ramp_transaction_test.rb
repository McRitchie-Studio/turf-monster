require "test_helper"

class CdpRampTransactionTest < ActiveSupport::TestCase
  def build_ramp(attrs = {})
    CdpRampTransaction.new({
      user: users(:alex),
      direction: "onramp",
      wallet_address: "So1anaPubkey111",
      wallet_mode: "web3"
    }.merge(attrs))
  end

  test "valid with defaults: initiated status, USDC asset, solana network" do
    ramp = build_ramp
    assert ramp.valid?
    assert ramp.initiated?
    assert_equal "USDC", ramp.asset
    assert_equal "solana", ramp.network
  end

  test "assigns partner_user_ref tm-<user_id>-<id> after create" do
    ramp = build_ramp
    ramp.save!
    assert_equal "tm-#{ramp.user_id}-#{ramp.id}", ramp.partner_user_ref
    assert ramp.partner_user_ref.length < 50
  end

  test "does not clobber a preset partner_user_ref" do
    ramp = build_ramp(partner_user_ref: "custom-ref")
    ramp.save!
    assert_equal "custom-ref", ramp.partner_user_ref
  end

  test "partner_user_ref must be unique and under 50 chars" do
    build_ramp(partner_user_ref: "dup-ref").save!
    dup = build_ramp(partner_user_ref: "dup-ref")
    assert_not dup.valid?
    assert dup.errors[:partner_user_ref].any?

    long = build_ramp(partner_user_ref: "x" * 50)
    assert_not long.valid?
  end

  test "requires direction, wallet_address, and wallet_mode" do
    assert_not build_ramp(wallet_address: nil).valid?
    assert_not build_ramp(wallet_mode: nil).valid?
    assert_raises(ArgumentError) { build_ramp(direction: "sideways") }
  end

  test "status enum covers the local lifecycle and rejects unknown values" do
    ramp = build_ramp
    %w[initiated token_minted returned cdp_created sending sent success failed expired abandoned].each do |status|
      ramp.status = status
      assert ramp.valid?, "expected #{status} to be a valid status"
    end
    assert_raises(ArgumentError) { ramp.status = "locked" }
  end

  test "terminal? is true only for success/failed/expired/abandoned" do
    ramp = build_ramp
    %w[success failed expired abandoned].each do |status|
      ramp.status = status
      assert ramp.terminal?, "#{status} should be terminal"
    end
    %w[initiated token_minted returned cdp_created sending sent].each do |status|
      ramp.status = status
      assert_not ramp.terminal?, "#{status} should not be terminal"
    end
  end

  test "coinbase_transaction_id is unique when present, multiple nils allowed" do
    build_ramp.save!
    build_ramp.save! # second nil coinbase_transaction_id is fine

    build_ramp(coinbase_transaction_id: "cb-tx-1").save!
    dup = build_ramp(coinbase_transaction_id: "cb-tx-1")
    assert_not dup.valid?
  end

  test "sell_amount returns a BigDecimal, never a Float" do
    ramp = build_ramp(direction: "offramp", sell_amount_value: "25.000001", sell_amount_currency: "USDC")
    ramp.save!
    assert_instance_of BigDecimal, ramp.sell_amount
    assert_equal BigDecimal("25.000001"), ramp.sell_amount

    assert_nil build_ramp.sell_amount
  end

  test "wallet_mode enum distinguishes managed (web2) from Phantom (web3)" do
    assert build_ramp(wallet_mode: "web2").wallet_web2?
    assert build_ramp(wallet_mode: "web3").wallet_web3?
  end

  test "active scope excludes terminal rows" do
    live = build_ramp.tap(&:save!)
    done = build_ramp(status: "success").tap(&:save!)
    assert_includes CdpRampTransaction.active, live
    assert_not_includes CdpRampTransaction.active, done
  end

  test "slug reads partner_user_ref (ErrorLog target compatibility)" do
    ramp = build_ramp.tap(&:save!)
    assert_equal ramp.partner_user_ref, ramp.slug
  end

  # ── State transitions ──────────────────────────────────────────────────────

  test "mark_token_minted! advances only from initiated" do
    ramp = build_ramp.tap(&:save!)
    assert ramp.mark_token_minted!
    assert ramp.token_minted?
    assert_not ramp.mark_token_minted!, "second call is a refused no-op"
  end

  test "mark_returned! stamps returned_at once and never rewinds the lifecycle" do
    ramp = build_ramp(status: "token_minted").tap(&:save!)
    assert ramp.mark_returned!
    assert ramp.returned?
    first_returned_at = ramp.returned_at
    assert first_returned_at.present?

    travel_to 5.minutes.from_now do
      assert ramp.mark_returned! # revisit — idempotent
      assert_equal first_returned_at.to_i, ramp.returned_at.to_i
    end

    ramp.update!(status: "cdp_created")
    assert ramp.mark_returned!
    assert ramp.cdp_created?, "a return hit must not downgrade cdp_created"

    ramp.update!(status: "success")
    assert_not ramp.mark_returned!, "terminal rows refuse the transition"
  end

  test "mark_cdp_created! advances only from pre-CDP statuses" do
    %w[initiated token_minted returned].each do |status|
      ramp = build_ramp(status: status).tap(&:save!)
      assert ramp.mark_cdp_created!, "#{status} → cdp_created should be allowed"
      assert ramp.cdp_created?
    end

    %w[sending sent success].each do |status|
      ramp = build_ramp(status: status).tap(&:save!)
      assert_not ramp.mark_cdp_created!, "#{status} must not rewind to cdp_created"
      assert_equal status, ramp.status
    end
  end

  test "mark_success!/mark_failed!/mark_expired! refuse to flip an already-terminal row" do
    ramp = build_ramp(status: "sent").tap(&:save!)
    assert ramp.mark_success!
    assert ramp.success?
    assert_not ramp.mark_failed!
    assert_not ramp.mark_expired!
    assert ramp.success?, "terminal states never overwrite each other"
  end

  test "mark_sending! persists the signature with the status flip, only from cdp_created" do
    ramp = build_ramp(direction: "offramp", status: "cdp_created").tap(&:save!)
    assert ramp.mark_sending!("Sig111")
    assert ramp.sending?
    assert_equal "Sig111", ramp.sent_signature
    assert ramp.broadcast_at.present?, "stamps the broadcast-attempt time (the blockhash-lapse anchor)"
    assert_in_delta Time.current.to_f, ramp.broadcast_at.to_f, 5

    first_broadcast_at = ramp.broadcast_at
    assert ramp.mark_sending!("Sig111"), "same-signature retry is an idempotent yes"
    assert_equal first_broadcast_at, ramp.broadcast_at, "an idempotent retry must not move the broadcast anchor"
    assert_not ramp.mark_sending!("Sig222"), "a different signature must not overwrite an in-flight send"
    assert_equal "Sig111", ramp.sent_signature

    fresh = build_ramp(direction: "offramp", status: "returned").tap(&:save!)
    assert_not fresh.mark_sending!("SigX"), "no send before cdp_created"
    assert_not fresh.mark_sending!(nil), "blank signature refused"
  end

  test "mark_sent! advances from sending or cdp_created and protects the recorded signature" do
    managed = build_ramp(direction: "offramp", status: "sending", sent_signature: "Sig111").tap(&:save!)
    assert managed.mark_sent!
    assert managed.sent?
    assert_equal "Sig111", managed.sent_signature
    assert managed.mark_sent!, "idempotent"
    assert_not managed.mark_sent!("Other"), "refuses to overwrite a different signature"

    phantom = build_ramp(direction: "offramp", status: "cdp_created").tap(&:save!)
    assert phantom.mark_sent!("ClientSig"), "Phantom mode reports straight from cdp_created"
    assert phantom.sent?
    assert_equal "ClientSig", phantom.sent_signature

    early = build_ramp(direction: "offramp", status: "returned").tap(&:save!)
    assert_not early.mark_sent!("SigX")
  end

  test "reset_failed_send! is the one deliberate rewind — sending only" do
    ramp = build_ramp(direction: "offramp", status: "sending",
                      sent_signature: "DeadSig", broadcast_at: 6.minutes.ago).tap(&:save!)
    assert ramp.reset_failed_send!
    assert ramp.cdp_created?
    assert_nil ramp.sent_signature
    assert_nil ramp.broadcast_at, "the dead attempt's broadcast anchor goes with it"

    sent = build_ramp(direction: "offramp", status: "sent", sent_signature: "GoodSig").tap(&:save!)
    assert_not sent.reset_failed_send!, "a confirmed send can never be reset"
    assert sent.sent?
  end

  # THE VERDICT THAT DECIDES A REWIND — and a wrong rewind sends a player's
  # USDC twice. Shared by Cdp::OfframpSendJob#verify_pending_send and
  # Cdp::OfframpSendsController#cosign, so it is pinned here once.

  def sending_ramp(broadcast_at:)
    ramp = CdpRampTransaction.create!(
      user: users(:jordan), direction: "offramp", wallet_mode: "web3",
      wallet_address: Solana::Keypair.generate.address, status: "cdp_created",
      to_address: Solana::Keypair.generate.address,
      sell_amount_value: BigDecimal("19"), sell_amount_currency: "USDC",
      cashout_deadline_at: 25.minutes.from_now
    )
    ramp.mark_sending!("SigUnderTest")
    ramp.update!(broadcast_at: broadcast_at)
    ramp
  end

  test "send_verdict calls a confirmed status landed" do
    ramp = sending_ramp(broadcast_at: 1.minute.ago)
    status = { "err" => nil, "confirmationStatus" => "confirmed" }
    assert_equal :landed, ramp.send_verdict(status)
    assert_equal :landed, ramp.send_verdict(status.merge("confirmationStatus" => "finalized"))
  end

  test "send_verdict calls an on-chain err failed, whatever its age" do
    assert_equal :failed, sending_ramp(broadcast_at: 1.minute.ago).send_verdict({ "err" => { "InstructionError" => 1 } })
    assert_equal :failed, sending_ramp(broadcast_at: 1.hour.ago).send_verdict({ "err" => { "InstructionError" => 1 } })
  end

  test "send_verdict calls a MISSING status AMBIGUOUS inside the blockhash window" do
    ramp = sending_ramp(broadcast_at: 30.seconds.ago)

    assert_equal :ambiguous, ramp.send_verdict(nil),
                 "a signature absent from getSignatureStatuses is in-flight or unindexed just as " \
                 "often as it is dead — rewinding on it builds a SECOND full-amount transfer and " \
                 "sends the player's USDC twice"
  end

  test "send_verdict calls a missing status never_landed only past the blockhash window" do
    assert_equal :ambiguous, sending_ramp(broadcast_at: (CdpRampTransaction::BLOCKHASH_LAPSE - 10.seconds).ago).send_verdict(nil)
    assert_equal :never_landed, sending_ramp(broadcast_at: (CdpRampTransaction::BLOCKHASH_LAPSE + 10.seconds).ago).send_verdict(nil)
  end

  test "send_verdict is ambiguous with no broadcast anchor at all" do
    ramp = sending_ramp(broadcast_at: 1.hour.ago)
    ramp.update!(broadcast_at: nil)

    assert_equal :ambiguous, ramp.send_verdict(nil),
                 "no anchor cannot prove deadness, so it must never read as verified-dead"
  end

  test "send_verdict is ambiguous for a processed-but-unconfirmed status" do
    ramp = sending_ramp(broadcast_at: 1.hour.ago)
    assert_equal :ambiguous, ramp.send_verdict({ "err" => nil, "confirmationStatus" => "processed" })
  end
end
