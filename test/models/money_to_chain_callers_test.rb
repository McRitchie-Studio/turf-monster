require "test_helper"

# Every caller that sends money to the chain, or compares the database to it,
# converts integer cents with Solana::Config.cents_to_base_units. Each test uses
# a cent value the old float path truncated (201 cents became 2_009_999), so a
# caller that slips back onto a Float fails here by exactly one unit.
class MoneyToChainCallersTest < ActiveSupport::TestCase
  ODD = 2_01
  ODD_UNITS = 2_010_000

  setup do
    @contest = Contest.create!(
      name: "Money callers #{SecureRandom.hex(3)}",
      slate: slates(:one),
      rank: 9000 + rand(900),
      contest_type: "standard",
      starts_at: 1.hour.ago,
      user: users(:alex),
      status: "open",
      max_entries: 29
    )
    Contest.where(id: @contest.id).update_all(entry_fee_cents: ODD, payout_table_cents: [ 10_01, ODD ])
    @contest.reload
  end

  test "the odd value is one the float path truncates" do
    assert_equal ODD_UNITS - 1, (ODD / 100.0 * 10**6).to_i
  end

  test "onchain_params: entry fee, payout amounts and prize pool are exact" do
    params = @contest.onchain_params

    assert_equal [ ODD_UNITS, ODD_UNITS ], params[:entry_fee_by_currency].first(2)
    assert_equal [ 10_010_000, ODD_UNITS ], params[:payout_amounts]
    assert_equal 12_020_000, params[:prize_pool]
  end

  test "settle_onchain!: each settlement pays payout_cents in exact base units" do
    @contest.update_columns(onchain_contest_id: Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58)
    user = wallet_user
    entry = Entry.create!(user: user, contest: @contest, status: "complete", score: 1, rank: 2, payout_cents: ODD,
                          **EnteredOnchain.attrs(@contest, user.web3_solana_address))
    vault = FakeVault.new

    Solana::Vault.stub(:new, vault) { @contest.settle_onchain! }

    settlements = vault.settle_calls.sole[:settlements]
    assert_equal [ ODD_UNITS ], settlements.map { |s| s[:payout] }
    assert_equal entry.entry_number, settlements.sole[:entry_num]
  end

  test "StripeDepositJob funds the wallet with exact base units" do
    user = users(:jordan)
    wallet = "ManagedAddr#{SecureRandom.hex(2)}"
    user.update!(web3_solana_address: wallet, web2_solana_address: nil)
    vault = FakeVault.new

    Solana::Vault.stub(:new, vault) do
      StripeDepositJob.perform_now(user_id: user.id, amount_cents: ODD, wallet_address: wallet,
                                   stripe_session_id: "cs_test_exact_#{SecureRandom.hex(4)}")
    end

    assert_equal [ ODD_UNITS ], vault.fund_calls.map { |c| c[:lamports] }
  end

  test "Solana::Reconciler compares the pool to the chain in exact base units" do
    Entry.create!(user: wallet_user, contest: @contest, status: "active", score: 0)
    @contest.update_columns(onchain_contest_id: Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58)
    onchain = { current_entries: 1, entry_fees: [ ODD_UNITS ] + Array.new(15, 0),
                entry_fee_by_currency: [ ODD_UNITS ] + Array.new(15, 0) }
    vault = Object.new
    vault.define_singleton_method(:read_contest) { |_slug| onchain }

    reconciler = Solana::Vault.stub(:new, vault) { Solana::Reconciler.new }
    reconciler.reconcile_contest(@contest)

    assert_empty reconciler.discrepancies.select { |d| d[:type] == :entry_fees_mismatch },
                 "a pool of #{ODD_UNITS} on chain matches #{ODD} cents in the database"
  end

  private

  def wallet_user
    User.create!(email: "money_#{SecureRandom.hex(5)}@example.com",
                 web3_solana_address: Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58)
  end
end
