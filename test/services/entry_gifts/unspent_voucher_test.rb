require "test_helper"

# EntryGifts::UnspentVoucher — may this account link a self-custody wallet
# without stranding a free entry it is still holding?
#
# THE FAULT, MEASURED BEFORE A LINE WAS WRITTEN. Claim a gift on a fresh
# account and the voucher is minted at the MANAGED address. Link a Phantom and
# User#solana_address — `web3_solana_address || web2_solana_address` — stops
# resolving there. Measured on the real consume path: combo_wallets? true,
# WalletSetupPolicy.required? false, and the stamped address no longer the one
# any entry path reads. Nothing noticed.
class EntryGifts::UnspentVoucherTest < ActiveSupport::TestCase
  # Stands in for Solana::Vault. Counts calls so a test can prove the chain was
  # never asked on the paths that must not ask it.
  class StubVault
    attr_reader :calls

    def initialize(consumed: true, raises: false)
      @consumed = consumed
      @raises = raises
      @calls = 0
    end

    def list_entry_tokens(_address)
      @calls += 1
      raise Solana::Client::RpcError, "simulated flake" if @raises

      [{ pda: "TokenPda11111111111111111111111111111111111", consumed: @consumed }]
    end
  end

  def gifted_user
    user = User.create!(email: "voucher-#{SecureRandom.hex(4)}@example.com",
                        email_verified_at: Time.current)
    user.update_columns(web2_solana_address: "Managed#{SecureRandom.hex(16)}",
                        web3_solana_address: nil)
    user.reload
  end

  # Claimed and stamped at the managed wallet — the shape EntryGifts::Claim
  # produces for a gifted newcomer.
  def claimed_gift_for(user, minted: true)
    EntryGift.create!(recipient_email: user.email, sender: users(:alex)).tap do |gift|
      gift.update!(claimed_by: user, claimed_at: Time.current,
                   wallet_address: user.web2_solana_address,
                   minted_at: (Time.current if minted))
    end
  end

  # --- the block -------------------------------------------------------------

  test "an unspent minted voucher blocks the wallet link" do
    user = gifted_user
    gift = claimed_gift_for(user)
    vault = StubVault.new(consumed: false)

    blocker = EntryGifts::UnspentVoucher.blocking_for(user, vault: vault)

    assert blocker, "a voucher still on chain must block the link that would strand it"
    assert_equal gift, blocker.gift
    assert_equal :unspent, blocker.reason
    assert_not blocker.unknown?
  end

  # THE HALF A TOKEN-ONLY CHECK MISSES, and the one WalletSetupPolicy
  # #holds_free_entry? already exists to cover. The claim is SYNCHRONOUS and
  # EntryGiftMintJob is not, so between them a live gift has no token on chain
  # to find. A guard that only asked the chain would wave the link through in
  # exactly that window and strand the voucher it was written to protect.
  test "a claimed gift whose mint is still queued blocks the wallet link" do
    user = gifted_user
    claimed_gift_for(user, minted: false)
    vault = StubVault.new(consumed: false)

    blocker = EntryGifts::UnspentVoucher.blocking_for(user, vault: vault)

    assert blocker, "a gift in flight must block just as a minted one does"
    assert_equal :unspent, blocker.reason
    assert_equal 0, vault.calls, "the queued window is decidable from columns alone"
  end

  # FAILS CLOSED. User#next_unconsumed_entry_token_for rescues to nil and cannot
  # tell "no token" from "could not read" — this guard must, because the two
  # directions cost differently: a flake read as "spent" strands a voucher
  # permanently, while a flake read as "held" costs a retry.
  test "a read that fails blocks, and says it could not tell" do
    user = gifted_user
    claimed_gift_for(user)

    blocker = EntryGifts::UnspentVoucher.blocking_for(user, vault: StubVault.new(raises: true))

    assert blocker, "an unreadable voucher is not permission to proceed"
    assert blocker.unknown?, "the caller must be able to say WHY it refused"
  end

  # --- the passes ------------------------------------------------------------
  #
  # THE CONTROLS. Without these the three above pass for a guard that refuses
  # every wallet link ever attempted.

  test "a spent voucher lets the wallet link through" do
    user = gifted_user
    claimed_gift_for(user)

    assert_nil EntryGifts::UnspentVoucher.blocking_for(user, vault: StubVault.new(consumed: true)),
               "the bypass lasts exactly as long as the free entry does"
  end

  test "an account with no gift at all is never blocked" do
    vault = StubVault.new(consumed: false)

    assert_nil EntryGifts::UnspentVoucher.blocking_for(gifted_user, vault: vault)
    assert_equal 0, vault.calls, "no gift means no reason to reach the chain"
  end

  # Already web3: #solana_address resolves to the Phantom either way, so this
  # link moves nothing and refusing it would only trap the account.
  test "an account that already holds a phantom is never blocked" do
    user = gifted_user
    claimed_gift_for(user)
    user.update_columns(web3_solana_address: "Phantom#{SecureRandom.hex(16)}")

    assert_nil EntryGifts::UnspentVoucher.blocking_for(user.reload, vault: StubVault.new(consumed: false))
  end

  # A gift that can never be paid (an admin claimant, OPSEC-044) must not buy a
  # permanent block on this account's wallet link.
  test "an unpayable gift does not block forever" do
    user = gifted_user
    gift = claimed_gift_for(user, minted: false)
    gift.update!(mint_error: EntryGifts::Claim::ADMIN_REASON)

    assert_nil EntryGifts::UnspentVoucher.blocking_for(user, vault: StubVault.new(consumed: false))
  end

  # Scoped to the address #solana_address resolves to TODAY. A gift stamped
  # somewhere else is not what this link would move.
  test "a gift stamped at another address does not block" do
    user = gifted_user
    gift = claimed_gift_for(user)
    gift.update!(wallet_address: "SomewhereElse#{SecureRandom.hex(12)}")

    assert_nil EntryGifts::UnspentVoucher.blocking_for(user, vault: StubVault.new(consumed: false))
  end
end
