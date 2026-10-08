require "test_helper"

# COSIGN SUBMITS RUN UNDER Solana::Vault::COSIGN_WAIT_BUDGET (5s).
#
# Each double reads the thread's wait budget at the moment the gem would make
# its RPC calls, so the test measures the budget the submit really ran under,
# and then checks the caller's own budget came back afterwards.
class Solana::VaultCosignWaitBudgetTest < ActiveSupport::TestCase
  KEY = Solana::Client::WAIT_BUDGET_KEY

  class CompleterSpy
    attr_reader :budgets

    def initialize
      @budgets = []
    end

    def complete(signed_wire, **)
      @budgets << Thread.current[KEY]
      Solana::Cosign::Completer::Completed.new(signature: "SIG", wire_base64: signed_wire,
                                               confirmation_status: "confirmed")
    end
  end

  class BroadcastClient
    attr_reader :budgets

    def initialize
      @budgets = []
    end

    def simulate_transaction(_wire, **)
      @budgets << [:simulate, Thread.current[KEY]]
      { "value" => { "err" => nil } }
    end

    def send_and_confirm(_wire)
      @budgets << [:send, Thread.current[KEY]]
      nil
    end
  end

  def vault_with(client: Object.new, completer: nil)
    vault = Solana::Vault.allocate
    vault.instance_variable_set(:@client, client)
    vault.define_singleton_method(:cosign_completer) { completer } if completer
    vault
  end

  test "the cosign budget is 5 seconds" do
    assert_equal 5, Solana::Vault::COSIGN_WAIT_BUDGET
  end

  %i[cosign_and_broadcast_entry cosign_and_broadcast_create_contest cosign_and_broadcast_contest_time].each do |submit|
    test "#{submit} completes under the cosign budget, and restores the caller's" do
      spy = CompleterSpy.new

      # The caller's budget is deliberately NOT 5, so a submit that forgot its
      # own block would show the caller's 9.0 here instead of passing by luck.
      Solana::Client.with_wait_budget(9) do
        assert_equal "SIG", vault_with(completer: spy).public_send(submit, "WIRE", expectation: :exp)
        assert_equal 9.0, Thread.current[KEY], "the caller's budget is back once the submit ends"
      end

      assert_equal [5.0], spy.budgets
    end
  end

  test "a cosign submit runs outside a request deadline that has passed" do
    spy = CompleterSpy.new
    spy.define_singleton_method(:complete) do |wire, **opts|
      (@seen ||= []) << [Current.rpc_long_budget, Solana::Deadline.remaining]
      super(wire, **opts)
    end

    Solana::Deadline.within(0) do
      assert_operator Solana::Deadline.remaining, :<=, 0, "CONTROL: outside the submit the deadline has passed"
      vault_with(completer: spy).cosign_and_broadcast_entry("WIRE", expectation: :exp)
    end

    assert_equal [[:cosign_submit, nil]], spy.instance_variable_get(:@seen)
  end

  test "simulate_and_broadcast simulates and sends under the cosign budget" do
    client = BroadcastClient.new

    vault_with(client: client).simulate_and_broadcast("WIRE")

    assert_equal [[:simulate, 5.0], [:send, 5.0]], client.budgets
    assert_nil Thread.current[KEY], "no budget leaks out of the submit"
  end

  test "CONTROL: the same completer, called without the Vault wrapper, sees no budget" do
    # So the 5.0 above comes from the submit method, not from the spy or a leak.
    spy = CompleterSpy.new
    vault_with(completer: spy).send(:cosign_completer).complete("WIRE", expectation: :exp)

    assert_equal [nil], spy.budgets
  end
end
