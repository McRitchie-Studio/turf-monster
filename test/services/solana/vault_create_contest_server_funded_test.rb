# frozen_string_literal: true

require "test_helper"

# THE LINE Solana::Vault#create_contest_server_funded DRAWS FOR ITS CALLER
# (contest-create-checks-before-delete).
#
# Contest#create_onchain_with_rollback! deletes its row on a failure that sent
# nothing and must keep it on one that may have landed. This file drives the
# REAL method against a stub RPC client and pins where that line sits:
#
#   build → signature → simulate      provably un-sent; a refusal is
#                                     Cosign::PreflightRejected; before_send
#                                     has NOT been called
#   before_send(signature)            the caller writes the signature down
#   send → confirm                    may have landed; ANY error, whichever
#                                     class the gem raised, comes out as
#                                     Cosign::BroadcastFailed carrying the
#                                     signature
#
# It is also the third row of test/services/solana/vault_simulate_callers_test.rb:
# the settings this caller passes to #simulate_wire! are pinned here.
class Solana::VaultCreateContestServerFundedTest < ActiveSupport::TestCase
  BLOCKHASH = Solana::Keypair.encode_base58("\x07".b * 32)

  class StubRpc
    attr_reader :events, :simulate_opts

    def initialize(simulation: { "err" => nil }, simulate_raises: nil, send_raises: nil, status: nil)
      @simulation = simulation
      @simulate_raises = simulate_raises
      @send_raises = send_raises
      @status = status || { "err" => nil, "confirmationStatus" => "confirmed" }
      @events = []
    end

    def get_latest_blockhash(**) = BLOCKHASH

    def simulate_transaction(_wire, **opts)
      @events << :simulate
      @simulate_opts = opts
      raise @simulate_raises if @simulate_raises

      @simulation
    end

    def send_transaction(_wire, **)
      @events << :send
      raise @send_raises if @send_raises

      "node-sig"
    end

    def confirm_transaction(_sig, **)
      { "value" => [@status] }
    end

    def sent? = @events.include?(:send)
  end

  def vault_with(client)
    vault = Solana::Vault.new(client: client)
    vault.define_singleton_method(:sleep) { |*| nil }
    vault
  end

  def create!(vault, before_send: nil)
    vault.create_contest_server_funded(
      contest_slug: "server-funded-line", entry_fee_by_currency: [19_000_000, 19_000_000],
      max_entries: 5, payout_amounts: [50_000_000], prize_pool: 50_000_000,
      season_id: 1, lock_timestamp: 0, before_send: before_send
    )
  end

  def http_error(status)
    Solana::Client::HttpError.new("HTTP #{status} from RPC: upstream error", code: status)
  end

  # ── Provably un-sent ──────────────────────────────────────────────────────

  test "simulates before it sends, with the settings every #simulate_wire! caller uses" do
    client = StubRpc.new
    create!(vault_with(client))

    assert_equal %i[simulate send], client.events
    assert_equal({ sig_verify: false, replace_recent_blockhash: true }, client.simulate_opts)
  end

  test "a refused simulation is PreflightRejected, sends nothing, and never calls before_send" do
    client = StubRpc.new(simulation: { "err" => { "InstructionError" => [0, { "Custom" => 1 }] }, "logs" => [] })
    stamped = []

    error = assert_raises(Solana::Cosign::PreflightRejected) { create!(vault_with(client), before_send: ->(s) { stamped << s }) }

    assert_match(/\Acreate_contest pre-flight simulation failed/, error.message)
    assert_not client.sent?
    assert_empty stamped, "nothing was sent, so there is nothing for the caller to write down"
  end

  test "a simulation that cannot be run is PreflightRejected too — still un-sent" do
    client = StubRpc.new(simulate_raises: http_error(503))

    error = assert_raises(Solana::Cosign::PreflightRejected) { create!(vault_with(client)) }

    assert_match(/simulation could not be run/, error.message)
    assert_not client.sent?
  end

  # Contests::PendingReconciler deletes a held row once its signature is unseen
  # past the blockhash window. That is a proof only for a recent-blockhash
  # wire: a durable-nonce wire stays landable until the nonce advances. So this
  # create must never anchor on the nonce, even where one is configured.
  test "anchors on a recent blockhash even when a durable nonce is configured" do
    client = StubRpc.new
    client.define_singleton_method(:get_account_info) { |*| flunk "read the durable nonce account" }

    with_env("SOLANA_DURABLE_NONCE_PUBKEY" => Solana::Keypair.encode_base58("\x05".b * 32)) do
      create!(vault_with(client))
    end

    assert_equal %i[simulate send], client.events
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  # ── The signature is handed over before the bytes leave ──────────────────

  test "before_send receives the wire's own signature, after the simulation and before the send" do
    client = StubRpc.new
    vault = vault_with(client)
    seen = nil

    result = create!(vault, before_send: ->(sig) { seen = [sig, client.events.dup] })

    assert_equal %i[simulate], seen.last, "stamped after the simulation passed, before the send"
    assert_equal result[:tx_signature], seen.first, "the stamp is the signature the method returns"
    assert_equal Solana::Keypair.encode_base58(vault.contest_pda("server-funded-line").first), result[:contest_pda]
  end

  test "a before_send that raises stops the send" do
    client = StubRpc.new

    assert_raises(ActiveRecord::StatementInvalid) do
      create!(vault_with(client), before_send: ->(_) { raise ActiveRecord::StatementInvalid, "db down" })
    end
    assert_not client.sent?, "a signature that could not be written down must not go out"
  end

  # ── May have landed ───────────────────────────────────────────────────────

  {
    "the old RpcError" => -> { Solana::Client::RpcError.new("Network error: Net::ReadTimeout") },
    "the new HttpError (503)" => -> { http_error(503) },
    "a 429 that outlived the retries" => -> { http_error(429) },
    "a raw socket error" => -> { Errno::ECONNRESET.new }
  }.each do |label, error|
    test "a send that raises #{label} comes out as BroadcastFailed with the signature" do
      client = StubRpc.new(send_raises: instance_exec(&error))
      stamped = nil

      raised = assert_raises(Solana::Cosign::BroadcastFailed) { create!(vault_with(client), before_send: ->(s) { stamped = s }) }

      assert_equal stamped, raised.signature, "the caller can reconcile the very signature it wrote down"
      assert_match(/may have landed/, raised.message)
    end
  end

  test "an on-chain err after the send is BroadcastFailed too — the caller asks the chain, not the message" do
    client = StubRpc.new(status: { "err" => { "InstructionError" => [0, "Custom"] }, "confirmationStatus" => "confirmed" })

    raised = assert_raises(Solana::Cosign::BroadcastFailed) { create!(vault_with(client)) }

    assert raised.signature.present?
  end
end
