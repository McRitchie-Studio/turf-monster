require "test_helper"

# [unit] THE SETTLE PAYS THE WALLET THAT ENTERED (settle-pays-the-entering-wallet).
#
# A user can hold a managed web2 wallet and a Phantom web3 wallet, and enter from
# either. The program derives each ContestEntry PDA from the entering wallet, so
# the settle must name that wallet. User#solana_address prefers web3, which is the
# wrong answer for an entry made from web2: the bug this file pins.
class EntryEnteringWalletTest < ActiveSupport::TestCase
  setup do
    @contest = Contest.create!(name: "Entering wallet #{SecureRandom.hex(3)}", slate: slates(:one),
                               rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                               user: users(:alex), status: "open", max_entries: 29)
    @web2 = EnteredOnchain.random_wallet
    @web3 = EnteredOnchain.random_wallet
    @combo = User.create!(email: "combo_#{SecureRandom.hex(4)}@example.com",
                          web2_solana_address: @web2, web3_solana_address: @web3)
  end

  test "an entry made from the managed wallet records the managed wallet for a user holding both" do
    entry = enter(@combo, from: @web2)

    assert_equal @web2, entry.wallet_address
    # Control: the address the old settle paid is the OTHER wallet.
    assert_equal @web3, @combo.solana_address
    refute_equal @combo.solana_address, entry.wallet_address
  end

  test "an entry made from Phantom records the Phantom wallet" do
    entry = enter(@combo, from: @web3, entry_number: 1)

    assert_equal @web3, entry.wallet_address
  end

  test "the wallet is recorded when the PDA is written after the row, as every confirm path does" do
    entry = Entry.create!(user: @combo, contest: @contest, status: "cart", score: 0)
    assert_nil entry.wallet_address

    entry.update!(status: "active", **EnteredOnchain.attrs(@contest, @web2))

    assert_equal @web2, entry.reload.wallet_address
  end

  test "a PDA neither of the user's wallets derives records nothing" do
    stranger = EnteredOnchain.random_wallet
    entry = enter(@combo, from: stranger)

    assert_nil entry.wallet_address
  end

  test "a PDA derived for another slot records nothing" do
    entry = Entry.create!(user: @combo, contest: @contest, status: "active", score: 0, entry_number: 2,
                          onchain_entry_id: EnteredOnchain.attrs(@contest, @web2, entry_number: 0)[:onchain_entry_id])

    assert_nil entry.wallet_address
  end

  test "settlements pay the entering wallet, not User#solana_address" do
    entry = enter(@combo, from: @web2)
    entry.update_columns(status: "complete", rank: 1, payout_cents: 300_00)

    settlement = @contest.payout_settlements.sole

    assert_equal @web2, settlement[:wallet]
    assert_equal entry.entry_number, settlement[:entry_num]
    assert_equal 300_00 * 10_000, settlement[:payout]
  end

  test "settlements refuse a paid entry with no recorded wallet instead of dropping it" do
    paid = enter(@combo, from: @web2)
    paid.update_columns(status: "complete", rank: 1, payout_cents: 300_00)
    blank = Entry.create!(user: User.create!(email: "nowallet_#{SecureRandom.hex(4)}@example.com"),
                          contest: @contest, status: "complete", score: 0, rank: 2, payout_cents: 100_00)

    error = assert_raises(Contest::MissingPayoutWalletError) { @contest.payout_settlements }

    assert_includes error.message, "paid entry #{blank.id} has no recorded entering wallet"
    assert_includes error.message, "entries:backfill_wallet_address[#{@contest.slug}]"
  end

  test "an unpaid entry with no wallet does not block the settle" do
    paid = enter(@combo, from: @web2)
    paid.update_columns(status: "complete", rank: 1, payout_cents: 300_00)
    Entry.create!(user: User.create!(email: "unpaid_#{SecureRandom.hex(4)}@example.com"),
                  contest: @contest, status: "complete", score: 0, rank: 5, payout_cents: 0)

    assert_equal [ @web2 ], @contest.payout_settlements.map { |s| s[:wallet] }
  end

  private

  def enter(user, from:, entry_number: 0)
    Entry.create!(user: user, contest: @contest, status: "active", score: 0,
                  **EnteredOnchain.attrs(@contest, from, entry_number: entry_number))
  end
end
