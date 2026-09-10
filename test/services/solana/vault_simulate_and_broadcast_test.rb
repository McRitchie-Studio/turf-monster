require "test_helper"

# Solana::Vault#simulate_and_broadcast — the server-side send that replaced the
# browser's own connection.sendRawTransaction in the multisig cosign flow.
#
# WHY IT EXISTS (mainnet, measured 2026-09-05). The browser could not reliably
# broadcast a cosigned wire, for three reasons at once:
#
#   1. Config.public_rpc_url REFUSES to hand a credentialed endpoint to a
#      browser, and SOLANA_PUBLIC_RPC_URL was unset — so the page fell back to
#      the free, heavily rate-limited public cluster RPC.
#   2. `new solanaWeb3.Connection(url)` defaults to the `finalized` commitment,
#      so sendRawTransaction preflighted a brand-new blockhash against a bank
#      ~32 slots stale and rejected a VALID transaction with BlockhashNotFound.
#   3. The wire was read from a DOM attribute baked at page render, so a second
#      Co-sign click re-sent the SAME expired bytes.
#
# All three surfaced through one catch-all modal that blamed the blockhash, so
# a program error and a throttled RPC were indistinguishable. $140 of
# alpha-contest payouts sat unsent from June to September because of it.
#
# sig_verify:false + replace_recent_blockhash:true mirror
# Vault#cosign_and_broadcast_entry — we want the PROGRAM's verdict out of the
# simulation, not a re-litigation of signatures or blockhash freshness. The
# real broadcast that follows still enforces both.
class Solana::VaultSimulateAndBroadcastTest < ActiveSupport::TestCase
  class StubClient
    attr_reader :simulate_calls, :sent
    def initialize(sim_result)
      @sim_result = sim_result
      @simulate_calls = []
      @sent = []
    end

    def simulate_transaction(wire, **opts)
      @simulate_calls << { wire: wire, opts: opts }
      @sim_result
    end

    def send_and_confirm(wire)
      @sent << wire
      "SIG_#{wire}"
    end
  end

  def vault_with(client)
    vault = Solana::Vault.allocate
    vault.instance_variable_set(:@client, client)
    vault
  end

  test "broadcasts and returns the signature when simulation is clean" do
    client = StubClient.new({ "err" => nil, "logs" => ["Program log: Instruction: SettleContest"] })
    result = vault_with(client).simulate_and_broadcast("WIRE")

    assert_equal "SIG_WIRE", result
    assert_equal ["WIRE"], client.sent
  end

  test "simulates with sig_verify off and a replaced blockhash" do
    client = StubClient.new({ "err" => nil })
    vault_with(client).simulate_and_broadcast("WIRE")

    opts = client.simulate_calls.first[:opts]
    assert_equal false, opts[:sig_verify]
    assert_equal true,  opts[:replace_recent_blockhash]
  end

  test "raises the program error and never broadcasts when simulation fails" do
    client = StubClient.new({
      "err" => { "InstructionError" => [1, "InvalidAccountData"] },
      "logs" => ["Program log: Instruction: SettleContest", "Program log: Error: InvalidAccountData"]
    })

    error = assert_raises(RuntimeError) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_match(/InvalidAccountData/, error.message)
    assert_empty client.sent, "a failing simulation must not reach the chain"
  end

  # The whole point: the operator sees the program's own words. A missing
  # winner token account reads as InvalidAccountData, which tells you to create
  # the account — "the blockhash may have expired" tells you to retry forever.
  test "the raised message carries the program logs, not a blockhash guess" do
    client = StubClient.new({
      "err" => { "InstructionError" => [1, "InvalidAccountData"] },
      "logs" => ["Program log: Error: InvalidAccountData"]
    })

    error = assert_raises(RuntimeError) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_match(/Error: InvalidAccountData/, error.message)
    assert_no_match(/blockhash/i, error.message)
  end
end
