require "test_helper"
require "minitest/mock"

# EntryGiftMintJob — pays the token an EntryGift promised.
#
# The interesting case is not the happy path. It is a retry after a mint that
# LANDED but whose response never came back: the deterministic source_ref makes
# the program's `init` refuse the retry, and that refusal is indistinguishable
# from a real failure by its error alone. The job must read the chain back
# rather than erroring forever.
class EntryGiftMintJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # ApplicationJob declares `retry_on StandardError`, so a raise from #perform
  # NEVER escapes perform_now — ActiveJob catches it and re-enqueues. The
  # observable proof that a failure was treated as a failure is therefore the
  # RETRY plus the recorded reason, not an exception. Asserting a raise here
  # passed only because it was never reached (the first draft of these three
  # tests did exactly that, green, proving nothing).
  def assert_retried_with_error(pattern)
    assert_enqueued_jobs 1, only: EntryGiftMintJob do
      yield
    end
    assert_not @gift.reload.minted?
    assert_match pattern, @gift.mint_error
  end

  setup do
    @user = users(:sam) # carries a wallet
    @gift = EntryGift.create!(recipient_email: "friend@example.com", sender: users(:alex))
    @gift.update!(claimed_by: @user, claimed_at: Time.current, wallet_address: @user.solana_address)
  end

  def run_job(vault)
    Solana::Vault.stub :ensure_program_id_live!, :live do
      Solana::Vault.stub :new, vault do
        yield if block_given?
        EntryGiftMintJob.perform_now(@gift.id)
      end
    end
  end

  # --- the happy path ---

  test "mints the gift's own ref to the gift's own wallet" do
    vault = FakeVault.new
    run_job(vault)

    assert_equal [@gift.mint_source_ref], vault.mint_calls
    assert_equal [@user.solana_address], vault.mint_wallets

    @gift.reload
    assert @gift.minted?
    assert @gift.mint_signature.present?
    assert_nil @gift.mint_error
  end

  test "clears a previous error on success" do
    @gift.update!(mint_error: "earlier RPC flake")
    run_job(FakeVault.new)
    assert_nil @gift.reload.mint_error
  end

  # --- idempotency ---

  test "an already-minted gift mints nothing" do
    @gift.update!(minted_at: Time.current, mint_signature: "sig_already")
    vault = FakeVault.new
    run_job(vault)

    assert_empty vault.mint_calls
    assert_equal "sig_already", @gift.reload.mint_signature
  end

  test "a missing gift is a no-op, not a crash" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      assert_nothing_raised { EntryGiftMintJob.perform_now(-1) }
    end
    assert_empty vault.mint_calls
  end

  # --- the lost-response recovery ---

  test "a mint that already landed is recovered, not retried forever" do
    # The chain already holds a token carrying THIS gift's ref — the state after
    # a successful mint whose confirmation never came back. The retry's `init`
    # refuses, exactly as the program does.
    vault = FakeVault.new(tokens: [{ pda: "tpda_landed", source_ref: @gift.mint_source_ref,
                                     consumed: false }])
    vault.raise_on_mint = StandardError.new("custom program error: 0x0 (already in use)")

    assert_nothing_raised { run_job(vault) }

    @gift.reload
    assert @gift.minted?, "a token already on chain must stamp the gift minted"
    assert_equal "tpda_landed", @gift.mint_signature
    assert_nil @gift.mint_error
  end

  # THE OTHER HALF OF THAT SAME QUESTION, and the half that must NOT be silently
  # forgiven: the chain holds no token for this ref, so the failure is real.
  test "a real failure records the error and re-raises for retry" do
    vault = FakeVault.new(tokens: [])
    vault.raise_on_mint = StandardError.new("RPC timeout")

    assert_retried_with_error(/RPC timeout/) { run_job(vault) }
  end

  # A token on the SAME wallet under a DIFFERENT ref is somebody else's grant (a
  # level-up, a purchase) and must never be read as this gift's payment.
  test "another token on the same wallet is not mistaken for this gift" do
    vault = FakeVault.new(tokens: [{ pda: "tpda_levelup", source_ref: "levelup:test:abc:2" }])
    vault.raise_on_mint = StandardError.new("RPC timeout")

    assert_retried_with_error(/RPC timeout/) { run_job(vault) }
    assert_empty EntryGift.where.not(minted_at: nil), "no gift may be stamped from a stranger's token"
  end

  # A recovery READ that itself fails is not evidence of anything. The original
  # error stands and Sidekiq retries.
  test "a failed recovery read leaves the original failure standing" do
    vault = FakeVault.new
    vault.raise_on_mint = StandardError.new("RPC timeout")
    def vault.list_entry_tokens(*) = raise(StandardError, "getProgramAccounts rate limited")

    assert_retried_with_error(/RPC timeout/) { run_job(vault) }
  end

  # --- nothing to pay ---

  test "a claim with no wallet records why and never calls the chain" do
    @gift.update!(wallet_address: nil, claimed_by: User.create!(email: "nowallet@example.com"))
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      EntryGiftMintJob.perform_now(@gift.id)
    end

    assert_empty vault.mint_calls
    assert_equal EntryGifts::Claim::NO_WALLET_REASON, @gift.reload.mint_error
  end
end
