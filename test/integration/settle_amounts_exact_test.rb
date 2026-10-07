require "test_helper"

# THE SETTLE TRANSACTION PAYS EXACTLY WHAT GRADING RECORDED.
#
# For every contest format, this grades a real on-chain contest under tie
# patterns, lets Contest#settle_onchain! build the REAL partially signed
# settle_contest transaction (Solana::Vault#build_settle_contest; only the RPC's
# recent blockhash is stood in for), decodes the instruction data off the wire,
# and checks each settlement record to the base unit: payout_cents * 10_000, and
# a total equal to the prize pool the contest was created with
# (Contest#onchain_params). The program accepts a settle only when the payouts
# sum to no more than the pool, so the two must agree exactly.
#
# The live formats' shares are all values the old float path happened to get
# right, so the last test grades a payout table with odd cents (shares such as
# 201 cents) that the float path truncated; it carries its own control.
class SettleAmountsExactTest < ActiveSupport::TestCase
  SETTLE_DISCRIMINATOR = Solana::Transaction.anchor_discriminator("settle_contest").b
  RECORD_BYTES = 32 + 4 + 4 + 8

  TIE_PATTERNS = {
    "no ties"            => ->(size) { (1..size).map { |i| 1000 - i } },
    "three tied for 1st" => ->(size) { Array.new([ size, 3 ].min, 900) + (1..[ size - 3, 0 ].max).map { |i| 800 - i } },
    "everyone tied"      => ->(size) { Array.new(size, 500) }
  }.freeze

  setup do
    @creator = users(:alex)
    @slate = slates(:one)
  end

  Contest::FORMATS.each_key do |format|
    test "#{format} settles exact base units under every tie pattern" do
      TIE_PATTERNS.each do |pattern, scores_for|
        contest = onchain_contest(format)
        scores_for.call(contest.max_entries).each { |score| make_entry(contest, score) }

        records = grade_and_decode(contest)
        paid = contest.entries.where("payout_cents > 0").order(:id)

        assert_equal paid.map { |e| e.payout_cents * 10_000 }.sort, records.map { |r| r[:payout] }.sort,
                     "#{format} / #{pattern}: every settlement pays its payout_cents to the unit"
        assert_equal contest.onchain_params[:prize_pool], records.sum { |r| r[:payout] },
                     "#{format} / #{pattern}: the settle sums to the funded prize pool"
      end
    end
  end

  test "a payout table with odd cents settles exact where the float path fell short" do
    contest = onchain_contest("standard")
    Contest.where(id: contest.id).update_all(payout_table_cents: [ 10_01, 2_01, 2_01, 2_01 ])
    contest.reload
    # Three tied for 1st split 1st-3rd (1_403 cents) as 468/468/467; 4th is 201.
    3.times { make_entry(contest, 900) }
    make_entry(contest, 800)
    make_entry(contest, 700)

    records = grade_and_decode(contest)
    shares = contest.entries.where("payout_cents > 0").pluck(:payout_cents).sort

    assert_equal [ 2_01, 4_67, 4_68, 4_68 ], shares
    assert_equal shares.map { |c| c * 10_000 }, records.map { |r| r[:payout] }.sort
    assert_equal 16_04 * 10_000, contest.onchain_params[:prize_pool]
    assert_equal contest.onchain_params[:prize_pool], records.sum { |r| r[:payout] }

    # Control: the float formula this replaced pays 4th place one unit short,
    # so its settle summed below the pool it was checked against.
    float_path = ->(cents) { (cents / 100.0 * 10**6).to_i }
    assert_equal 2_009_999, float_path.call(2_01)
    assert_equal contest.onchain_params[:prize_pool] - 1, shares.sum(&float_path)
  end

  private

  def onchain_contest(format)
    config = Contest::FORMATS.fetch(format)
    Contest.create!(
      name: "Exact settle #{format} #{SecureRandom.hex(3)}",
      slate: @slate,
      rank: 9000 + rand(900),
      contest_type: format,
      starts_at: 1.hour.ago,
      user: @creator,
      status: "open",
      max_entries: config[:max_entries]
    ).tap { |c| c.update_columns(onchain_contest_id: Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58) }
  end

  def make_entry(contest, score)
    user = User.create!(email: "exact_#{SecureRandom.hex(5)}@example.com",
                        web3_solana_address: Solana::Keypair.from_bytes(SecureRandom.random_bytes(32)).to_base58)
    Entry.create!(user: user, contest: contest, status: "active", score: score,
                  **EnteredOnchain.attrs(contest, user.web3_solana_address))
  end

  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |commitment: "finalized"| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
    client
  end

  # Grades the contest with the real settle builder and returns the settlement
  # records decoded from the queued transaction's settle_contest instruction.
  def grade_and_decode(contest)
    vault = Solana::Vault.new(client: fake_client)
    Solana::Vault.stub(:new, vault) do
      contest.stub(:score_entries!, nil) { contest.grade! }
    end

    tx = PendingTransaction.find_by!(target: contest, tx_type: "settle_contest")
    message = Solana::WireMessage.parse_base64(tx.serialized_tx)
    ix = message.instructions.find { |i| i[:data].b.start_with?(SETTLE_DISCRIMINATOR) }
    assert ix, "the queued transaction carries a settle_contest instruction"

    data = ix[:data].b
    count = data.byteslice(8, 4).unpack1("L<")
    assert_equal 8 + 4 + count * RECORD_BYTES, data.bytesize
    Array.new(count) do |i|
      record = data.byteslice(12 + i * RECORD_BYTES, RECORD_BYTES)
      { entry_num: record.byteslice(32, 4).unpack1("L<"),
        rank: record.byteslice(36, 4).unpack1("L<"),
        payout: record.byteslice(40, 8).unpack1("Q<") }
    end
  end
end
