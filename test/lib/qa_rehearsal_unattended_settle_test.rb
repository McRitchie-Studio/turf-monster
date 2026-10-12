# frozen_string_literal: true

require "test_helper"

# The unattended devnet settle (conclude --cosign agent). It confirms on the
# dyno with the same primitives Admin::PendingTransactionsController#confirm
# runs. The scripts run here against a stubbed chain; the wire is decoded and
# the row and contest are read back.
class QaRehearsalUnattendedSettleTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

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

  class Broadcasts
    attr_reader :wires

    def initialize = @wires = []

    def send_and_confirm(wire)
      @wires << wire
      "sig-settle"
    end
  end

  def fake_client
    Object.new.tap do |c|
      c.define_singleton_method(:get_latest_blockhash) { |**| Solana::Keypair.encode_base58((1..32).to_a.pack("C*")) }
      c.define_singleton_method(:get_account_info) { |*_a, **_k| { "value" => nil } }
    end
  end

  setup do
    @mack = Solana::Keypair.generate
    @admin = Solana::Keypair.admin.to_base58
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_ptx")
    @contest.update_columns(status: "settlement_pending")
    @ptx = PendingTransaction.create!(tx_type: "settle_contest", serialized_tx: "OLD_TX", status: "pending",
                                      target: @contest, initiator_address: "init",
                                      metadata: { settlements: [] }.to_json)
    @dyno = LocalDyno.new
    @broadcasts = Broadcasts.new
    @verified = []
    mack = @mack
    @driver = Driver.new(io: StringIO.new)
    @driver.instance_variable_set(:@remote, @dyno)
    @driver.instance_variable_set(:@keys, Struct.new(:kp) { def keypair(_who) = kp }.new(mack))
    @driver.instance_variable_set(:@mainnet_fence, TurfMonster::QaRehearsal::MainnetSignerFence.default)
    @driver.instance_variable_set(:@manifest, Struct.new(:slug) { def read = { "contest_slug" => slug } }.new(@contest.slug))
  end

  # Settle at 2 on chain (devnet's retune): the server plus one agent.
  def chain_vault(settle_threshold: 2, seated:)
    thresholds = Array.new(32, 0).tap { |t| t[Solana::Governance::ACTION_IDS["settle_contest"]] = settle_threshold }
    Solana::Vault.new(client: fake_client).tap do |v|
      v.define_singleton_method(:read_vault_state) { |**| { active_signers: seated } }
      v.define_singleton_method(:cached_governance) { { thresholds: thresholds } }
    end
  end

  def settle(vault:, signers:)
    verified = @verified
    Solana::Config.stub(:governance?, true) do
      Solana::Config.stub(:client, @broadcasts) do
        stub_const_signers(signers) do
          Solana::TxVerifier.stub(:verify!, ->(**kw) { verified << kw; true }) do
            Solana::Vault.stub(:new, vault) { @driver.send(:cosign_with_agent, { "ptx_slug" => @ptx.slug }) }
          end
        end
      end
    end
  end

  def stub_const_signers(list, &block)
    old = Solana::Config::MULTISIG_SIGNERS
    Solana::Config.send(:remove_const, :MULTISIG_SIGNERS)
    Solana::Config.const_set(:MULTISIG_SIGNERS, list.freeze)
    block.call
  ensure
    Solana::Config.send(:remove_const, :MULTISIG_SIGNERS)
    Solana::Config.const_set(:MULTISIG_SIGNERS, old)
  end

  test "settles with the server and one devnet agent, verifies, and records the row and the contest" do
    result = settle(vault: chain_vault(seated: [@admin, @mack.to_base58]), signers: [@admin, @mack.to_base58])

    message = Solana::WireMessage.parse_base64(@broadcasts.wires.first)
    signers = message.account_keys.first(message.num_required_signatures).map { |k| Solana::Keypair.encode_base58(k) }
    assert_equal [@admin, @mack.to_base58], signers, "the server leads; the agent is the named cosigner"
    refute_includes message.signatures, ("\x00" * 64).b

    assert_equal [@mack.to_base58], @verified.map { |kw| kw[:signer_pubkey] }
    assert_equal "settle_contest", @verified.first[:instruction_name]
    assert_equal "onchain_ptx", @verified.first[:writable_pubkey], "the contest PDA is asserted writable"

    @ptx.reload
    assert_equal "confirmed", @ptx.status
    assert_equal "sig-settle", @ptx.tx_signature
    assert_equal [@mack.to_base58], @ptx.cosigner_addresses
    assert @contest.reload.onchain_settled?
    assert_equal "settled", @contest.status
    assert_equal "confirmed", result["status"]
  end

  test "a cosigner outside the app's multisig set is refused before the row moves" do
    error = assert_raises(RuntimeError) do
      settle(vault: chain_vault(seated: [@admin, @mack.to_base58]), signers: [@admin])
    end

    assert_match(/not in the multisig set/, error.message)
    assert_equal "pending", @ptx.reload.status
    refute @contest.reload.onchain_settled?
  end

  test "a failed verification leaves the row pending and the contest unsettled" do
    vault = chain_vault(seated: [@admin, @mack.to_base58])
    Solana::Config.stub(:governance?, true) do
      Solana::Config.stub(:client, @broadcasts) do
        stub_const_signers([@admin, @mack.to_base58]) do
          Solana::TxVerifier.stub(:verify!, ->(**) { raise Solana::TxVerifier::VerificationError, "no such tx" }) do
            Solana::Vault.stub(:new, vault) do
              assert_raises(Solana::TxVerifier::VerificationError) do
                @driver.send(:cosign_with_agent, { "ptx_slug" => @ptx.slug })
              end
            end
          end
        end
      end
    end

    assert_equal "pending", @ptx.reload.status
    refute @contest.reload.onchain_settled?
  end

  test "the dyno confirm and the controller confirm verify the same things" do
    script = @driver.send(:confirm_settle_script, "p", "c", [], "s")
    controller = Rails.root.join("app/controllers/admin/pending_transactions_controller.rb").read

    %w[MULTISIG_SIGNERS validate_extras! TxVerifier.verify! mark_settled! cosigner_addresses].each do |step|
      assert_includes script, step
      assert_includes controller, step, "#{step} left the controller: re-read confirm_settle_script against it"
    end
  end
end
