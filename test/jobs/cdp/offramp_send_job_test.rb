require "test_helper"

# Cdp::OfframpSendJob — the managed-wallet (web2) server-signed USDC send
# (§10). Every guard is mandatory; the verify-before-retry path must settle a
# persisted signature on-chain before any re-send is even considered.
class Cdp::OfframpSendJobTest < ActiveJob::TestCase
  setup do
    @user = users(:jordan)
    # This job SIGNS from the custodial wallet, so the user must have one.
    # generate_managed_wallet! alone stopped providing it when web3-only
    # onboarding became the default (2026-08-15) — it returns early on the flag.
    grant_managed_wallet!(@user)
    @to_address = Solana::Keypair.generate.address
  end

  def create_ramp(**attrs)
    CdpRampTransaction.create!({
      user: @user,
      direction: "offramp",
      wallet_address: @user.web2_solana_address,
      wallet_mode: "web2",
      status: "cdp_created",
      to_address: @to_address,
      sell_amount_value: BigDecimal("19"),
      sell_amount_currency: "USDC",
      cashout_deadline_at: 25.minutes.from_now,
      confirmed_at: Time.current
    }.merge(attrs))
  end

  # Full get_account_info envelope (FakeSolanaClient returns account_infos
  # values verbatim, mirroring the real RPC's { "value" => ... } shape).
  def token_account_info(mint: Solana::Config::USDC_MINT)
    mint_bytes = Solana::Keypair.decode_base58(mint)
    { "value" => {
      "owner" => Cdp::OfframpDestination::TOKEN_PROGRAM_ID_B58,
      "data" => [Base64.strict_encode64(mint_bytes + ("\x00" * 133).b), "base64"]
    } }
  end

  # Vault fake wired so the destination resolves (to_address is a USDC token
  # account) and the balance covers a $19 sell by default.
  def fake_vault(usdc_balance: 100, account_infos: nil, signature_statuses: {}, send_raises: nil)
    FakeVault.new(
      usdc_balance: usdc_balance,
      account_infos: account_infos || { @to_address => token_account_info },
      signature_statuses: signature_statuses,
      send_raises: send_raises
    )
  end

  def perform_with(vault, ramp)
    Solana::Vault.stub :new, vault do
      Cdp::OfframpSendJob.perform_now(ramp_id: ramp.id)
    end
  end

  test "happy path: builds, persists the signature as sending, broadcasts, schedules verify" do
    ramp = create_ramp
    vault = fake_vault

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.sending?
    assert_equal "FakeOfframpSendSig", ramp.sent_signature
    assert ramp.broadcast_at.present?, "mark_sending! must stamp the broadcast-attempt time"
    assert_in_delta Time.current.to_f, ramp.broadcast_at.to_f, 5
    assert_equal 1, vault.offramp_build_calls.length
    assert_equal 19_000_000, vault.offramp_build_calls.first[:amount]
    assert_equal @to_address, vault.offramp_build_calls.first[:destination]
    assert_equal 1, vault.client.sent_transactions.length

    verify = enqueued_jobs.find { |j| j[:job] == Cdp::OfframpSendJob }
    assert verify, "expected a verify re-enqueue"
    assert_equal ramp.id, verify[:args].first["ramp_id"]
    assert verify[:at].present?, "verify must wait, not run immediately"
  end

  test "refuses without a user confirmation" do
    ramp = create_ramp(confirmed_at: nil)
    vault = fake_vault

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_nil ramp.sent_signature
    assert_empty vault.offramp_build_calls
    assert_empty vault.client.sent_transactions
  end

  test "refuses a STALE confirmation (older than the TTL)" do
    ramp = create_ramp(confirmed_at: 11.minutes.ago)
    vault = fake_vault

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_empty vault.client.sent_transactions
  end

  test "refuses past the cashout deadline safety margin" do
    ramp = create_ramp(cashout_deadline_at: 2.minutes.from_now)
    vault = fake_vault

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_empty vault.offramp_build_calls
    assert_empty vault.client.sent_transactions
  end

  test "refuses with no cashout deadline at all (fail closed)" do
    ramp = create_ramp(cashout_deadline_at: nil)
    vault = fake_vault

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_empty vault.client.sent_transactions
  end

  test "refuses when the user's USDC balance doesn't cover the sell" do
    ramp = create_ramp # $19 sell
    vault = fake_vault(usdc_balance: 5)

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_empty vault.offramp_build_calls
    assert_empty vault.client.sent_transactions
  end

  test "treats an unreadable balance as a hard block, never a pass" do
    ramp = create_ramp
    vault = FakeVault.new(
      usdc_balance_raises: true,
      account_infos: { @to_address => token_account_info }
    )

    perform_with(vault, ramp)

    assert ramp.reload.cdp_created?
    assert_empty vault.client.sent_transactions
  end

  test "an unresolvable destination is captured to ErrorLog and never sends" do
    ramp = create_ramp
    vault = fake_vault(account_infos: {}) # neither shape exists on-chain

    assert_difference "ErrorLog.count", 1 do
      perform_with(vault, ramp)
    end

    assert ramp.reload.cdp_created?
    assert_empty vault.offramp_build_calls
    assert_empty vault.client.sent_transactions
  end

  test "refuses non-cdp_created statuses and the wrong wallet mode" do
    vault = fake_vault

    early = create_ramp(status: "returned")
    perform_with(vault, early)
    assert early.reload.returned?

    web3 = create_ramp(status: "cdp_created", wallet_mode: "web3",
                       wallet_address: Solana::Keypair.generate.address)
    perform_with(vault, web3)
    assert web3.reload.cdp_created?

    assert_empty vault.client.sent_transactions
  end

  test "signature is persisted even when the broadcast itself faults (then verifies, never blind-resends)" do
    ramp = create_ramp
    vault = fake_vault(send_raises: "network blip mid-broadcast")

    assert_difference "ErrorLog.count", 1 do
      perform_with(vault, ramp)
    end

    ramp.reload
    assert ramp.sending?, "status must reach sending despite the broadcast fault"
    assert_equal "FakeOfframpSendSig", ramp.sent_signature, "signature persisted BEFORE the broadcast completed"
    assert enqueued_jobs.any? { |j| j[:job] == Cdp::OfframpSendJob }, "verify re-enqueued"
  end

  # ── Verify-before-retry ────────────────────────────────────────────────────

  test "verify path: a confirmed signature flips sending to sent without any re-send" do
    ramp = create_ramp(status: "sending", sent_signature: "SigX")
    vault = fake_vault(signature_statuses: { "SigX" => { "err" => nil, "confirmationStatus" => "confirmed" } })

    perform_with(vault, ramp)

    assert ramp.reload.sent?
    assert_equal "SigX", ramp.sent_signature
    assert_empty vault.offramp_build_calls, "must not rebuild"
    assert_empty vault.client.sent_transactions, "must not re-send"
  end

  test "verify path: an AMBIGUOUS status re-verifies later and never re-sends" do
    ramp = create_ramp(status: "sending", sent_signature: "SigX")
    vault = fake_vault # no status for SigX

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.sending?, "ambiguous result must not change state"
    assert_equal "SigX", ramp.sent_signature
    assert_empty vault.client.sent_transactions
    verify = enqueued_jobs.find { |j| j[:job] == Cdp::OfframpSendJob }
    assert verify, "expected an ambiguous-result re-verify"
  end

  test "verify path: a DEFINITIVE on-chain failure resets for a fresh re-guarded attempt" do
    ramp = create_ramp(status: "sending", sent_signature: "SigX", broadcast_at: 30.seconds.ago)
    vault = fake_vault(
      signature_statuses: { "SigX" => { "err" => { "InstructionError" => [0, "Custom"] }, "confirmationStatus" => "confirmed" } }
    )

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.cdp_created?, "verified-failed send rewinds to cdp_created"
    assert_nil ramp.sent_signature
    assert_nil ramp.broadcast_at, "the dead attempt's broadcast anchor is cleared with it"
    assert_empty vault.client.sent_transactions, "the rerun is a NEW job, re-guarded — nothing sent now"
    assert enqueued_jobs.any? { |j| j[:job] == Cdp::OfframpSendJob }, "fresh attempt enqueued"
  end

  test "verify path: a signature absent past the blockhash window (anchored on BROADCAST time) is verified-dead and reset" do
    ramp = create_ramp(status: "sending", sent_signature: "SigX",
                       confirmed_at: 6.minutes.ago, broadcast_at: 6.minutes.ago)
    vault = fake_vault # signature never appears

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.cdp_created?
    assert_nil ramp.sent_signature
    assert_empty vault.client.sent_transactions
  end

  test "verify path: an old confirmed_at with a FRESH broadcast is ambiguous — never reset (double-send window)" do
    # The dangerous case: guard-phase retries / queue latency put the first
    # broadcast minutes after the confirmation click. 15s later the RPC
    # hasn't indexed the signature yet — a confirmed_at-anchored lapse check
    # would declare it verified-dead and rebuild a SECOND tx while the first
    # is still inside its blockhash validity. Both land = double USDC send.
    ramp = create_ramp(status: "sending", sent_signature: "SigX",
                       confirmed_at: 6.minutes.ago, broadcast_at: 15.seconds.ago)
    vault = fake_vault # status not yet indexed (routine RPC lag)

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.sending?, "a just-broadcast tx must NOT be declared verified-dead"
    assert_equal "SigX", ramp.sent_signature
    assert_empty vault.offramp_build_calls, "must not rebuild"
    assert_empty vault.client.sent_transactions, "must not re-send"
    assert enqueued_jobs.any? { |j| j[:job] == Cdp::OfframpSendJob }, "re-verify scheduled"
  end

  test "verify path: a missing broadcast_at anchor is never verified-dead (fails ambiguous)" do
    ramp = create_ramp(status: "sending", sent_signature: "SigX", confirmed_at: 6.minutes.ago)
    vault = fake_vault # signature absent AND no broadcast anchor

    perform_with(vault, ramp)

    ramp.reload
    assert ramp.sending?, "no anchor = ambiguous, not dead"
    assert_equal "SigX", ramp.sent_signature
    assert_empty vault.client.sent_transactions
  end

  test "no-ops on missing, sent, and terminal rows" do
    vault = fake_vault

    perform_with(vault, create_ramp(status: "sent", sent_signature: "Done"))
    perform_with(vault, create_ramp(status: "failed"))
    Solana::Vault.stub :new, vault do
      Cdp::OfframpSendJob.perform_now(ramp_id: -1)
    end

    assert_empty vault.offramp_build_calls
    assert_empty vault.client.sent_transactions
  end
end
