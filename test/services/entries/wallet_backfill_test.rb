require "test_helper"

# [unit] Entries::WalletBackfill records the entering wallet on older rows from
# the chain, read-only, and leaves a row it cannot prove nil (grading then
# refuses it). The fake client answers getAccountInfo only, so a write to the
# chain would raise NoMethodError.
class EntriesWalletBackfillTest < ActiveSupport::TestCase
  setup do
    @contest = Contest.create!(name: "Backfill #{SecureRandom.hex(3)}", slate: slates(:one),
                               rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                               user: users(:alex), status: "open", max_entries: 29)
    @web2 = EnteredOnchain.random_wallet
    @web3 = EnteredOnchain.random_wallet
    @user = User.create!(email: "backfill_#{SecureRandom.hex(4)}@example.com",
                         web2_solana_address: @web2, web3_solana_address: @web3)
    @accounts = {}
  end

  test "reads the entering wallet off the ContestEntry account" do
    entry = legacy_entry(from: @web2)
    @accounts[entry.onchain_entry_id] = account(@web2, 0)

    stats = run_backfill

    assert_equal @web2, entry.reload.wallet_address
    assert_equal 1, stats[:chain]
    # Control: User#solana_address, which the old settle paid, is the other wallet.
    assert_equal @web3, @user.solana_address
  end

  test "an account naming another wallet or slot than the PDA's seeds is not trusted" do
    forged = legacy_entry(from: @web2)
    @accounts[forged.onchain_entry_id] = account(@web3, 0)
    wrong_slot = legacy_entry(from: @web2, entry_number: 1)
    @accounts[wrong_slot.onchain_entry_id] = account(@web2, 2)

    stats = run_backfill

    assert_nil forged.reload.wallet_address
    assert_nil wrong_slot.reload.wallet_address
    assert_equal [ forged.id, wrong_slot.id ].sort, stats[:unresolved].sort
  end

  test "a closed account falls back to the PDA proof from the user's wallets" do
    entry = legacy_entry(from: @web3)
    @accounts[entry.onchain_entry_id] = nil

    stats = run_backfill

    assert_equal @web3, entry.reload.wallet_address
    assert_equal 1, stats[:derived]
  end

  test "a closed account no wallet of the user's derives stays nil" do
    entry = legacy_entry(from: EnteredOnchain.random_wallet)
    @accounts[entry.onchain_entry_id] = nil

    assert_equal [ entry.id ], run_backfill[:unresolved]
    assert_nil entry.reload.wallet_address
  end

  test "an RPC answer with no value key writes nothing and is reported unreadable" do
    entry = legacy_entry(from: @web2)
    @accounts[entry.onchain_entry_id] = :no_value

    assert_equal [ entry.id ], run_backfill[:unreadable]
    assert_nil entry.reload.wallet_address
  end

  test "a row that already has a wallet is never read" do
    entry = Entry.create!(user: @user, contest: @contest, status: "active", score: 0,
                          **EnteredOnchain.attrs(@contest, @web2))
    assert_equal @web2, entry.wallet_address

    stats = run_backfill

    assert_equal({ chain: 0, derived: 0, unresolved: [], unreadable: [] }, stats)
  end

  private

  # A row as it stood before the column: PDA and slot stored, no wallet.
  def legacy_entry(from:, entry_number: 0)
    Entry.create!(user: @user, contest: @contest, status: "active", score: 0,
                  **EnteredOnchain.attrs(@contest, from, entry_number: entry_number)).tap do |entry|
      entry.update_columns(wallet_address: nil)
    end
  end

  # turf-vault ContestEntry: discriminator, contest_id, wallet, entry_num, status,
  # rank, payout, currency_idx, bump, reserved.
  def account(wallet, entry_num)
    data = Digest::SHA256.digest("account:ContestEntry")[0, 8] +
           Digest::SHA256.digest(@contest.slug) +
           Solana::Keypair.decode_base58(wallet) +
           [ entry_num ].pack("V") + "\x00".b + [ 0 ].pack("V") + [ 0 ].pack("Q<") + "\x00\xFF".b + ("\x00" * 16).b
    { "data" => [ Base64.strict_encode64(data), "base64" ] }
  end

  def run_backfill
    accounts = @accounts
    client = Object.new
    client.define_singleton_method(:get_account_info) do |pubkey, **_kw|
      answer = accounts.fetch(pubkey) { raise "unexpected read of #{pubkey}" }
      answer == :no_value ? {} : { "value" => answer }
    end
    Entries::WalletBackfill.run(contest: @contest, vault: Solana::Vault.new(client: client))
  end
end
