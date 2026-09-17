require "test_helper"

# THE ORDERING THIS TASK EXISTS TO PIN: the signature is recorded BEFORE the
# bytes leave, not after.
#
# THE DEFECT. `ContestsController#confirm_onchain_entry` used to broadcast and
# then stamp `PendingTransaction#tx_signature` twelve lines later. A crash, a
# dyno restart or a failed `update!` anywhere in that window left a row that
# reads "never broadcast" for money that had already moved — and
# `recover_pending_entry` reads a blank PendingTransaction exactly that way, so
# the player is invited to enter and pay a second time. "The broadcast raised,
# therefore nothing was sent" is not sound either: `Solana::Client#call` retries
# the faults that mean "the request went out and the answer was lost", so the
# exception a caller finally sees can follow an attempt that already forwarded
# the wire.
#
# THE FIX IS STRUCTURAL, not a moved line. `Cosign::Completer#complete` takes a
# `before_send:` callback and invokes it after every check that can refuse the
# wire and BEFORE `send_transaction`. The signature is knowable without asking
# the RPC anything — it is the first signature inside the cosigned wire — so
# there is nothing to wait for.
#
# A COMMENT ASKING THE NEXT EDITOR NOT TO MOVE A LINE IS NOT A GUARANTEE. These
# tests record the actual call ORDER and assert on it, so re-introducing the gap
# fails here rather than in production.
class Solana::CosignBeforeSendOrderingTest < ActiveSupport::TestCase
  # A client that records the order of everything the completer asks it to do.
  class RecordingClient
    attr_reader :journal

    def initialize(send_raises: nil)
      @journal = []
      @send_raises = send_raises
    end

    def get_block_height(commitment: nil)
      @journal << :get_block_height
      1
    end

    def simulate_transaction(_wire, **_opts)
      @journal << :simulate
      { "err" => nil, "logs" => [] }
    end

    def send_transaction(_wire, **_opts)
      @journal << :send
      raise @send_raises if @send_raises

      nil
    end

    def confirm_transaction(_signature)
      @journal << :confirm
      { "value" => [{ "err" => nil, "confirmationStatus" => "confirmed" }] }
    end
  end

  def setup
    @house  = Solana::Keypair.generate
    @player = Solana::Keypair.generate
  end

  # Build a real cosigned wire: the house is fee payer, the player signs its own
  # slot, and the house's slot is left for the completer to fill.
  def prepared_and_signed
    builder = Solana::Cosign::Builder.new(client: CosignFakeClient.build, fee_payer: @house)
    prepared = builder.build(
      instructions: [{
        program_id: Solana::Keypair.generate.public_key_bytes,
        accounts: [{ pubkey: @player.public_key_bytes, is_signer: true, is_writable: true }],
        data: "\x01\x02\x03".b
      }],
      cosigners: [@player],
      compute_unit_price: 50_000,
      compute_unit_limit: 200_000
    )
    # `require_complete: false` — this is the WALLET's signature, filling only the
    # player's slot. The house's slot stays empty on purpose; filling it is the
    # completer's job and is the thing under test.
    signed = Solana::Transaction.cosign_wire_base64(prepared.wire_base64, signer: @player,
                                                    require_complete: false)
    [prepared, signed]
  end

  test "before_send runs AFTER every refusable check and BEFORE the send" do
    prepared, signed = prepared_and_signed
    client = RecordingClient.new
    completer = Solana::Cosign::Completer.new(client: client, fee_payer: @house, poll_interval: 0,
                                              sleeper: ->(_s) { })

    # The stamp is recorded into the SAME journal as the RPC calls, so the
    # assertion below is about the interleaving itself and not about two lists
    # that happen to agree.
    completer.complete(signed, expectation: prepared.expectation,
                               before_send: ->(_sig) { client.journal << :stamped })

    assert_equal %i[get_block_height simulate stamped send confirm], client.journal,
                 "deadline check, then simulation, then THE STAMP, then the send, then confirm — " \
                 "the stamp sits before the send, which is the whole defect this closes"
  end

  test "the stamp HAPPENS when the send then fails — the bytes may be on chain" do
    prepared, signed = prepared_and_signed
    client = RecordingClient.new(send_raises: RuntimeError.new("connection reset"))
    completer = Solana::Cosign::Completer.new(client: client, fee_payer: @house, poll_interval: 0,
                                              sleeper: ->(_s) { })

    stamped = []
    error = assert_raises(Solana::Cosign::BroadcastFailed) do
      completer.complete(signed, expectation: prepared.expectation,
                                 before_send: ->(sig) { stamped << sig })
    end

    assert_equal 1, stamped.length,
                 "THE WHOLE POINT: a send that failed must still have recorded its signature, " \
                 "because a failed send is not proof that nothing was sent"
    assert_equal stamped.first, error.signature,
                 "the error carries the same signature that was stamped, so the row can be reconciled"
    assert_includes client.journal, :send
  end

  test "the stamp does NOT happen when the wire is refused — nothing was signed or sent" do
    prepared, signed = prepared_and_signed
    client = RecordingClient.new

    # An expectation for a DIFFERENT transaction: the returned wire cannot match
    # it, so verify! refuses before the fee payer's key is ever used.
    other = Solana::Cosign::Builder.new(client: CosignFakeClient.build, fee_payer: @house).build(
      instructions: [{ program_id: Solana::Keypair.generate.public_key_bytes,
                       accounts: [{ pubkey: @player.public_key_bytes, is_signer: true, is_writable: true }],
                       data: "\xFF".b }],
      cosigners: [@player], compute_unit_price: 50_000, compute_unit_limit: 200_000
    )

    completer = Solana::Cosign::Completer.new(client: client, fee_payer: @house, poll_interval: 0,
                                              sleeper: ->(_s) { })
    stamped = []
    assert_raises(Solana::Cosign::WireRejected) do
      completer.complete(signed, expectation: other.expectation,
                                 before_send: ->(sig) { stamped << sig })
    end

    assert_empty stamped, "a refused wire must leave no signature — it was never signed"
    assert_empty client.journal, "and must cost no RPC call at all"
  end

  test "a raising before_send stops the send: the stamp is a precondition, not a side effect" do
    prepared, signed = prepared_and_signed
    client = RecordingClient.new
    completer = Solana::Cosign::Completer.new(client: client, fee_payer: @house, poll_interval: 0,
                                              sleeper: ->(_s) { })

    assert_raises(ActiveRecord::RecordInvalid) do
      completer.complete(signed, expectation: prepared.expectation,
                                 before_send: ->(_sig) { raise ActiveRecord::RecordInvalid })
    end

    refute_includes client.journal, :send,
                    "if the row could not be stamped, the transaction must not be broadcast — " \
                    "otherwise the unrecorded-broadcast gap is back by another route"
  end

  test "CONTROL — the ordering assertion bites when before_send is dropped" do
    # Proves the first test is not vacuous: a completer that never calls
    # before_send records no stamp, and the assertion that catches that is the
    # one doing the work.
    prepared, signed = prepared_and_signed
    client = RecordingClient.new
    completer = Solana::Cosign::Completer.new(client: client, fee_payer: @house, poll_interval: 0,
                                              sleeper: ->(_s) { })

    stamped = []
    completer.complete(signed, expectation: prepared.expectation, before_send: nil)
    assert_empty stamped, "no callback, no stamp — so the passing test above measures the callback"
    assert_includes client.journal, :send
  end
end
