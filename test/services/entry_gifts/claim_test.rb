require "test_helper"

# EntryGifts::Claim — what happens the instant a gift's magic link is consumed.
#
# The behaviour under test that no other suite covers: a gifted account gets a
# managed wallet EVEN THOUGH web3-only onboarding is on, because the gift is an
# on-chain token and a token needs an address (Mr. McRitchie's call, 2026-09-08).
class EntryGifts::ClaimTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @sender = users(:alex)
    @gift   = EntryGift.create!(recipient_email: "friend@example.com", sender: @sender)
    # A brand-new account exactly as sign_up_new leaves one under web3-only
    # onboarding: created, signed in, and holding NO wallet.
    @user = with_web3_only(true) { User.create!(email: "friend@example.com") }
    assert_nil @user.reload.solana_address, "fixture precondition: no wallet at signup"
  end

  def with_web3_only(on)
    previous = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = on ? "true" : "false"
    yield
  ensure
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = previous
  end

  # --- the operator's call ---

  test "mints a managed wallet despite web3-only onboarding" do
    with_web3_only(true) do
      assert EntryGifts::Claim.call(@gift, @user).claimed?
    end

    assert @user.reload.web2_solana_address.present?,
           "a gifted account must get an address to mint the token to"
    assert_equal @user.solana_address, @gift.reload.wallet_address
  end

  test "stamps the claim on the gift" do
    with_web3_only(true) { EntryGifts::Claim.call(@gift, @user) }

    @gift.reload
    assert @gift.claimed?
    assert_equal @user, @gift.claimed_by
    assert_nil @gift.mint_error
  end

  test "enqueues the mint" do
    assert_enqueued_with(job: EntryGiftMintJob, args: [@gift.id]) do
      with_web3_only(true) { EntryGifts::Claim.call(@gift, @user) }
    end
  end

  # THE HALF-GIFT THIS GUARDS. The signup callback already declined to create the
  # on-chain UserAccount (no wallet existed then) and nothing re-runs it when one
  # appears. Vault#enter_contest_with_token passes user_pda as a WRITABLE
  # account, so without this the recipient holds a token they cannot spend.
  test "enqueues the on-chain UserAccount for the new wallet" do
    assert_enqueued_with(job: CreateOnchainUserAccountJob, args: [@user.id]) do
      with_web3_only(true) { EntryGifts::Claim.call(@gift, @user) }
    end
  end

  # --- an account that already has a wallet ---

  test "reuses an existing wallet and creates no second one" do
    user = users(:sam) # already carries a web3 address
    existing = user.solana_address
    assert existing.present?

    assert_no_enqueued_jobs(only: CreateOnchainUserAccountJob) do
      EntryGifts::Claim.call(@gift, user)
    end

    assert_equal existing, user.reload.solana_address
    assert_equal existing, @gift.reload.wallet_address
    assert_nil user.web2_solana_address, "must not mint a custodial wallet over a linked one"
  end

  # --- idempotency ---

  test "a second claim is a no-op and enqueues nothing" do
    with_web3_only(true) { EntryGifts::Claim.call(@gift, @user) }
    first_claimed_at = @gift.reload.claimed_at

    result = nil
    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      result = EntryGifts::Claim.call(@gift.reload, users(:jordan))
    end

    assert_not result.claimed?
    assert_equal "already claimed", result.reason
    assert_equal @user, @gift.reload.claimed_by, "the first claimant keeps the gift"
    assert_equal first_claimed_at.to_i, @gift.claimed_at.to_i
  end

  # --- the states that cannot be paid ---

  # OPSEC-044 is NOT parameterised by the gift path: an admin never gets a
  # custodial key. The gift is still CLAIMED (they clicked, it is theirs) and the
  # row names why it cannot be minted, so /admin/entry_gifts shows the condition
  # instead of a gift stuck at "claimed" forever.
  test "an admin claimant is claimed but unpayable, and no mint is queued" do
    admin = User.create!(email: "new-admin@example.com", role: "admin")

    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      with_web3_only(true) { EntryGifts::Claim.call(@gift, admin) }
    end

    @gift.reload
    assert @gift.claimed?, "an admin who clicked still claimed the gift"
    assert_nil @gift.wallet_address
    assert_equal EntryGifts::Claim::ADMIN_REASON, @gift.mint_error
    assert_equal :failed, @gift.status
  end

  test "no gift and no user are handled, not raised" do
    assert_not EntryGifts::Claim.call(nil, @user).claimed?
    assert_not EntryGifts::Claim.call(@gift, nil).claimed?
    assert_not @gift.reload.claimed?
  end
end
