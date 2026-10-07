require "test_helper"

# [integration] THE REAL SETTLE PAYS THE WALLET THAT ENTERED.
#
# Grades an on-chain contest through the admin grade action, lets
# Contest#settle_onchain! build the REAL partially signed settle_contest
# transaction (Solana::Vault#build_settle_contest; only the RPC's recent
# blockhash is stood in for), and reads the wire back. The program checks each
# settlement's ContestEntry PDA against [b"entry", contest_id, wallet, entry_num],
# so the transaction is accepted only if each record's wallet and slot derive the
# PDA the entry was created at. One winner here entered from the managed wallet
# of an account that also holds Phantom, the shape that broke settle.
#
# A paid winner with no recorded wallet refuses grade with a clear message and
# grades nothing. The control grades the same contest once the wallet is there.
class SettlePaysEnteringWalletTest < ActionDispatch::IntegrationTest
  SETTLE_DISCRIMINATOR = Solana::Transaction.anchor_discriminator("settle_contest").b
  RECORD_BYTES = 32 + 4 + 4 + 8

  setup do
    @admin = users(:alex)
    @contest = Contest.create!(name: "Entering wallet settle #{SecureRandom.hex(3)}", slate: slates(:one),
                               rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                               user: @admin, status: "open", max_entries: 29)
    @contest.update_columns(onchain_contest_id: EnteredOnchain.random_wallet)

    @web2 = EnteredOnchain.random_wallet
    @web3 = EnteredOnchain.random_wallet
    combo = User.create!(email: "combo_settle_#{SecureRandom.hex(4)}@example.com",
                         web2_solana_address: @web2, web3_solana_address: @web3)
    @mixed = enter(combo, from: @web2, score: 100.0)

    @phantom_wallet = EnteredOnchain.random_wallet
    phantom = User.create!(email: "phantom_settle_#{SecureRandom.hex(4)}@example.com",
                           web3_solana_address: @phantom_wallet)
    @phantom = enter(phantom, from: @phantom_wallet, score: 90.0, entry_number: 1)

    log_in_as(@admin)
  end

  test "the built settle for a mixed-wallet contest derives each winner's ContestEntry PDA" do
    grade

    assert_redirected_to contest_path(@contest)
    ix = settle_instruction
    records = decode_records(ix)
    by_wallet = records.index_by { |r| r[:wallet] }

    assert_equal [ @phantom_wallet, @web2 ].sort, by_wallet.keys.sort
    refute by_wallet.key?(@web3), "the mixed-wallet winner is paid at the wallet that entered, not Phantom"

    [ @mixed, @phantom ].each do |entry|
      record = by_wallet.fetch(entry.reload.wallet_address)
      derived = vault.entry_pda(@contest.slug, record[:wallet], record[:entry_num]).first
      assert_equal entry.onchain_entry_id, Solana::Keypair.encode_base58(derived),
                   "entry #{entry.id}: the record's wallet and slot derive the PDA it was entered at"
      assert_includes ix[:accounts], derived.b, "entry #{entry.id}: the PDA rides in the settle's accounts"
      assert_includes ix[:accounts], vault.user_account_pda(record[:wallet]).first.b
    end

    # Control: what the old settle named, User#solana_address, derives a PDA that
    # does not exist, which is the program rejection that blocked every winner.
    wrong = vault.entry_pda(@contest.slug, @mixed.user.solana_address, @mixed.entry_number).first
    refute_equal @mixed.onchain_entry_id, Solana::Keypair.encode_base58(wrong)
    refute_includes ix[:accounts], wrong.b
  end

  test "a paid winner with no recorded wallet refuses grade with a clear error and grades nothing" do
    @phantom.update_columns(wallet_address: nil)

    grade

    assert_redirected_to contest_path(@contest)
    assert_equal "Cannot grade: paid entry #{@phantom.id} has no recorded entering wallet, so the settle cannot " \
                 "pay it. Run bin/rails \"entries:backfill_wallet_address[#{@contest.slug}]\" and grade again; " \
                 "nothing was graded.", flash[:alert]
    assert_ungraded
  end

  test "the JSON grade call answers 422 with the same refusal" do
    @phantom.update_columns(wallet_address: nil)

    grade(as: :json)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_match "no recorded entering wallet", body["error"]
    assert_ungraded
  end

  test "control: the same contest with every wallet recorded grades through the same action" do
    grade

    assert_equal "Contest graded and settled!", flash[:notice]
    assert_equal "settled", @contest.reload.status
    assert_equal 1, PendingTransaction.where(target: @contest, tx_type: "settle_contest").count
  end

  private

  def enter(user, from:, score:, entry_number: 0)
    Entry.create!(user: user, contest: @contest, status: "active", score: score,
                  **EnteredOnchain.attrs(@contest, from, entry_number: entry_number))
  end

  def vault
    @vault ||= begin
      client = Object.new
      client.define_singleton_method(:get_latest_blockhash) { |commitment: "finalized"| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
      Solana::Vault.new(client: client)
    end
  end

  def grade(as: nil)
    Solana::Vault.stub(:new, vault) do
      as ? post(grade_contest_path(@contest), as: as) : post(grade_contest_path(@contest))
    end
  end

  def settle_instruction
    tx = PendingTransaction.find_by!(target: @contest, tx_type: "settle_contest")
    message = Solana::WireMessage.parse_base64(tx.serialized_tx)
    message.instructions.find { |i| i[:data].b.start_with?(SETTLE_DISCRIMINATOR) }.tap do |ix|
      assert ix, "the queued transaction carries a settle_contest instruction"
    end
  end

  def decode_records(ix)
    data = ix[:data].b
    count = data.byteslice(8, 4).unpack1("L<")
    Array.new(count) do |i|
      record = data.byteslice(12 + i * RECORD_BYTES, RECORD_BYTES)
      { wallet: Solana::Keypair.encode_base58(record.byteslice(0, 32)),
        entry_num: record.byteslice(32, 4).unpack1("L<"),
        payout: record.byteslice(40, 8).unpack1("Q<") }
    end
  end

  def assert_ungraded
    assert_equal "open", @contest.reload.status
    assert_equal %w[active active], [ @mixed, @phantom ].map { |e| e.reload.status }
    assert_equal [ 0, 0 ], [ @mixed, @phantom ].map { |e| e.payout_cents.to_i }
    assert_equal 0, TransactionLog.where(source: @contest).count
    assert_equal 0, PendingTransaction.where(target: @contest).count
  end
end
