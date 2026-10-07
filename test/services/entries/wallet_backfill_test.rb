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
    @reads = Hash.new(0)
    @pauses = []
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

  # Helius answers a rate limit with HTTP 429 and a plain-text body. On
  # solana-studio 0.12 that raises JSON::ParserError; from the gem fix on it
  # raises RpcError code 429 once the client's own retries run out. Either way
  # the row is re-read once, after a pause, before it is skipped.
  test "a 429 then success resolves the row as :chain" do
    entry = legacy_entry(from: @web2)
    @accounts[entry.onchain_entry_id] = [ JSON::ParserError.new("unexpected character: 'Too'"), account(@web2, 0) ]

    stats = run_backfill

    assert_equal @web2, entry.reload.wallet_address
    assert_equal 1, stats[:chain]
    assert_empty stats[:unreadable]
    assert_equal 2, @reads[entry.onchain_entry_id]
    assert_equal [ Entries::WalletBackfill::REREAD_PAUSE ], @pauses
  end

  test "an RpcError 429 then success resolves the row as :chain" do
    entry = legacy_entry(from: @web2)
    @accounts[entry.onchain_entry_id] = [ Solana::Client::RpcError.new("HTTP 429 from RPC: Too many requests", code: 429),
                                          account(@web2, 0) ]

    stats = run_backfill

    assert_equal @web2, entry.reload.wallet_address
    assert_equal 1, stats[:chain]
  end

  test "an answer with no value key then success resolves the row" do
    entry = legacy_entry(from: @web3)
    @accounts[entry.onchain_entry_id] = [ :no_value, nil ]

    stats = run_backfill

    assert_equal @web3, entry.reload.wallet_address
    assert_equal 1, stats[:derived]
  end

  test "a row unreadable twice is skipped after exactly one re-read" do
    entry = legacy_entry(from: @web2)
    rate_limited = Solana::Client::RpcError.new("HTTP 429 from RPC: Too many requests", code: 429)
    @accounts[entry.onchain_entry_id] = [ rate_limited, rate_limited, account(@web2, 0) ]

    stats = run_backfill

    assert_equal [ entry.id ], stats[:unreadable]
    assert_nil entry.reload.wallet_address
    assert_equal 2, @reads[entry.onchain_entry_id]
    assert_equal 1, @pauses.size
  end

  test "a readable row is read once and never paused for" do
    entry = legacy_entry(from: @web2)
    @accounts[entry.onchain_entry_id] = account(@web2, 0)

    run_backfill

    assert_equal 1, @reads[entry.onchain_entry_id]
    assert_empty @pauses
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

  # The fake client answers getAccountInfo only. An Array of answers is served
  # in order, one per read; an exception in it is raised, :no_value answers
  # without the "value" key.
  def run_backfill
    accounts = @accounts
    reads = @reads
    pauses = @pauses
    client = Object.new
    client.define_singleton_method(:get_account_info) do |pubkey, **_kw|
      planned = accounts.fetch(pubkey) { raise "unexpected read of #{pubkey}" }
      answer = planned.is_a?(Array) ? planned.fetch(reads[pubkey]) : planned
      reads[pubkey] += 1
      raise answer if answer.is_a?(Exception)

      answer == :no_value ? {} : { "value" => answer }
    end
    Entries::WalletBackfill.run(contest: @contest, vault: Solana::Vault.new(client: client),
                                sleeper: ->(seconds) { pauses << seconds })
  end
end
