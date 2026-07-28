require "test_helper"
require "minitest/mock"

# BL3 (Stage 3 audit): real-USD deposit flow. Idempotency depends on the
# OPSEC-022 unique partial index on TransactionLog.stripe_session_id.
class StripeDepositJobTest < ActiveJob::TestCase
  setup do
    @user = users(:jordan)
    @wallet = "ManagedAddr#{SecureRandom.hex(2)}"
    @sid = "cs_test_dep_#{SecureRandom.hex(4)}"
  end

  test "managed-wallet path: ensure_ata + ensure_user_account + fund_user, records TransactionLog" do
    # v0.16: deposit-to-vault is gone. Both managed and phantom paths now just
    # fund the user's own USDC ATA — no custodial vault balance.
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end

    log = TransactionLog.find_by(stripe_session_id: @sid)
    assert log
    assert_equal "deposit", log.transaction_type
    assert_equal 2500, log.amount_cents
    assert_equal "credit", log.direction
    assert_match(/fake-fund/, log.onchain_tx)

    assert_equal 1, vault.ensure_account_calls.length
    assert_equal 1, vault.fund_calls.length
  end

  test "phantom-wallet path: ensure_ata + fund_user only" do
    @user.update!(web3_solana_address: @wallet, web2_solana_address: nil)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 5000, wallet_address: @wallet, stripe_session_id: @sid)
    end

    log = TransactionLog.find_by(stripe_session_id: @sid)
    assert log
    assert_equal 5000, log.amount_cents
    assert_match(/fake-fund/, log.onchain_tx)
    assert_equal 1, vault.fund_calls.length
  end

  test "idempotency: re-delivered webhook does NOT double-credit (claim collision)" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    TransactionLog.record!(user: @user, type: "deposit", amount_cents: 2500, direction: "credit", stripe_session_id: @sid)

    vault = FakeVault.new
    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end

    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 0, vault.fund_calls.length
  end

  test "concurrent race: the row claim's unique index rescues the second insert" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = FakeVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 1, vault.fund_calls.length

    # Second delivery for the same session: the claim create! trips the unique
    # partial index (RecordNotUnique), which the job rescues — no second row,
    # and critically no second transfer.
    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        assert_nothing_raised do
          StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
        end
      end
    end
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 1, vault.fund_calls.length
  end

  test "unknown user_id is a no-op (early return)" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      assert_nothing_raised do
        StripeDepositJob.perform_now(user_id: 99_999_999, amount_cents: 2500, wallet_address: @wallet, stripe_session_id: @sid)
      end
    end
    assert_equal 0, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal 0, vault.fund_calls.length
  end

  # ── Money-path regression: NO double transfer (2026-07 CRITICAL) ─────────
  #
  # `fund_user` is the irreversible on-chain USDC transfer. The pre-fix
  # ordering ran it BEFORE the first row write, so a transient error between
  # transfer and record! (retried by ApplicationJob's `retry_on StandardError`)
  # or a duplicate/concurrent webhook could transfer 2–3×. The fix claims the
  # TransactionLog row (unique index on stripe_session_id) BEFORE transferring,
  # so every re-run collides at the claim and returns without paying again.
  #
  # These tests assert the EFFECT — `fund_user` invocation count — not a proxy.
  # The counter records the transfer even when a later step faults, exactly as
  # the real chain call would have already moved money.

  # A vault whose fund_user records the (irreversible) transfer, then raises a
  # transient fault EXACTLY ONCE — modelling "the USDC moved on-chain, but the
  # very next step faulted." The 2nd+ calls succeed, so the buggy transfer-first
  # ordering visibly funds twice instead of erroring out.
  class ClaimThenTransientFundVault < FakeVault
    def fund_user(wallet, lamports)
      result = super # records the transfer in @fund_calls — it physically landed
      raise StandardError, "simulated transient post-transfer fault" if fund_calls.length == 1

      result
    end
  end

  test "money-path: a transient fault after transfer + ActiveJob retry funds EXACTLY ONCE" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = ClaimThenTransientFundVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        perform_enqueued_jobs do
          StripeDepositJob.perform_later(user_id: @user.id, amount_cents: 2500,
                                         wallet_address: @wallet, stripe_session_id: @sid)
        end
      end
    end

    # retry_on must NOT re-run the irreversible transfer. Transfer-first ordering
    # re-funds on the retry (2×); claim-first stops the retry at the unique index
    # before it can pay again.
    assert_equal 1, vault.fund_calls.length,
                 "fund_user (the irreversible USDC transfer) must run exactly once across retries"

    # End-state: the claim whose completion never landed is left `pending` — the
    # safe outcome (audit-reconcilable, never re-transferred). Directly exercises
    # the job's die-after-claim path: a fault after the transfer cannot re-pay,
    # it only leaves the ledger row un-finalized.
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count
    assert_equal "pending", TransactionLog.find_by(stripe_session_id: @sid).status,
                 "a claim whose completion write never lands stays pending, not re-transferred"
  end

  test "money-path: a duplicate delivery after a claim-without-completion funds EXACTLY ONCE" do
    @user.update!(web2_solana_address: @wallet, encrypted_web2_solana_private_key: "ciphertext")
    vault = ClaimThenTransientFundVault.new

    Solana::Keypair.stub :from_encrypted, "fake-kp" do
      Solana::Vault.stub :new, vault do
        # Delivery 1: claims the row + transfers on-chain, then a transient fault
        # fires before the completion write (retry_on swallows it, enqueues a retry
        # we deliberately do NOT run here).
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500,
                                     wallet_address: @wallet, stripe_session_id: @sid)
        # Delivery 2 (duplicate / concurrent webhook for the same session) must find
        # the claim already held and NOT transfer again.
        StripeDepositJob.perform_now(user_id: @user.id, amount_cents: 2500,
                                     wallet_address: @wallet, stripe_session_id: @sid)
      end
    end

    assert_equal 1, vault.fund_calls.length,
                 "a duplicate delivery must never re-transfer over an already-claimed session"
    assert_equal 1, TransactionLog.where(stripe_session_id: @sid).count,
                 "the session must map to exactly one TransactionLog row"
  end
end
