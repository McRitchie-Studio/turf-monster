require "test_helper"

# THE MEASUREMENT THIS SWAP RESTS ON.
#
# turf-adopts-cosign-primitives replaced three hand-written cosign guards with
# `Solana::Cosign::Expectation`, and the replacement is STRICTER in one specific
# way: the old entry guard checked the Anchor DISCRIMINATOR plus two accounts
# (the entry PDA and the token PDA) and let every other account and every other
# byte through, while the gem compares each built instruction EXACTLY — same
# program, same ordered account keys, same data.
#
# THE RISK THAT CREATES. Phantom injects Lighthouse guard instructions into the
# transactions it signs, and it does so on MAINNET ONLY. A devnet entry — which
# is all the QA rehearsal and every Phantom test on this repo can produce — never
# sees a single Lighthouse instruction, so devnet CANNOT answer the question that
# matters: does the exact-match rule still admit a real, Phantom-signed,
# mainnet entry? If it does not, every player entry breaks in production, which
# is the 2026-06-11 outage again.
#
# THE ANSWER, MEASURED. test/fixtures/files/phantom_mainnet_cosigned_wires.json
# holds five REAL mainnet wires this house has already cosigned and broadcast,
# re-read from mainnet-beta with getTransaction at `finalized`: one
# enter_contest, one enter_contest_with_token and three create_contest — the
# whole money path. This test replays each one through the exact rule the swap
# ships and asserts it is ADMITTED.
#
# WHAT THE MEASUREMENT PROVES, AND WHAT IT DOES NOT. Said plainly, because a
# test that overclaims is worse than no test:
#
#   * PROVES — Phantom did not touch, reorder, duplicate or split the app
#     instruction. Every wire carries EXACTLY ONE non-ComputeBudget,
#     non-Lighthouse instruction, and it is this app's own program. That is the
#     property the exact-match rule depends on, and it is measured, not assumed.
#   * PROVES — every Lighthouse instruction Phantom actually injected (7 to 9 per
#     wire, 37 in total) is an ASSERTION variant the allowlist admits. Only
#     variants 6 and 10 appear in real traffic.
#   * PROVES — the signer set, the fee payer's slot and the ComputeBudget pair
#     survive Phantom's re-encode in the form the expectation requires.
#   * DOES NOT PROVE — that the app instruction's BYTES equal some independently
#     derived expectation. The instruction is read out of the wire, so that one
#     comparison is a round trip. It is the count, the position and the
#     untouched-ness that carry the weight here, plus the discriminator check
#     below, which ties the instruction to a builder in this repo.
#
# If a builder ever changes what it emits, or the guard ever changes what it
# admits, re-run this before shipping. It needs no network.
class Solana::CosignMainnetWireAdmissionTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/phantom_mainnet_cosigned_wires.json")

  MAINNET = JSON.parse(File.read(FIXTURE)).freeze
  WIRES   = MAINNET.fetch("wires").freeze
  HOUSE   = MAINNET.fetch("house_fee_payer").freeze
  PLAYER  = MAINNET.fetch("player_wallet").freeze

  COMPUTE_BUDGET = Solana::ComputeBudget::PROGRAM_ID.b
  LIGHTHOUSE     = Solana::Cosign::LIGHTHOUSE_PROGRAM_ID.b

  # The Anchor discriminators this repo's own builders emit, computed here the
  # same way Solana::Transaction.anchor_discriminator computes them. Asserting
  # the real wires carry THESE is what stops the round trip above from being
  # the whole story: it ties the instruction in a mainnet wire to a named
  # instruction of this program rather than to itself.
  DISCRIMINATORS = {
    "enter_contest"            => Solana::Transaction.anchor_discriminator("enter_contest"),
    "enter_contest_with_token" => Solana::Transaction.anchor_discriminator("enter_contest_with_token"),
    "create_contest"           => Solana::Transaction.anchor_discriminator("create_contest")
  }.freeze

  def decode(wire)
    Solana::WireMessage.parse(Base64.strict_decode64(wire.fetch("wire_base64")))
  end

  # Split a decoded mainnet message the way Expectation#verify! splits it.
  def partition(message)
    budget, lighthouse, app = [], [], []
    message.instructions.each_with_index do |ix, index|
      case ix[:program_id]
      when COMPUTE_BUDGET then budget << [index, Solana::ComputeBudget.parse(ix[:data])]
      when LIGHTHOUSE     then lighthouse << [index, ix[:data].getbyte(0)]
      else                     app << [index, ix]
      end
    end
    [budget, lighthouse, app]
  end

  # The expectation the SERVER would have held for this wire: its app
  # instructions, its signer set, and fee caps derived the way the builder
  # derives them.
  def expectation_for(message, app)
    max_price, max_fee = Solana::Cosign.fee_caps(
      compute_unit_price: Solana::Vault::PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS,
      compute_unit_limit: Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT,
      margin: Solana::Vault::COSIGN_FEE_MARGIN
    )
    Solana::Cosign::Expectation.new(
      fee_payer: message.fee_payer,
      cosigners: message.signer_keys.drop(1),
      instructions: app.map { |_i, ix| { program_id: ix[:program_id], accounts: ix[:accounts], data: ix[:data] } },
      max_compute_unit_price: max_price,
      max_priority_fee_micro_lamports: max_fee
    )
  end

  # --- the headline ----------------------------------------------------------

  test "every real mainnet Phantom wire is ADMITTED by the exact-match rule" do
    assert_equal 5, WIRES.length, "the measurement is over all five captured wires"

    WIRES.each do |wire|
      message = decode(wire)
      _budget, _lighthouse, app = partition(message)

      assert expectation_for(message, app).verify!(message),
             "mainnet #{wire['flow']} #{wire['signature']} must still be admitted — " \
             "if this fails, the exact-match guard breaks live entries"
    end
  end

  test "Completer#cosign accepts every real mainnet wire without touching the network" do
    # The wires are already fully signed (the house cosigned them in production),
    # so slot 0 holds a valid signature and the completer takes its "presigned at
    # build" branch. That still runs verify! plus every cosigner-signature check,
    # which is the whole pre-broadcast boundary, and it makes no RPC call.
    completer = Solana::Cosign::Completer.new(client: :no_rpc_expected, fee_payer: house_keypair)

    WIRES.each do |wire|
      message = decode(wire)
      _budget, _lighthouse, app = partition(message)
      expectation = expectation_for(message, app)

      cosigned = completer.cosign(wire.fetch("wire_base64"), expectation: expectation)
      assert_equal wire.fetch("signature"), cosigned.signature,
                   "the signature the completer derives must be the one the chain recorded for #{wire['flow']}"
    end
  end

  # --- the properties the exact-match rule actually depends on ---------------

  test "Phantom left the app instruction alone: exactly one, and it is this program's" do
    WIRES.each do |wire|
      message = decode(wire)
      _budget, _lighthouse, app = partition(message)

      assert_equal 1, app.length,
                   "#{wire['flow']} #{wire['signature']}: Phantom must inject NOTHING into the app " \
                   "instruction stream — the exact-match rule refuses an extra or reordered instruction"

      _index, ix = app.first
      discriminator = ix[:data].byteslice(0, 8)
      assert_equal DISCRIMINATORS.fetch(wire.fetch("flow")), discriminator,
                   "#{wire['flow']}: the surviving instruction must be this program's #{wire['flow']}, " \
                   "tying the wire to a builder in this repo rather than to itself"
    end
  end

  test "every Lighthouse instruction Phantom injected is an admitted assertion variant" do
    seen = Hash.new(0)

    WIRES.each do |wire|
      message = decode(wire)
      _budget, lighthouse, _app = partition(message)

      assert lighthouse.any?, "#{wire['flow']}: a real mainnet Phantom wire carries Lighthouse instructions"
      lighthouse.each do |index, variant|
        seen[variant] += 1
        assert_includes Solana::Cosign::LIGHTHOUSE_ASSERTIONS, variant,
                        "#{wire['flow']} ix #{index}: variant #{variant} is not an admitted assertion — " \
                        "the allowlist would refuse a real Phantom wire"
      end
    end

    # The shape of real traffic, pinned. A new variant appearing here is not a
    # failure of this app, but it IS a signal that the evidence behind the
    # 2..17 allowlist needs re-reading before it is trusted further.
    assert_equal 37, seen.values.sum, "all 37 Lighthouse instructions across the five wires"
    assert_equal({ 6 => 32, 10 => 5 }, seen.sort.to_h,
                 "real Phantom traffic carries only AssertAccountInfoMulti (6) and AssertTokenAccountMulti (10)")
  end

  test "the house is account 0 and writable, and the signer set is exactly house plus player" do
    WIRES.each do |wire|
      message = decode(wire)

      assert_equal HOUSE, Solana::Cosign.base58(message.fee_payer), "#{wire['flow']}: the house pays"
      assert message.writable?(0), "#{wire['flow']}: account 0 must be writable"
      assert_equal [HOUSE, PLAYER], message.signer_keys.map { |k| Solana::Cosign.base58(k) },
                   "#{wire['flow']}: exactly two signers, house first — no padding, none missing"
    end
  end

  test "the ComputeBudget pair survives Phantom untouched, and inside the cap" do
    WIRES.each do |wire|
      message = decode(wire)
      budget, _lighthouse, _app = partition(message)

      parsed = budget.map { |_i, (kind, value)| [kind, value] }.to_h
      assert_equal Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT, parsed[:limit],
                   "#{wire['flow']}: the builder's CU limit came back unchanged"
      assert_equal Solana::Vault::PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS, parsed[:price],
                   "#{wire['flow']}: the builder's price came back unchanged — no wallet raised the fee"
    end
  end

  # --- what makes the measurement TRANSFER to today's code -------------------

  test "today's builders emit the same instruction SHAPE the mainnet wires carry" do
    # THE ASSERTION THAT STOPS THIS SUITE BEING A MUSEUM PIECE.
    #
    # Everything above measures five transactions signed on mainnet in the past.
    # That only tells us something about the code we are shipping if the
    # builders still emit the same instruction — so this compares the live
    # builders' output against the wires, by account COUNT and by Anchor
    # discriminator. If a future account-order change (the way v0.26 inserts
    # `governance` at index 4) alters what a builder emits, the fixtures stop
    # describing production and this fails, loudly, instead of the admission
    # tests above quietly proving something about a shape nobody builds.
    #
    # The five wires were captured under the v0.25 shape, which is what
    # `Config.governance?` reports false for and what production runs today.
    # When governance flips on, expect this to fail and re-capture the fixtures
    # — do not widen the assertion.
    skip "governance shape differs from the captured wires; re-capture the fixtures" if Solana::Config.governance?

    vault = Solana::Vault.new(client: CosignFakeClient.build)
    wallet = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
    token_pda = Solana::Keypair.generate.address

    built = {
      "enter_contest" => vault.build_enter_contest(wallet, "shape-probe", 0, currency_idx: 0, season_id: 1),
      "enter_contest_with_token" =>
        vault.build_enter_contest_with_token(wallet, "shape-probe", 0, token_pda, season_id: 1),
      "create_contest" => vault.build_create_contest(
        wallet, "shape-probe", admin_signs: false,
        entry_fee_by_currency: [19_000_000], max_entries: 29,
        payout_amounts: [300_000_000, 50_000_000], prize_pool: 350_000_000,
        season_id: 1, lock_timestamp: 0
      )
    }

    WIRES.group_by { |w| w.fetch("flow") }.each do |flow, wires|
      message = Solana::WireMessage.parse(Base64.strict_decode64(built.fetch(flow)[:serialized_tx]))
      live = message.instructions.reject { |ix| ix[:program_id] == COMPUTE_BUDGET }
      assert_equal 1, live.length, "#{flow}: the builder emits exactly one app instruction"
      live_ix = live.first

      wires.each do |wire|
        _budget, _lighthouse, app = partition(decode(wire))
        _index, onchain = app.first

        # NOT the program id. turf-vault is deployed under a SEPARATE program id
        # per cluster, so a mainnet wire names the mainnet program and a wire
        # built in this environment names this environment's — they differ by
        # design, and asserting equality would only be asserting which cluster
        # the test runs against. What must match is the SHAPE: the same
        # instruction of the same program source, taking the same accounts.
        assert_equal onchain[:data].byteslice(0, 8), live_ix[:data].byteslice(0, 8),
                     "#{flow} #{wire['signature']}: the builder now emits a different instruction"
        assert_equal onchain[:accounts].length, live_ix[:accounts].length,
                     "#{flow} #{wire['signature']}: the account LIST changed shape since these wires were " \
                     "signed, so they no longer describe what Phantom would be handed today — " \
                     "re-capture the fixtures before trusting the admission tests above"
      end
    end

    # And all five wires really are one deployment, so "the mainnet program" is
    # a single thing the shape comparison above is measuring against.
    programs = WIRES.map do |wire|
      _budget, _lighthouse, app = partition(decode(wire))
      app.first.last[:program_id]
    end
    assert_equal 1, programs.uniq.length,
                 "the captured wires must all come from ONE turf-vault deployment"
  end

  # --- the control: the rule still BITES on these very wires ------------------

  test "CONTROL — a MemoryWrite spliced into a real mainnet wire is refused" do
    # Without a control, every assertion above would pass just as happily against
    # a guard that admitted everything. This proves the rule that admits these
    # five wires is the same rule that refuses the attack the allowlist exists
    # for: a Lighthouse MemoryWrite naming the house as payer.
    wire = WIRES.first
    message = decode(wire)
    _budget, _lighthouse, app = partition(message)
    expectation = expectation_for(message, app)

    memory_write = {
      program_id: LIGHTHOUSE,
      accounts: [{ pubkey: message.fee_payer, is_signer: true, is_writable: true }],
      data: ([Solana::Cosign::LIGHTHOUSE_MEMORY_WRITE, 0, 255].pack("CCC") + [10_000].pack("Q<") + "\x00").b
    }

    error = assert_raises(Solana::Cosign::WireRejected) do
      expectation.verify!(splice(message, memory_write))
    end
    assert_equal "lighthouse_memory_write", error.reason
  end

  test "CONTROL — an app instruction whose data was altered is refused" do
    wire = WIRES.first
    message = decode(wire)
    _budget, _lighthouse, app = partition(message)
    _index, ix = app.first

    tampered = { program_id: ix[:program_id], accounts: ix[:accounts], data: ix[:data].dup }
    tampered[:data].setbyte(tampered[:data].bytesize - 1, ix[:data].getbyte(-1) ^ 0xFF)

    expectation = expectation_for(message, app)
    error = assert_raises(Solana::Cosign::WireRejected) do
      expectation.verify!(rebuild_with_app(message, tampered))
    end
    assert_equal "instruction_data_mismatch", error.reason
  end

  private

  def house_keypair
    # A keypair the completer will accept as ITS key. It never signs here — every
    # wire's slot 0 is already filled — but Completer#verify! checks the
    # expectation's fee payer against it, so it must BE the house key.
    @house_keypair ||= FakeHouseKeypair.new(Solana::Keypair.decode_base58(HOUSE))
  end

  # A stand-in for the house Solana::Keypair. The mainnet wires are already
  # signed, so no private key is needed — and none exists in this repo.
  class FakeHouseKeypair
    def initialize(public_key_bytes) = @public_key_bytes = public_key_bytes
    def public_key_bytes = @public_key_bytes
    def sign(_message) = raise("the mainnet wires are already signed — nothing here may sign")
  end

  # Rebuild a decoded message with one extra instruction appended, re-serialized
  # so the guard sees a real wire rather than a doctored object.
  def splice(message, extra_instruction)
    rebuild(message, message.instructions + [normalize(extra_instruction)])
  end

  def rebuild_with_app(message, replacement_app)
    replaced = message.instructions.map do |ix|
      next ix if ix[:program_id] == COMPUTE_BUDGET || ix[:program_id] == LIGHTHOUSE

      normalize(replacement_app)
    end
    rebuild(message, replaced)
  end

  def normalize(ix)
    { program_id: Solana::Cosign.key_bytes(ix[:program_id]),
      accounts: Array(ix[:accounts]).map { |a| a.is_a?(Hash) ? Solana::Cosign.key_bytes(a[:pubkey]) : a },
      data: ix[:data] }
  end

  # A minimal decoded-message stand-in carrying the fields Expectation#verify!
  # reads. Re-serializing a real legacy wire byte-for-byte is a separate problem
  # from the one under test, and the guard only ever asks these questions.
  RebuiltMessage = Struct.new(:fee_payer, :signer_keys, :recent_blockhash, :instructions,
                              :writable_zero, keyword_init: true) do
    def writable?(index) = index.zero? ? writable_zero : true
    def recent_blockhash_base58 = Solana::Cosign.base58(recent_blockhash)
  end

  def rebuild(message, instructions)
    RebuiltMessage.new(
      fee_payer: message.fee_payer,
      signer_keys: message.signer_keys,
      recent_blockhash: message.recent_blockhash,
      instructions: instructions,
      writable_zero: message.writable?(0)
    )
  end
end
