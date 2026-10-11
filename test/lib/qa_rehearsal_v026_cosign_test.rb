# frozen_string_literal: true

require "test_helper"

# The QA rehearsal on turf-vault v0.26. The dyno holds one vault key, and
# v0.26 asks two for a lock and a close (three for a settle), so each step asks
# the dyno what the chain needs, picks seated agent keys the driver files, gets
# a server-signed wire with their slots, and signs here.
#
# The driver's real scripts run in this process against a vault whose chain
# reads are stubbed. The broadcast wire is decoded: every slot filled, signers
# in order. v0.25 runs the scripts it always ran and loads no agent key.
class QaRehearsalV026CosignTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver
  ID = Solana::Governance::ACTION_IDS
  EMPTY = ("\x00" * 64).b

  AGENTS = { "mason" => Solana::Keypair.generate, "mack" => Solana::Keypair.generate }.freeze

  class Keys
    attr_reader :loaded

    def initialize(agents)
      @agents = agents
      @loaded = []
    end

    def keypair(who)
      @loaded << who
      @agents.fetch(who)
    end
  end

  class Broadcasts
    attr_reader :wires

    def initialize = @wires = []

    def send_and_confirm(wire)
      @wires << wire
      "sig-#{@wires.size}"
    end
  end

  # Runs a script here with RemoteRunner's helpers. `exit` ends the script.
  class LocalDyno
    attr_reader :scripts

    def initialize = @scripts = []

    def call(source)
      @scripts << source
      answer = nil
      host = Object.new
      host.define_singleton_method(:emit) { |payload| answer = JSON.parse(payload.to_json) }
      host.define_singleton_method(:refuse) { |message| raise message }
      begin
        host.instance_eval(source)
      rescue SystemExit
        nil
      end
      answer
    end
  end

  def fake_client
    Object.new.tap do |c|
      c.define_singleton_method(:get_latest_blockhash) { |**| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
      c.define_singleton_method(:get_account_info) { |*_args, **_kw| { "value" => nil } }
    end
  end

  # A vault whose chain answers: who is seated, the stored thresholds, and a
  # contest whose lock is still in the future.
  def chain_vault(seated:, thresholds: Array.new(32, 0))
    server_locks = @server_locks
    Solana::Vault.new(client: fake_client).tap do |v|
      v.define_singleton_method(:read_vault_state) { |**| { active_signers: seated } }
      v.define_singleton_method(:cached_governance) { { thresholds: thresholds } }
      v.define_singleton_method(:read_contest) { |_slug, **| { lock_timestamp: 2_000_000_000, conclusion_timestamp: 0 } }
      v.define_singleton_method(:set_contest_lock_time) { |slug, _ts, **| server_locks << slug }
      v.define_singleton_method(:close_contest) { |_slug, **| raise "v0.26 must not close server-signed" }
    end
  end

  setup do
    @contest = contests(:one)
    @dyno = LocalDyno.new
    @keys = Keys.new(AGENTS)
    @broadcasts = Broadcasts.new
    @server_locks = []
    @driver = Driver.new(io: StringIO.new)
    @driver.instance_variable_set(:@remote, @dyno)
    @driver.instance_variable_set(:@keys, @keys)
  end

  def run_step(governance:, vault:, &step)
    Solana::Config.stub(:governance?, governance) do
      Solana::Config.stub(:client, @broadcasts) do
        Solana::Vault.stub(:new, vault, &step)
      end
    end
  end

  def signer_keys(wire)
    message = Solana::WireMessage.parse_base64(wire)
    [message.account_keys.first(message.num_required_signatures).map { |k| Solana::Keypair.encode_base58(k) },
     message.signatures]
  end

  def admin = Solana::Keypair.admin.to_base58

  def mason = AGENTS["mason"].to_base58

  def mack = AGENTS["mack"].to_base58

  # ── lock ─────────────────────────────────────────────────────────────────

  test "v0.25 locks server-signed in one script and loads no agent key" do
    run_step(governance: false, vault: chain_vault(seated: [admin])) { @driver.lock_contest(@contest.slug) }

    assert_equal 1, @dyno.scripts.size
    assert_equal [@contest.slug], @server_locks
    assert_empty @keys.loaded
    assert_empty @broadcasts.wires
  end

  test "v0.26 lock is signed by the server and one seated agent" do
    vault = chain_vault(seated: [admin, mason])
    run_step(governance: true, vault: vault) { @driver.lock_contest(@contest.slug) }

    assert_equal 3, @dyno.scripts.size, "request, build, record"
    assert_empty @server_locks
    assert_equal 1, @broadcasts.wires.size
    signers, signatures = signer_keys(@broadcasts.wires.first)
    assert_equal [admin, mason], signers
    refute_includes signatures, EMPTY, "every slot is filled before the send"
    assert @contest.reload.locked?
  end

  test "v0.26 refuses by name when too few agents are seated, and sends nothing" do
    vault = chain_vault(seated: [admin, mack], thresholds: Array.new(32, 0).tap { |t| t[ID["set_contest_lock_time"]] = 3 })

    error = assert_raises(Driver::StepError) do
      run_step(governance: true, vault: vault) { @driver.lock_contest(@contest.slug) }
    end
    assert_match(/set_contest_lock_time needs 2 agent signature/, error.message)
    assert_empty @broadcasts.wires
  end

  # ── close ────────────────────────────────────────────────────────────────

  test "v0.26 close follows a retune: three on chain means two agents" do
    @contest.update_columns(onchain_settled: true, onchain_closed: false)
    vault = chain_vault(seated: [admin, mason, mack],
                        thresholds: Array.new(32, 0).tap { |t| t[ID["close_contest"]] = 3 })
    @driver.instance_variable_set(:@manifest, Struct.new(:slug) { def read = { "contest_slug" => slug } }.new(@contest.slug))
    @driver.define_singleton_method(:guard!) { true }

    run_step(governance: true, vault: vault) { @driver.close_contest }

    signers, signatures = signer_keys(@broadcasts.wires.first)
    assert_equal [admin, mason, mack], signers
    refute_includes signatures, EMPTY
    assert @contest.reload.onchain_closed?
  end

  # ── settle ───────────────────────────────────────────────────────────────

  test "v0.26 settle build asks for the extra signer before it builds" do
    vault = chain_vault(seated: [admin, mason, mack])
    answer = run_step(governance: true, vault: vault) do
      @dyno.call(@driver.send(:settle_build_script, @contest.slug, mason))
    end

    assert_equal({ "action" => "settle_contest", "needed" => 1, "server" => admin,
                   "seated" => [admin, mason, mack] }, answer["cosign"])
    assert_equal [mack], @driver.send(:pick_agents, answer["cosign"], exclude: [mason]).map(&:to_base58)
  end

  test "v0.25 settle build is the two-signer wire it always was" do
    answer = run_step(governance: false, vault: chain_vault(seated: [admin])) do
      @dyno.call(@driver.send(:settle_build_script, @contest.slug, mason))
    end

    signers, = signer_keys(answer.fetch("serialized_tx"))
    assert_equal [admin, mason], signers
  end
end
