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

    error = assert_raises(Solana::Cosign::PreflightRejected) { vault_with(client).simulate_and_broadcast("WIRE") }

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

    error = assert_raises(Solana::Cosign::PreflightRejected) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_match(/Error: InvalidAccountData/, error.message)
    assert_no_match(/blockhash/i, error.message)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE UN-SENT / MAY-HAVE-SENT SEAM
  # ══════════════════════════════════════════════════════════════════════════
  #
  # `send_and_confirm` is the line. Everything before it is provably un-sent and
  # is typed `PreflightRejected`; everything from it onward is AMBIGUOUS, because
  # a network fault after the wire leaves is indistinguishable here from one
  # before. This method is the only place that knows which side a failure fell
  # on, so it is the only place that can say — and a caller that claimed a
  # PendingTransaction before broadcasting releases the claim on this type and
  # on nothing else. Getting it wrong in either direction is money: release too
  # eagerly and a landed transaction becomes re-broadcastable; never release and
  # a program refusal strands the row.

  class RaisingClient < StubClient
    def initialize(sim_raises: nil, send_raises: nil)
      super({ "err" => nil })
      @sim_raises = sim_raises
      @send_raises = send_raises
    end

    def simulate_transaction(wire, **opts)
      raise @sim_raises if @sim_raises
      super
    end

    def send_and_confirm(wire)
      raise @send_raises if @send_raises
      super
    end
  end

  test "a simulation the program refuses is typed as provably un-sent" do
    client = StubClient.new({ "err" => { "InstructionError" => [1, { "Custom" => 6046 }] } })

    assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).simulate_and_broadcast("WIRE")
    end
    assert_empty client.sent
  end

  # An unreachable or throttled RPC is as un-sent as a program refusal, and a
  # row stranded on a transient blip is the failure mode of leaving it untyped.
  test "a simulation that could not be RUN at all is typed as provably un-sent" do
    client = RaisingClient.new(sim_raises: "RPC 429 Too Many Requests")

    error = assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).simulate_and_broadcast("WIRE")
    end
    assert_match(/429/, error.message)
    assert_empty client.sent
  end

  # THE ONE THAT MUST NOT BE TYPED UN-SENT. The bytes may already be on the
  # chain — and the gem now has a NAME for exactly that, which this app
  # previously expressed as a bare `raise`. `Cosign::BroadcastFailed` is the
  # "reconcile before rebuilding" side of the seam, and it is a SIBLING of
  # PreflightRejected rather than a subclass, so a rescue of one can never
  # accidentally catch the other.
  test "a failure during the send is NOT typed un-sent" do
    client = RaisingClient.new(send_raises: "connection reset")

    error = assert_raises(Solana::Cosign::BroadcastFailed) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_not_kind_of Solana::Vault::PreflightRejected, error,
                       "a fault after the wire may have left must never read as provably un-sent"
    assert_match(/connection reset/, error.message)
    assert_match(/reconcile/, error.message,
                 "the type carries its own instruction: this row keeps its claim and asks the chain")
  end

  # THE CLAIM THIS TEST MAKES CHANGED, BECAUSE THE TYPE DID.
  #
  # It used to assert `PreflightRejected < RuntimeError`. That was true when this
  # app declared the class itself, and it was asserted for one reason: every
  # existing `rescue StandardError` chain and every operator-facing message path
  # predates the type and must be unchanged by it.
  #
  # `Vault::PreflightRejected` is now an alias for the gem's
  # `Cosign::PreflightRejected`, whose chain is `Cosign::Error < StandardError`.
  # RuntimeError is no longer in it. The PROPERTY the old assertion protected is
  # untouched — StandardError is what every one of those rescues names — so the
  # assertion is retargeted at the property rather than at the old spelling of
  # it, and the second half proves the claim is worth making by checking that
  # nothing in this app ever narrowed a rescue to RuntimeError.
  test "the typed refusal is still a StandardError, so every existing rescue chain still catches it" do
    assert_operator Solana::Vault::PreflightRejected, :<, StandardError
    assert_operator Solana::Vault::PreflightUnavailable, :<, Solana::Cosign::PreflightRejected,
                    "the no-verdict subtype must stay catchable by a plain PreflightRejected rescue"
    assert_operator Solana::Cosign::BroadcastFailed, :<, StandardError

    # The seam itself: the ambiguous half must NOT be catchable as the provable
    # half, or a caller would rewind a claim on a transaction that may be live.
    assert_not_operator Solana::Cosign::BroadcastFailed, :<, Solana::Cosign::PreflightRejected
  end

  test "no rescue in this app narrows to RuntimeError, which is why losing it costs nothing" do
    # The control for the test above. If some call site DID name RuntimeError,
    # dropping it from the chain would silently stop catching a pre-flight
    # refusal there, and the retargeted assertion would be hiding that.
    offenders = Dir[Rails.root.join("app/**/*.rb"), Rails.root.join("lib/**/*.rb")].select do |path|
      File.read(path).match?(/^\s*rescue\s+[^#\n]*\bRuntimeError\b/)
    end

    assert_empty offenders,
                 "these files rescue RuntimeError specifically and would stop catching " \
                 "Vault::PreflightRejected now that it descends from StandardError instead"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE SEAM IS NOT REDRAWN AROUND THE NODE'S OWN PRE-FLIGHT — AND WHY
  # ══════════════════════════════════════════════════════════════════════════
  #
  # `send_and_confirm` runs `skipPreflight: false`, so the NODE pre-flights
  # against the real blockhash and the real signatures — exactly the two things
  # the simulation above deliberately does not check — and on refusal answers
  # with a CODED JSON-RPC error without forwarding. On that one attempt the
  # transaction is genuinely un-sent, and it is tempting to type it.
  #
  # IT IS STILL NOT A PROOF, because of what sits underneath: `Solana::Client#call`
  # retries INSIDE one call. It retries `Net::ReadTimeout` and `Errno::ECONNRESET`
  # — the faults that mean the request was written and the answer was lost, i.e.
  # the node may already have forwarded the wire — then re-POSTs the same bytes
  # and surfaces only the LAST exception. A blockhash can die inside the 30s read
  # timeout that produced the first fault, so the final answer can be a coded
  # `Blockhash not found` for a transaction attempt 1 already sent. Typing on the
  # final answer alone rewinds the row and re-sends the treasury.
  #
  # The caller cannot see that history — the intermediate exceptions never leave
  # `#call` and the final error carries no record of them — so this method types
  # NO exception from the send, and recovery comes from asking the chain
  # (`PendingTransaction#reconcile_broadcast!`) instead.

  # The coded error no longer reaches the caller AS a Solana::Client::RpcError:
  # it is wrapped in `Cosign::BroadcastFailed`, which is the type that SAYS "this
  # may be on chain". The property under test is unchanged and now structural —
  # a caller cannot read the coded shape as a proof, because the shape it is
  # handed is the ambiguous one. The node's own words ride along in the message,
  # which is what the operator actually sees (`render json: { error: e.message }`).
  test "a CODED rpc error from the send is still NOT typed un-sent" do
    coded = Solana::Client::RpcError.new("Blockhash not found", code: -32002)
    client = RaisingClient.new(send_raises: coded)

    error = assert_raises(Solana::Cosign::BroadcastFailed) do
      vault_with(client).simulate_and_broadcast("WIRE")
    end

    assert_not_kind_of Solana::Vault::PreflightRejected, error,
                       "Solana::Client#call retries the ambiguous faults and surfaces only the " \
                       "last answer, so a coded error may follow an attempt that already " \
                       "forwarded the wire — it is not a proof that nothing was sent"
    assert_match(/Blockhash not found/, error.message,
                 "the node's own words survive the wrapping — they are all the operator gets")
    assert_match(/reconcile/, error.message)
  end

  # THE CONTROL for the test above: the property is not vacuous only because a
  # coded error is the shape the node's pre-flight actually returns. If
  # Solana::Client ever stopped carrying the code, the reasoning above would be
  # about something that no longer exists.
  test "Solana::Client::RpcError carries the JSON-RPC code the reasoning turns on" do
    assert_equal(-32002, Solana::Client::RpcError.new("Blockhash not found", code: -32002).code)
    assert_nil Solana::Client::RpcError.new("Network error: timeout").code,
               "the gem's synthesized transport error carries no code"
  end

  # THE RETRY LOOP ITSELF — the thing the seam refuses to read through. This is
  # the gem's behaviour, asserted here because the app's safety argument depends
  # on it: if `#call` ever stopped retrying the ambiguous faults, a coded error
  # WOULD be a proof and this seam could be redrawn.
  test "Solana::Client retries the faults that mean the answer was lost" do
    source = File.read(Gem.loaded_specs["solana-studio"].gem_dir + "/lib/solana/client.rb")

    assert_match(/rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET/, source,
                 "the ambiguous transport faults are caught…")
    retry_block = source[/rescue Net::OpenTimeout.*?\n      end/m]
    assert_match(/retry/, retry_block,
                 "…and RETRIED, which is what hides an attempt that may have forwarded the wire")
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE SIGNATURE COMES FROM THE BYTES, NOT FROM THE RPC
  # ══════════════════════════════════════════════════════════════════════════

  def wire_with_signature(sig_bytes)
    # compact-u16 count of 1, then the 64-byte signature, then a stub message.
    Base64.strict_encode64("\x01".b + sig_bytes + ("\x00".b * 32))
  end

  test "signature_for_wire reads the transaction's own first signature" do
    sig_bytes = (1..64).map { |i| i % 256 }.pack("C*")
    expected  = Solana::Keypair.encode_base58(sig_bytes)

    assert_equal expected,
                 vault_with(StubClient.new({ "err" => nil })).signature_for_wire(wire_with_signature(sig_bytes))
  end

  # It is a PURE function of the bytes: no RPC is touched, which is the whole
  # reason a caller can stamp the signature before it sends.
  test "signature_for_wire asks no RPC" do
    client = StubClient.new({ "err" => nil })
    vault_with(client).signature_for_wire(wire_with_signature("z".b * 64))

    assert_empty client.simulate_calls
    assert_empty client.sent
  end

  test "signature_for_wire refuses a wire too short to carry a signature" do
    vault = vault_with(StubClient.new({ "err" => nil }))
    assert_raises(RuntimeError) { vault.signature_for_wire(Base64.strict_encode64("\x01short")) }
  end

  # THE DECODER SELF-CHECK. Callers stamp the derived signature and reconcile
  # against it, so a wrong derivation would strand every row it touched while
  # every test still passed. The node computes the same value from the same
  # bytes; a disagreement means neither may be trusted.
  #
  # IT IS A `BroadcastFailed`, AND IT CARRIES THE SIGNATURE. The send has already
  # happened by this line, so the disagreement is on the may-be-on-chain side of
  # the seam and must never read as un-sent. `#signature` is the value derived
  # from the bytes — the one the caller stamped before sending — so the row can
  # be reconciled against the chain with the same handle it already holds.
  test "a node signature that disagrees with the wire's own is refused" do
    sig_bytes = "q".b * 64
    wire = wire_with_signature(sig_bytes)
    expected = Solana::Keypair.encode_base58(sig_bytes)

    client = StubClient.new({ "err" => nil })
    client.define_singleton_method(:send_and_confirm) { |w| @sent << w; "A_DIFFERENT_SIGNATURE" }

    error = assert_raises(Solana::Cosign::BroadcastFailed) { vault_with(client).simulate_and_broadcast(wire) }

    assert_not_kind_of Solana::Vault::PreflightRejected, error,
                       "the bytes are already out — a disagreement here is never provably un-sent"
    assert_match(/A_DIFFERENT_SIGNATURE/, error.message, "the node's answer is named…")
    assert_match(/#{Regexp.escape(expected)}/, error.message, "…and so is the wire's own, so both can be looked up")
    assert_equal expected, error.signature,
                 "the error carries the DERIVED signature — the handle the caller already stamped"
  end

  # …and it must not turn a SUCCESSFUL broadcast into a failure just because the
  # decoder could not read the wire. The send has already happened by then.
  test "an undecodable wire does not fail a broadcast that succeeded" do
    client = StubClient.new({ "err" => nil })
    assert_equal "SIG_WIRE", vault_with(client).simulate_and_broadcast("WIRE")
  end
end
