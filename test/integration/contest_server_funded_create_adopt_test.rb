# frozen_string_literal: true

require "test_helper"

# A SERVER-FUNDED CREATE THAT LANDED BUT ERRORED IS ADOPTED, NOT DELETED
# (contest-create-checks-before-delete).
#
# End to end through the real pieces: Contest#create_onchain_with_rollback! →
# the REAL Solana::Vault#create_contest_server_funded (simulate, write-ahead,
# send) → Contests::PendingReconciler reading the chain. Only the RPC client is
# stubbed, and it plays a chain on which the send's answer was lost: the
# transaction went through, the reply did not.
#
# Before this task the row was destroyed on that error, leaving a funded
# on-chain contest with no Rails row.
class ContestServerFundedCreateAdoptTest < ActiveSupport::TestCase
  BLOCKHASH = Solana::Keypair.encode_base58("\x09".b * 32)

  # The chain as the RPC reports it. `landed:` puts the Contest account at its
  # PDA once the send has been attempted; `send_raises:` is what the client
  # raises from sendTransaction regardless.
  class ChainRpc
    attr_reader :sends

    def initialize(landed:, send_raises:, simulation: { "err" => nil })
      @landed = landed
      @send_raises = send_raises
      @simulation = simulation
      @sends = 0
      @accounts = {}
    end

    def get_latest_blockhash(**) = BLOCKHASH
    def simulate_transaction(_wire, **) = @simulation

    def send_transaction(_wire, **)
      @sends += 1
      @accounts[:contest] = true if @landed
      raise @send_raises
    end

    def confirm_transaction(_sig, **)
      { "value" => [nil] } # the status lookup has not indexed it (or it never landed)
    end

    def get_account_info(_pda, **)
      { "value" => (@accounts[:contest] ? { "data" => ["", "base64"], "owner" => "program" } : nil) }
    end
  end

  def http_error(status)
    Solana::Client::HttpError.new("HTTP #{status} from RPC: upstream error", code: status)
  end

  def vault_on(rpc)
    vault = Solana::Vault.new(client: rpc)
    vault.define_singleton_method(:sleep) { |*| nil }
    vault
  end

  def new_contest(slug)
    Contest.create!(
      name: slug.titleize, slug: slug, slate: slates(:one), status: :open,
      contest_type: "small", entry_fee_cents: 19_00, max_entries: 5
    )
  end

  def run_create(contest, vault)
    Solana::Vault.stub(:new, vault) { contest.create_onchain_with_rollback! }
  end

  {
    "the new HttpError (502 after the gem's retries)" => -> { http_error(502) },
    "the old RpcError (read timeout)" => -> { Solana::Client::RpcError.new("Network error: Net::ReadTimeout") }
  }.each_with_index do |(label, error), i|
    test "a stubbed create that landed but errored with #{label} is adopted from chain" do
      contest = new_contest("landed-but-errored-#{i}")
      rpc = ChainRpc.new(landed: true, send_raises: instance_exec(&error))
      vault = vault_on(rpc)

      run_create(contest, vault) # adopted: create! returns normally

      contest.reload
      assert_equal "open", contest.status, "adopted with the status the caller asked for"
      assert_equal Solana::Keypair.encode_base58(vault.contest_pda(contest.slug).first), contest.onchain_contest_id
      assert contest.onchain_tx_signature.present?, "the signature written ahead of the send is kept"
      assert contest.accepts_usdt?
      assert_equal 1, rpc.sends, "adopting reads the chain; it never sends the create again"
    end
  end

  # ── CONTROLS: the same failure on a chain that says otherwise ─────────────

  test "CONTROL — the same error with nothing on chain keeps the row pending, then the sweep removes it on a confirmed miss" do
    contest = new_contest("errored-not-landed")
    rpc = ChainRpc.new(landed: false, send_raises: http_error(503))
    vault = vault_on(rpc)

    assert_raises(Contest::OnchainCreateUncertain) { run_create(contest, vault) }
    assert_equal "pending", contest.reload.status, "not adopted (nothing is there) and not deleted (it may still land)"

    travel 15.minutes do
      stats = Contests::PendingReconciler.run(vault: vault)
      assert_equal 1, stats[:deleted], "no PDA and the signature still unseen past its blockhash window"
    end
    assert_not Contest.exists?(contest.id)
  end

  test "CONTROL — a refused simulation deletes the row and sends nothing" do
    contest = new_contest("refused-before-send")
    rpc = ChainRpc.new(landed: true, send_raises: http_error(503),
                       simulation: { "err" => { "InstructionError" => [0, { "Custom" => 1 }] } })

    assert_raises(RuntimeError) { run_create(contest, vault_on(rpc)) }

    assert_not Contest.exists?(contest.id)
    assert_equal 0, rpc.sends
  end
end
