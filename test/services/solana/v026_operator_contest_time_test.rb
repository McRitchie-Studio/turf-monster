require "test_helper"

# [unit] The OPERATOR (Phantom-first) contest lock and conclusion carry the
# signer turf-vault v0.26 demands.
#
# THE DEFECT. v0.26 raised `set_contest_lock_time` and
# `set_contest_conclusion_time` to 2 vault signatures (SET_CONTEST_LOCK_TIME,
# SET_CONTEST_CONCLUSION_TIME). The operator builder named the operator's
# Phantom as `admin` and `cosigner: None`, with no remaining accounts, so
# `authorize` wanted one more signer and found none: 6046 InsufficientSigners
# on every lock and every conclusion the moment the switch flipped.
#
# THE FIX. On a governance boot the named `cosigner` slot carries the SERVER's
# key — the fee payer, which already fills account 0 after Phantom signs — when
# the chain's threshold for the action the contest's state selects is 2. These
# tests pin the account list both ways, and that the escalated actions (3) are
# refused in Rails before Phantom opens. The instruction landing on a real v0.26
# program is proven by test/integration/turf_vault_v026_local_validator_test.rb.
class Solana::V026OperatorContestTimeTest < ActiveSupport::TestCase
  SLUG = "v026-operator-contest-time".freeze
  TS = 1_900_000_000

  class StubRpc
    def initialize = CosignFakeClient.teach(self)
    def get_latest_blockhash(**_opts) = @blockhash ||= Solana::Keypair.generate.to_base58
  end

  def setup
    @operator = Solana::Keypair.generate
    @server = Solana::Keypair.admin
    @vault = Solana::Vault.new(client: StubRpc.new)
    chain(lock: Time.current.to_i + 3600, conclusion: 0, thresholds: nil)
  end

  # What the chain holds: the contest's two timestamps and the stored table.
  def chain(lock:, conclusion:, thresholds:)
    contest = { lock_timestamp: lock, conclusion_timestamp: conclusion }
    table = thresholds && { thresholds: thresholds }
    @vault.define_singleton_method(:read_contest) { |_slug| contest }
    @vault.define_singleton_method(:cached_governance) { table }
  end

  def accounts(instruction = "set_contest_lock_time")
    @vault.contest_time_instruction(instruction, SLUG, TS, admin_pubkey: @operator.address)[:accounts]
  end

  def with_governance(on = true, &block)
    Solana::Config.stub(:governance?, on, &block)
  end

  def program_id
    Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID)
  end

  test "v0.25: cosigner is None and nothing is read from the chain" do
    @vault.define_singleton_method(:read_contest) { |_slug| raise "v0.25 must not read the contest" }
    with_governance(false) do
      metas = accounts
      assert_equal program_id, metas[1][:pubkey], "cosigner: None is the program id"
      refute metas[1][:is_signer]
      assert_equal 4, metas.size, "no governance account on v0.25"
    end
  end

  test "v0.26 lock at the default threshold names the server as the second signer" do
    with_governance do
      metas = accounts
      assert_equal @operator.public_key_bytes, metas[0][:pubkey]
      assert metas[0][:is_signer]
      assert_equal @server.public_key_bytes, metas[1][:pubkey], "the server key fills the named cosigner slot"
      assert metas[1][:is_signer]
      gov, _ = @vault.governance_pda
      assert_equal gov, metas[3][:pubkey], "governance follows vault_state"
    end
  end

  test "v0.26 conclusion at the default threshold names the server too" do
    with_governance do
      metas = accounts("set_contest_conclusion_time")
      assert_equal @server.public_key_bytes, metas[1][:pubkey]
      assert metas[1][:is_signer]
    end
  end

  # The threshold is the chain's: a retune to 1 drops the server again.
  test "a chain threshold of 1 leaves cosigner None" do
    table = Array.new(32, 0).tap { |t| t[Solana::Governance::ACTION_IDS["set_contest_lock_time"]] = 1 }
    chain(lock: Time.current.to_i + 3600, conclusion: 0, thresholds: table)
    with_governance do
      assert_equal program_id, accounts[1][:pubkey]
    end
  end

  test "re-opening a passed lock needs three and is refused before Phantom opens" do
    chain(lock: Time.current.to_i - 60, conclusion: 0, thresholds: nil)
    with_governance do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) { accounts }
      assert_match(/set_contest_lock_time_reopen needs 3/, error.message)
    end
  end

  test "amending a set conclusion needs three and is refused" do
    chain(lock: 0, conclusion: Time.current.to_i + 7200, thresholds: nil)
    with_governance do
      error = assert_raises(Solana::Vault::ThresholdUnreachableError) { accounts("set_contest_conclusion_time") }
      assert_match(/set_contest_conclusion_time_amend needs 3/, error.message)
    end
  end

  test "an operator wallet that IS the server key is refused, not sent as one signer twice" do
    @operator = @server
    with_governance do
      assert_raises(Solana::Vault::ThresholdUnreachableError) { accounts }
    end
  end

  # The wire Phantom receives: the server is a signer only as the fee payer, so
  # the operator still signs once and the completer fills one slot.
  test "the built wire asks Phantom for one signature and the expectation admits it" do
    with_governance do
      built = @vault.build_set_contest_lock_time(SLUG, TS, admin_pubkey: @operator.address)
      message = Solana::WireMessage.parse_base64(built[:serialized_tx])
      assert_equal [@server.public_key_bytes, @operator.public_key_bytes].sort, message.signer_keys.sort

      signed = Solana::Transaction.cosign_wire_base64(built[:serialized_tx], signer: @operator, require_complete: false)
      expectation = @vault.contest_time_expectation("set_contest_lock_time", SLUG, TS, admin_pubkey: @operator.address)
      assert expectation.verify!(Solana::WireMessage.parse_base64(signed))
    end
  end
end
