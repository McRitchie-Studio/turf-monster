require "test_helper"
require "minitest/mock"

class TokenPurchaseJobTest < ActiveJob::TestCase
  # Minimal Vault stand-in. Tracks mint_entry_token calls and can simulate a
  # mid-loop failure. The job resumes from `StripePurchase.tx_signatures`
  # (the DB row is the source of truth), so we don't need to fake on-chain
  # state to test the resume path — we pre-populate the DB row instead.
  class FakeVault
    attr_reader :mint_calls

    def initialize(fail_after: nil, starting_sequence: 0)
      @fail_after = fail_after
      @starting_sequence = starting_sequence
      @mint_calls = []
    end

    # Retained for backwards compatibility with any callers still asking for
    # on-chain state. The current job no longer relies on this — see
    # OPSEC-009 comment block in TokenPurchaseJob.
    def list_entry_tokens(_wallet, **_opts)
      []
    end

    def next_entry_token_sequence(_wallet)
      @starting_sequence + @mint_calls.length
    end

    def mint_entry_token(wallet_address:, source:, source_ref:, **_opts)
      @mint_calls << source_ref
      raise StandardError, "simulated chain failure" if @fail_after && @mint_calls.length > @fail_after
      seq = @starting_sequence + @mint_calls.length - 1
      { signature: "sig_#{seq}_#{SecureRandom.hex(2)}", pda: "pda-seq-#{seq}", sequence: seq }
    end
  end

  setup do
    @user = users(:alex)
    @user.update!(web2_solana_address: "TestWallet#{SecureRandom.hex(2)}", encrypted_web2_solana_private_key: "x")
    @wallet = @user.solana_address
    @sid = "cs_test_partial_#{SecureRandom.hex(4)}"
  end

  test "happy path mints all N tokens and writes a minted StripePurchase + TransactionLog" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid)
    end

    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length
    assert_equal 3, vault.mint_calls.length
    # source_ref is "stripe:<purchase_id>:<index>" — short enough to fit the
    # on-chain [u8;64] AND distinct per token. Regression: the old
    # "stripe:<66-char-session>:<i>" overflowed 64 bytes, truncating the ":#{i}"
    # so all three trio tokens hashed to one PDA and collided on init (0x0).
    assert vault.mint_calls.all? { |r| r.start_with?("stripe:#{purchase.id}:") }, "ref keyed on purchase id"
    assert_equal 3, vault.mint_calls.uniq.length, "each token gets a DISTINCT source_ref"
    assert vault.mint_calls.all? { |r| r.bytesize <= 64 }, "each source_ref fits the on-chain [u8;64]"
    assert TransactionLog.where("metadata @> ?", { stripe_session_id: @sid }.to_json).exists?
  end

  test "partial-failure resume: starts at already_minted, mints only the remaining tokens" do
    # Simulate a previous run that minted indices 0 and 1 and persisted their
    # signatures to the DB before crashing on index 2. The retry should resume
    # at i=2 (already_minted == 2) and mint only the one remaining token.
    sp = StripePurchase.create!(
      user: @user,
      stripe_session_id: @sid,
      quantity: 3,
      price_cents: 49_00,
      status: "failed",
      mint_tx_signatures: ["prev_sig_0", "prev_sig_1"].to_json
    )
    vault = FakeVault.new(starting_sequence: 2)
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid)
    end

    # Only the 3rd iteration should have hit the chain on this retry.
    assert_equal 1, vault.mint_calls.length
    assert_equal "stripe:#{sp.id}:2", vault.mint_calls.first

    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    # All three signatures (2 preserved from before + 1 new) form the final audit trail.
    assert_equal 3, purchase.tx_signatures.length
    assert_equal "prev_sig_0", purchase.tx_signatures[0]
    assert_equal "prev_sig_1", purchase.tx_signatures[1]
    assert purchase.tx_signatures[2].start_with?("sig_2_")
  end

  test "mid-loop failure persists captured signatures and leaves StripePurchase in failed state" do
    vault = FakeVault.new(fail_after: 2) # mints 0 and 1, raises on 2
    # Don't assert on raise behaviour — ActiveJob's retry_on may swallow. The
    # contract we care about is the end-state: failed status + persisted sigs.
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid) rescue nil
    end
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "failed", purchase.status
    assert_equal 2, purchase.tx_signatures.length, "should have persisted the first two signatures before crash"
    assert_equal 3, vault.mint_calls.length, "should have attempted all three mints (the third raised)"
  end

  test "OPSEC-009: full failure + Sidekiq retry → final state has all 3 signatures, status minted" do
    # First run: vault fails on the 3rd mint. Verifies partial persistence.
    crashing_vault = FakeVault.new(fail_after: 2)
    Solana::Vault.stub :new, crashing_vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid) rescue nil
    end

    purchase = StripePurchase.for_session(@sid).first
    assert_equal "failed", purchase.status
    assert_equal 2, purchase.tx_signatures.length, "first run should persist sigs 0 and 1"
    first_run_sigs = purchase.tx_signatures.dup

    # Retry: a fresh vault (no fail_after) at sequence 2 to simulate the on-chain
    # state after the first run's two successful mints. The job should resume
    # from already_minted == 2 and mint only the third token.
    retry_vault = FakeVault.new(starting_sequence: 2)
    Solana::Vault.stub :new, retry_vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid)
    end

    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length, "final audit trail must include all 3 mint signatures"
    # The first two signatures from the original run are preserved verbatim.
    assert_equal first_run_sigs, purchase.tx_signatures[0..1]
    # The retry only attempted the third mint — not a re-mint of 0/1.
    assert_equal 1, retry_vault.mint_calls.length
    assert_equal "stripe:#{purchase.id}:2", retry_vault.mint_calls.first
    assert TransactionLog.where("metadata @> ?", { stripe_session_id: @sid }.to_json).exists?
  end

  test "OPSEC-009: retry on already-minted purchase no-ops (does not re-mint)" do
    # Pre-existing fully-minted purchase. A duplicate Sidekiq run (or a delayed
    # webhook retry) must NOT attempt any on-chain mint.
    StripePurchase.create!(
      user: @user,
      stripe_session_id: @sid,
      quantity: 3,
      price_cents: 49_00,
      status: "minted",
      mint_tx_signatures: %w[sig_a sig_b sig_c].to_json
    )
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet, stripe_session_id: @sid)
    end

    assert_equal 0, vault.mint_calls.length, "minted purchase must not trigger any on-chain calls"
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal %w[sig_a sig_b sig_c], purchase.tx_signatures, "existing signatures untouched"
  end

  test "skip when StripePurchase already minted" do
    StripePurchase.create!(user: @user, stripe_session_id: @sid, quantity: 1, price_cents: 19_00, status: "minted")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet, stripe_session_id: @sid)
    end
    assert_equal 0, vault.mint_calls.length, "should not attempt any mint on already-minted session"
  end

  test "resumes a previously-failed StripePurchase (status: failed → pending → minted)" do
    StripePurchase.create!(user: @user, stripe_session_id: @sid, quantity: 1, price_cents: 19_00, status: "failed")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet, stripe_session_id: @sid)
    end
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal 1, vault.mint_calls.length
  end

  test "bails on unknown user_id without creating a row" do
    Solana::Vault.stub :new, FakeVault.new do
      TokenPurchaseJob.perform_now(user_id: 999_999, pack_id: "single", wallet_address: "x", stripe_session_id: @sid)
    end
    assert_nil StripePurchase.for_session(@sid).first
  end

  # ── PayPal (purchase_type: "paypal") ────────────────────────────────────

  test "paypal: mints all N tokens against a captured PaypalPurchase" do
    purchase = create_paypal_purchase(order_id: "ORDER_JOB", pack_id: "trio", quantity: 3, price_cents: 49_00)
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_JOB")
    end

    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length
    # source_ref parity with stripe: "<provider>:<purchase_id>:<i>" — short,
    # distinct per token, fits the on-chain [u8;64].
    assert vault.mint_calls.all? { |r| r.start_with?("paypal:#{purchase.id}:") }, "ref keyed on provider + purchase id"
    assert_equal 3, vault.mint_calls.uniq.length
    assert vault.mint_calls.all? { |r| r.bytesize <= 64 }
    assert TransactionLog.where("metadata @> ?", { paypal_order_id: "ORDER_JOB" }.to_json).exists?
  end

  test "paypal: skips when no PaypalPurchase row exists — never creates one" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_MISSING")
    end
    assert_equal 0, vault.mint_calls.length
    assert_nil PaypalPurchase.for_order("ORDER_MISSING").first
  end

  test "paypal: refunded purchase short-circuits — never mints over refunded money" do
    # A PAYMENT.CAPTURE.REFUNDED processed while this job sat in the queue /
    # retry window leaves the row "refunded" at perform time. The job must
    # treat it as terminal like "minted" — minting here would hand on-chain
    # tokens to an account whose money already went back.
    purchase = create_paypal_purchase(order_id: "ORDER_REFUNDED")
    purchase.begin_fulfillment!(capture_id: "CAP_R")
    purchase.mark_refunded!(reason: "refund while queued")

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_REFUNDED")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal "refunded", purchase.reload.status, "refund is the authoritative terminal state"
  end

  test "paypal: already-minted purchase no-ops (OPSEC-009)" do
    purchase = create_paypal_purchase(order_id: "ORDER_NOOP")
    purchase.mark_minted!(["sig_a"])
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_NOOP")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal ["sig_a"], purchase.reload.tx_signatures
  end

  test "paypal: mid-loop failure persists signatures; retry resumes and re-marks captured" do
    purchase = create_paypal_purchase(order_id: "ORDER_RESUME", pack_id: "trio", quantity: 3, price_cents: 49_00)
    crashing_vault = FakeVault.new(fail_after: 2)
    Solana::Vault.stub :new, crashing_vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_RESUME") rescue nil
    end
    purchase.reload
    assert_equal "failed", purchase.status
    assert_equal 2, purchase.tx_signatures.length

    retry_vault = FakeVault.new(starting_sequence: 2)
    Solana::Vault.stub :new, retry_vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "trio", wallet_address: @wallet,
                                   purchase_type: "paypal", paypal_order_id: "ORDER_RESUME")
    end
    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 3, purchase.tx_signatures.length
    assert_equal 1, retry_vault.mint_calls.length
    assert_equal "paypal:#{purchase.id}:2", retry_vault.mint_calls.first
  end

  test "stripe compatibility default: omitting purchase_type keeps legacy webhook behavior" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet, stripe_session_id: @sid)
    end
    purchase = StripePurchase.for_session(@sid).first
    assert_equal "minted", purchase.status
    assert_equal "stripe:#{purchase.id}:0", vault.mint_calls.first
  end

  # ── Coinflow (purchase_type: "coinflow") ────────────────────────────────

  test "coinflow: mints 1 token against a captured CoinflowPurchase (buy-1)" do
    purchase = create_coinflow_purchase(reference: "coinflow_job")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "coinflow", coinflow_reference: "coinflow_job")
    end

    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 1, purchase.tx_signatures.length
    # source_ref parity: "<provider>:<purchase_id>:<i>" — short, distinct, fits [u8;64].
    assert_equal "coinflow:#{purchase.id}:0", vault.mint_calls.first
    assert vault.mint_calls.all? { |r| r.bytesize <= 64 }
    assert TransactionLog.where("metadata @> ?", { coinflow_reference: "coinflow_job" }.to_json).exists?
  end

  test "coinflow: skips when no CoinflowPurchase row exists — never creates one" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "coinflow", coinflow_reference: "coinflow_missing")
    end
    assert_equal 0, vault.mint_calls.length
    assert_nil CoinflowPurchase.for_reference("coinflow_missing").first
  end

  test "coinflow: refunded purchase short-circuits — never mints over refunded money" do
    purchase = create_coinflow_purchase(reference: "coinflow_refunded")
    purchase.mark_refunded!(reason: "refund while queued")

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "coinflow", coinflow_reference: "coinflow_refunded")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal "refunded", purchase.reload.status
  end

  test "coinflow: already-minted purchase no-ops (OPSEC-009)" do
    purchase = create_coinflow_purchase(reference: "coinflow_noop")
    purchase.mark_minted!(["sig_a"])
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "coinflow", coinflow_reference: "coinflow_noop")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal ["sig_a"], purchase.reload.tx_signatures
  end

  test "coinflow: a failed row is restored to captured and resumes on retry" do
    # Simulate a prior run that failed (status flipped to failed by the rescue).
    # The retry must re-mark it captured and mint the one token.
    purchase = create_coinflow_purchase(reference: "coinflow_resume")
    purchase.update!(status: "failed")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "coinflow", coinflow_reference: "coinflow_resume")
    end
    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 1, vault.mint_calls.length
    assert_equal "coinflow:#{purchase.id}:0", vault.mint_calls.first
  end

  # ── Aeropay (purchase_type: "aeropay") ──────────────────────────────────

  test "aeropay: mints 1 token against a captured AeropayPurchase (buy-1)" do
    purchase = create_aeropay_purchase(reference: "aeropay_job")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "aeropay", aeropay_reference: "aeropay_job")
    end

    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 1, purchase.tx_signatures.length
    # source_ref parity: "<provider>:<purchase_id>:<i>" — short, distinct, fits [u8;64].
    assert_equal "aeropay:#{purchase.id}:0", vault.mint_calls.first
    assert vault.mint_calls.all? { |r| r.bytesize <= 64 }
    assert TransactionLog.where("metadata @> ?", { aeropay_reference: "aeropay_job" }.to_json).exists?
  end

  test "aeropay: skips when no AeropayPurchase row exists — never creates one" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "aeropay", aeropay_reference: "aeropay_missing")
    end
    assert_equal 0, vault.mint_calls.length
    assert_nil AeropayPurchase.for_reference("aeropay_missing").first
  end

  test "aeropay: refunded purchase short-circuits — never mints over refunded money" do
    purchase = create_aeropay_purchase(reference: "aeropay_refunded")
    purchase.mark_refunded!(reason: "refund while queued")

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "aeropay", aeropay_reference: "aeropay_refunded")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal "refunded", purchase.reload.status
  end

  test "aeropay: already-minted purchase no-ops (OPSEC-009)" do
    purchase = create_aeropay_purchase(reference: "aeropay_noop")
    purchase.mark_minted!(["sig_a"])
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "aeropay", aeropay_reference: "aeropay_noop")
    end
    assert_equal 0, vault.mint_calls.length
    assert_equal ["sig_a"], purchase.reload.tx_signatures
  end

  test "aeropay: a failed row is restored to captured and resumes on retry" do
    purchase = create_aeropay_purchase(reference: "aeropay_resume")
    purchase.update!(status: "failed")
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      TokenPurchaseJob.perform_now(user_id: @user.id, pack_id: "single", wallet_address: @wallet,
                                   purchase_type: "aeropay", aeropay_reference: "aeropay_resume")
    end
    purchase.reload
    assert_equal "minted", purchase.status
    assert_equal 1, vault.mint_calls.length
    assert_equal "aeropay:#{purchase.id}:0", vault.mint_calls.first
  end

  private

  def create_aeropay_purchase(reference:, pack_id: "single", quantity: 1, price_cents: 19_00)
    AeropayPurchase.create!(
      user: @user,
      aeropay_reference: reference,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @wallet,
      status: "captured",
      aeropay_transaction_id: "txn_#{SecureRandom.hex(3)}",
      captured_at: Time.current
    )
  end

  def create_coinflow_purchase(reference:, pack_id: "single", quantity: 1, price_cents: 19_00)
    CoinflowPurchase.create!(
      user: @user,
      coinflow_reference: reference,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @wallet,
      status: "captured",
      coinflow_payment_id: "PAY_#{SecureRandom.hex(3)}",
      captured_at: Time.current
    )
  end

  def create_paypal_purchase(order_id:, pack_id: "single", quantity: 1, price_cents: 19_00)
    PaypalPurchase.create!(
      user: @user,
      paypal_order_id: order_id,
      pack_id: pack_id,
      quantity: quantity,
      price_cents: price_cents,
      wallet_address: @wallet,
      status: "captured",
      capture_id: "CAP_#{SecureRandom.hex(3)}",
      captured_at: Time.current
    )
  end
end
