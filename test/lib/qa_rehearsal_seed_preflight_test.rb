# frozen_string_literal: true

require "test_helper"

# The rehearsal creates its contest as a parked roster row, and the roster seed
# is what puts that row on QA. These run the scripts the driver sends against
# the test database, so the seed and the lookup are held to each other.
#
# The chain script (the one that mints and creates) is captured and answered
# with a canned result. It is never evaluated.
class QaRehearsalSeedPreflightTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver
  Refused = TurfMonster::QaRehearsal::RemoteRunner::Refused

  ROSTER = User::PARKED_IDENTITIES
  CREATOR = ROSTER.find { |identity| identity[:email] == Driver::CREATOR_EMAIL }
  CHAIN_CALLS = /Solana::Vault|mint_spl|ensure_ata|Contest\.create!|Solana::Config\.client|update_columns/

  CREATED = {
    "contest_slug" => "qa-rehearsal-x", "name" => "QA Rehearsal", "onchain" => true,
    "picks_required" => 6, "payouts" => { "1" => 100 }, "prize_pool_cents" => 50_000,
    "matchup_ids" => [1, 2, 3], "locks_at" => "2026-09-06T00:00:00Z", "minted" => nil,
    "kickoff_shift_seconds" => 0
  }.freeze

  # Stands in for the dyno: evaluates a script here with the helpers
  # RemoteRunner prepends, except the chain script.
  class LocalDyno
    attr_reader :scripts

    def initialize = (@scripts = [])

    def call(source)
      @scripts << source
      return CREATED if source.include?("Contest.create!")

      answer = nil
      host = Object.new
      host.define_singleton_method(:emit) { |payload| answer = JSON.parse(payload.to_json) }
      host.define_singleton_method(:refuse) { |message| raise Refused, message }
      host.instance_eval(source)
      answer
    end
  end

  class NullManifest
    def write(data) = data
  end

  setup do
    @dyno = LocalDyno.new
    @io = StringIO.new
    @driver = Driver.new(io: @io)
    @driver.instance_variable_set(:@facts, { "network" => "devnet" })
    @driver.instance_variable_set(:@remote, @dyno)
    @driver.instance_variable_set(:@manifest, NullManifest.new)
    Slate.create!(name: Driver::SLATE_NAME)
    displace_roster_rows!
  end

  # No row holds a roster email, wallet or username: the state the seed starts
  # from on a database that was never seeded.
  def displace_roster_rows!
    emails = ROSTER.map { |i| i[:email] }
    wallets = ROSTER.filter_map { |i| i[:wallet] }
    usernames = ROSTER.map { |i| i[:username] }
    User.where(email: emails).or(User.where(web3_solana_address: wallets)).or(User.where(username: usernames))
        .each_with_index do |user, n|
      user.update_columns(email: "displaced-#{n}@example.com", username: "displaced#{n}",
                          web3_solana_address: nil)
    end
    assert_empty User.where(email: emails).or(User.where(web3_solana_address: wallets)).to_a
  end

  def seed! = silence_warnings { capture_io { @driver.seed_roster } }

  test "after the QA seed, create resolves the creator before the chain script is sent" do
    seed!
    @driver.create_contest

    creator = User.find_by!(email: Driver::CREATOR_EMAIL)
    assert_equal "admin", creator.role
    assert_equal CREATOR[:wallet], creator.web3_solana_address
    refute creator.unproven_parked_holder?, "the seeded creator holds its parked wallet, so the address is proven"

    _seed, preflight, chain = @dyno.scripts
    refute_match CHAIN_CALLS, preflight, "the preflight reads the database and nothing else"
    assert_includes chain, "Contest.create!"
    assert_includes @io.string, "creator: #{CREATOR[:username]} (#{Driver::CREATOR_EMAIL})"
  end

  test "the seed step names every roster username and the creator" do
    seed!

    ROSTER.each { |identity| assert User.exists?(email: identity[:email]), "#{identity[:username]} was not seeded" }
    assert_match(/roster:\s+#{ROSTER.map { |i| i[:username] }.join(', ')}/, @io.string)
    assert_includes @io.string, "Next, once he confirms:  bin/qa-contest-rehearsal create"
  end

  test "a missing creator stops create with a plain sentence and sends no chain script" do
    error = assert_raises(Driver::StepError) { @driver.create_contest }

    assert_equal Driver::CREATOR_MISSING, error.message
    assert_includes error.message, Driver::SEED_COMMAND
    assert_includes error.message, "Nothing was written"
    assert_equal 1, @dyno.scripts.size, "only the preflight ran"
    refute_match CHAIN_CALLS, @dyno.scripts.first
  end

  test "the command the refusal names clears the refusal" do
    assert_raises(Driver::StepError) { @driver.create_contest }

    seed!

    assert_equal "qa-rehearsal-x", @driver.create_contest["contest_slug"]
  end

  # One shape a deployed database can hold: a roster rename changes no stored
  # row, so a row seeded before one keeps the wallet under the old address.
  test "a row holding the creator wallet under an older address is adopted, not duplicated" do
    old = User.create!(email: "bot@mcritchie.studio", name: "Alex", web3_solana_address: CREATOR[:wallet])
    assert_raises(Driver::StepError) { @driver.create_contest }

    seed!

    assert_equal old.id, User.find_by!(email: Driver::CREATOR_EMAIL).id
    assert_equal 1, User.where(web3_solana_address: CREATOR[:wallet]).count
    assert_equal "qa-rehearsal-x", @driver.create_contest["contest_slug"]
  end

  test "a missing slate stops create before the chain script" do
    seed!
    Slate.where(name: Driver::SLATE_NAME).delete_all

    error = assert_raises(Driver::StepError) { @driver.create_contest }

    assert_equal Driver::SLATE_MISSING, error.message
    assert(@dyno.scripts.none? { |script| script.include?("Contest.create!") })
  end

  test "a roster row the seed cannot save is refused in a sentence" do
    script = @driver.seed_script.sub("seeded = seed_parked_identities!",
                                     "raise ActiveRecord::RecordInvalid, User.new.tap(&:valid?)")
    refute_equal @driver.seed_script, script

    error = assert_raises(Refused) { silence_warnings { @dyno.call(script) } }

    assert_match(/\Athe roster seed could not save User/, error.message)
  end

  test "the roster seed writes no row the roster does not describe" do
    stranger = User.create!(email: "stranger@example.com")
    stranger.update_columns(web2_solana_address: nil, encrypted_web2_solana_private_key: nil)
    before = stranger.reload.attributes

    seed!

    assert_equal before, stranger.reload.attributes
  end

  test "the server signer and the co-signer are printed, and an unlisted signer is flagged" do
    seed!
    @driver.create_contest
    assert_includes @io.string, "server signs as #{Solana::Keypair.admin.to_base58}"
    assert_includes @io.string, "co-signer #{Solana::Config::MULTISIG_COSIGNER}"
    assert_includes @io.string, "not in this app's SOLANA_MULTISIG_SIGNERS list",
                    "the test key is in no signer list, so the flag must print"
  end

  test "close refuses a contest that has not settled, before any chain call" do
    contest = contests(:one)
    contest.update_columns(onchain_settled: false, onchain_cancelled: false, onchain_closed: false)

    error = Solana::Vault.stub(:new, -> { flunk "close reached the vault on an unsettled contest" }) do
      assert_raises(Refused) { @dyno.call(@driver.close_script(contest.slug)) }
    end

    assert_includes error.message, "has not settled on chain"
    refute contest.reload.onchain_closed
  end

  test "close goes on to the vault once the contest has settled" do
    contest = contests(:one)
    contest.update_columns(onchain_settled: true, onchain_closed: false)
    vault = Struct.new(:closed) { def close_contest(slug) = (self.closed = slug) && "sig-close" }.new

    answer = Solana::Vault.stub(:new, vault) { @dyno.call(@driver.close_script(contest.slug)) }

    assert_equal contest.slug, vault.closed
    assert_equal "sig-close", answer["signature"]
    assert contest.reload.onchain_closed
  end
end
