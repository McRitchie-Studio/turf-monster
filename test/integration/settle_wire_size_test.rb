require "test_helper"

# EVERY CONTEST FORMAT SETTLES IN ONE TRANSACTION.
#
# Settlement is one settle_contest call in one legacy transaction, and a wire
# transaction holds at most 1,232 bytes. Each paid entry adds a 48-byte
# settlement record and three accounts, so the paid-entry count is what decides
# the fit. This builds the REAL partially signed transaction the app queues
# (Solana::Vault#build_settle_contest over solana-studio's Transaction), decodes
# it with Solana::WireMessage, and measures it: for every format, with a full
# field graded through Contest::PayoutSplit under each tie pattern, in both the
# turf-vault v0.25 shape and the v0.26 governance shape (the governance account
# plus a third signer, which is what the cosign rebuild adds).
#
# Only the RPC is stood in for, and only for the recent blockhash, a fixed 32
# bytes on every wire.
class SettleWireSizeTest < ActiveSupport::TestCase
  COSIGNER = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  THIRD_SIGNER = "GDDMwNyyx8uB6zrqwBFHjLLG3TBYk2F8Az4yrQC5RzMp".freeze

  SHAPES = { "v0.25" => false, "v0.26" => true }.freeze

  # Finishing scores for a full field of `size` entries, best first.
  TIE_PATTERNS = {
    "no ties"                  => ->(size, _paid) { (1..size).map { |i| 1000 - i } },
    "everyone tied"            => ->(size, _paid) { Array.new(size, 500) },
    "tie at the last paid rank" => ->(size, paid) { (1...paid).map { |i| 1000 - i } + Array.new(size - paid + 1, 500) },
    "tie across the last paid rank" => ->(size, paid) { [1000] + Array.new(size - 1, 500) },
    "pairs tied all the way down" => ->(size, _paid) { (0...size).map { |i| 1000 - (i / 2) } }
  }.freeze

  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |commitment: "finalized"| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
    client
  end

  def wallet(i)
    Solana::Keypair.from_bytes(Digest::SHA256.digest("settle-size winner #{i}")).to_base58
  end

  # The settlements #settle_onchain! would queue: every entry paid more than
  # zero, each from its own wallet (distinct wallets add the most accounts).
  def settlements_for(scores, payouts)
    Contest::PayoutSplit.call(scores, payouts).each_with_index.filter_map do |(rank, cents), i|
      next unless cents > 0

      { wallet: wallet(i), entry_num: 1, rank: rank, payout: cents * 10_000 }
    end
  end

  def wire_bytes(settlements, governance:)
    Solana::Config.stub(:governance?, governance) do
      result = Solana::Vault.new(client: fake_client).build_settle_contest(
        "settle-size-contest", settlements,
        cosigner_pubkey: COSIGNER,
        extra_cosigners: governance ? [THIRD_SIGNER] : []
      )
      Solana::WireMessage.parse_base64(result[:serialized_tx]).to_bytes.bytesize
    end
  end

  Contest::FORMATS.each_key do |format|
    SHAPES.each do |shape, governance|
      test "#{format} settles in one transaction on #{shape} under every tie pattern" do
        config = Contest::FORMATS.fetch(format)
        payouts = Contest.new(contest_type: format).payouts
        paid = payouts.keys.max

        TIE_PATTERNS.each do |pattern, scores_for|
          settlements = settlements_for(scores_for.call(config[:max_entries], paid), payouts)
          assert_operator settlements.size, :<=, Contest::MAX_PAID_RANKS, "#{format} / #{pattern}"

          size = wire_bytes(settlements, governance: governance)
          assert_operator size, :<=, Solana::Vault::PACKET_DATA_SIZE,
                          "#{format} / #{pattern} on #{shape}: #{settlements.size} paid entries serialize to #{size} bytes"
        end
      end
    end
  end

  # A contest carrying the nine-rank table cannot settle; contests:reshape_payout
  # gives it a four-rank table of the same pool, and then it does.
  test "reshaped pre snapshot large fits" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("contests:reshape_payout")
    contest = Contest.create!(name: "Pre-snapshot large", slate: slates(:one), status: :open, contest_type: "large")
    Contest.where(id: contest.id).update_all(payout_table_cents: Contest::PRE_SNAPSHOT_PAYOUTS.fetch("large"))
    no_ties = TIE_PATTERNS.fetch("no ties").call(99, 9)

    # Control: the table it opened with does not fit.
    assert_raises(Solana::Vault::SettleTooLargeError) do
      wire_bytes(settlements_for(no_ties, contest.reload.payouts), governance: true)
    end

    ENV["WRITE"] = "1"
    ENV["TABLE_CENTS"] = "100000,40000,20000,20000"
    capture_io do
      Rake::Task["contests:reshape_payout"].reenable
      Rake::Task["contests:reshape_payout"].invoke(contest.slug)
    end

    payouts = contest.reload.payouts
    assert_equal 1800_00, payouts.values.sum
    SHAPES.each do |shape, governance|
      TIE_PATTERNS.each do |pattern, scores_for|
        settlements = settlements_for(scores_for.call(99, payouts.keys.max), payouts)
        size = wire_bytes(settlements, governance: governance)
        assert_operator size, :<=, Solana::Vault::PACKET_DATA_SIZE, "#{pattern} on #{shape}: #{size} bytes"
      end
    end
  ensure
    %w[WRITE TABLE_CENTS].each { |key| ENV.delete(key) }
  end

  # The ceiling the formats are built to: four paid entries fit the v0.26
  # shape, and a fifth does not, so the builder refuses it before anything is
  # queued.
  test "four paid entries fit v0.26 and five do not" do
    four = (0...4).map { |i| { wallet: wallet(i), entry_num: 1, rank: i + 1, payout: 1_000_000 } }
    five = four + [{ wallet: wallet(4), entry_num: 1, rank: 5, payout: 1_000_000 }]

    assert_operator wire_bytes(four, governance: true), :<=, Solana::Vault::PACKET_DATA_SIZE

    error = assert_raises(Solana::Vault::SettleTooLargeError) { wire_bytes(five, governance: true) }
    assert_match(/5 paid entries serializes to \d+ bytes/, error.message)
  end
end
