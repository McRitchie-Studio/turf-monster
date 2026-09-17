require "test_helper"

# WHO PAYS FOR THE CASH-OUT — the one fact that decides whether a Phantom
# player can take their money out at all.
#
# Turf Monster's product line is gasless on purpose: entries, account creation,
# username changes, card purchases and winnings all put the HOUSE on the
# transaction, so a player who onboarded with USDC never has to go find SOL.
# The managed-wallet cash-out honours that too — Vault#build_user_usdc_transfer
# has the admin pay while the managed key authorises.
#
# The Phantom cash-out did not. #build_user_usdc_transfer_unsigned serialized
# with additional_signers: [wallet_bytes] and nothing else, which makes the
# PLAYER'S wallet the fee payer. A player holding USDC and zero SOL therefore
# could not withdraw — and met that wall at withdrawal, the moment most likely
# to read as the platform holding their funds.
#
# No other tier could see it. The controller test runs through FakeVault, whose
# builder returns the literal string "FAKE_TX_offramp_…", so no wire exists to
# inspect; nothing else parses this builder's bytes. These tests read the fee
# payer straight off the wire, then walk the full Phantom-first handshake the
# fix requires: Phantom signs its slot, the guard validates, the house cosigns.
class Solana::VaultOfframpFeePayerTest < ActiveSupport::TestCase
  # No RPC: the cash-out builder only needs a blockhash. It anchors on a plain
  # recent blockhash (no durable nonce), so get_account_info is never reached.
  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    CosignFakeClient.teach(client)
    client
  end

  def vault
    @vault ||= Solana::Vault.new(client: fake_client)
  end

  def admin_bytes
    Solana::Keypair.admin.public_key_bytes.b
  end

  # A cash-out comfortably above the $0.99 floor.
  AMOUNT = 19_000_000

  def build_cashout(wallet:, destination:, amount: AMOUNT)
    vault.build_user_usdc_transfer_unsigned(
      wallet_address: wallet.to_base58,
      destination_token_account: destination,
      amount_lamports: amount
    )
  end

  # --- wire readers (same shape as the entry cosign-wire suite) ---------------

  def signature_slots(wire_bytes)
    bytes = wire_bytes.b
    count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    [count, Array.new(count) { |i| bytes.byteslice(cursor + (i * 64), 64) }]
  end

  def empty_slot?(slot)
    slot == ("\x00".b * 64)
  end

  # Account keys in wire order. Signer slots map 1:1 onto the first
  # numRequiredSignatures of them, so "who is the fee payer" is account 0.
  def account_keys(wire_bytes)
    bytes = wire_bytes.b
    sig_count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    message_start = cursor + (sig_count * 64)
    count, acct_cursor = Solana::Transaction.read_compact_u16(bytes, message_start + 3)
    Array.new(count) { |i| bytes.byteslice(acct_cursor + (i * 32), 32) }
  end

  # Phantom's half: sign the EXACT message bytes into the wallet's OWN slot and
  # leave every other slot untouched. require_complete:false because the admin
  # slot is still empty at this point — the entire point of Phantom-first order.
  def phantom_signs(serialized_tx_b64, keypair)
    Solana::Transaction.cosign_wire(Base64.decode64(serialized_tx_b64),
                                    signer: keypair, require_complete: false)
  end

  # --- the guard ---------------------------------------------------------------
  #
  # `#assert_usdc_transfer_cosign_safe!` is DELETED. What judges a returned
  # cash-out wire now is `Solana::Cosign::Expectation`, and the expectation is
  # stated the way Cdp::OfframpSendsController#cosign states it: REBUILT from the
  # ramp row's own wallet, destination and amount. The cash-out has no stored
  # wire to read — those three facts live on the row — which is why this flow
  # uses the rebuild form rather than #cosign_expectation.
  #
  # The refusal REASONS are the gem's vocabulary now, and they are broader by
  # construction rather than enumerated one attack at a time. The old guard
  # checked the destination, the amount, the fee payer, the signer set, System
  # instructions and Lighthouse variants as six named rules; the expectation
  # compares the whole built instruction — every account, in order, and every
  # byte of data — so a drifted destination is `instruction_accounts_mismatch`, a
  # drifted amount is `instruction_data_mismatch`, and an instruction nobody
  # built is `unexpected_instruction` WHATEVER program it names.
  def cashout_expectation(wallet:, destination:, amount: AMOUNT)
    vault.usdc_transfer_expectation(
      wallet_address: wallet.to_base58,
      destination_token_account: destination,
      amount_lamports: amount
    )
  end

  # Judge a base64 wire. Pure: no key is touched and nothing is signed, which is
  # what lets it judge a wire the player has not signed yet. Returns the decoded
  # WireMessage, or raises Cosign::WireRejected naming the first rule it breaks.
  def cashout_judge(wire_b64, wallet:, destination:, amount: AMOUNT)
    vault.cosign_completer.verify!(
      wire_b64, expectation: cashout_expectation(wallet: wallet, destination: destination, amount: amount)
    )
  end

  # --- the defect, stated directly -------------------------------------------

  test "the cash-out wire names the HOUSE in the fee-payer position" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address

    out  = build_cashout(wallet: wallet, destination: destination)
    wire = Base64.decode64(out[:serialized_tx])
    keys = account_keys(wire)

    assert_equal admin_bytes, keys[0],
                 "account 0 is the fee payer. It must be the house — a Phantom player holding " \
                 "USDC and zero SOL cannot pay for their own withdrawal, and every other " \
                 "user-facing path already has the house paying."
  end

  test "the player still signs the cash-out — only the fee payer changed" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address

    out  = build_cashout(wallet: wallet, destination: destination)
    wire = Base64.decode64(out[:serialized_tx])
    keys = account_keys(wire)
    count, = signature_slots(wire)

    assert_equal 2, count, "the cash-out declares two signers: the house (payer) and the player"
    assert_equal wallet.public_key_bytes.b, keys[1],
                 "the player's wallet stays in a signer slot — it is their USDC leaving their " \
                 "token account, and that consent is the protection"
  end

  test "both signature slots are left empty for the Phantom-first handshake" do
    wallet = Solana::Keypair.generate

    out = build_cashout(wallet: wallet, destination: Solana::Keypair.generate.address)
    _count, slots = signature_slots(Base64.decode64(out[:serialized_tx]))

    assert empty_slot?(slots[0]),
           "the admin slot must be EMPTY at build time: Phantom signs first, the server cosigns " \
           "second (a pre-filled slot makes cosign_wire refuse to clobber, and the server-first " \
           "ordering is what trips Phantom's Lighthouse 'could be malicious' banner)"
    assert empty_slot?(slots[1]), "Phantom fills its own slot in the browser"
  end

  # --- the full handshake -----------------------------------------------------

  test "Phantom signs, the guard passes, and the house cosign completes the wire" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address

    out         = build_cashout(wallet: wallet, destination: destination)
    user_signed = phantom_signs(out[:serialized_tx], wallet)

    _count, slots = signature_slots(user_signed)
    assert empty_slot?(slots[0]), "the house has not signed yet"
    assert_not empty_slot?(slots[1]), "Phantom filled its own slot"

    signed_b64 = Base64.strict_encode64(user_signed)
    assert cashout_judge(signed_b64, wallet: wallet, destination: destination),
           "the expectation must admit the wire this server itself prepared"

    # THE JUDGEMENT IS INSIDE THE COSIGN NOW. #cosign_usdc_transfer takes the
    # expectation and refuses before it reaches for the admin key, so
    # "validate then cosign" is structural rather than a rule the controller has
    # to remember — there is no way to reach the house signature without passing.
    cosigned = vault.cosign_usdc_transfer(
      signed_b64, expectation: cashout_expectation(wallet: wallet, destination: destination)
    )
    _count, final = signature_slots(Base64.decode64(cosigned[:signed_tx]))

    assert_not empty_slot?(final[0]), "the house signature slot is filled by the cosign"
    assert_not empty_slot?(final[1]), "Phantom's signature is untouched by the cosign"
    assert cosigned[:signature].present?,
           "the tx signature is returned so the caller can persist it BEFORE the bytes leave the server"
  end

  # --- the guard: the house signature must not be spendable on anything else --

  test "the guard refuses a wire whose destination is not the one we resolved" do
    wallet = Solana::Keypair.generate
    ours   = Solana::Keypair.generate.address
    theirs = Solana::Keypair.generate.address

    # A real wire, correctly signed by the player — but paying somewhere else.
    out        = build_cashout(wallet: wallet, destination: theirs)
    signed_b64 = Base64.strict_encode64(phantom_signs(out[:serialized_tx], wallet))

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_judge(signed_b64, wallet: wallet, destination: ours)
    end
    assert_equal "instruction_accounts_mismatch", error.reason
    assert_match(/differ from built instruction 0/, error.message)
  end

  test "the guard refuses a wire that inflates the amount" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address

    out        = build_cashout(wallet: wallet, destination: destination, amount: 500_000_000)
    signed_b64 = Base64.strict_encode64(phantom_signs(out[:serialized_tx], wallet))

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_judge(signed_b64, wallet: wallet, destination: destination)
    end
    assert_equal "instruction_data_mismatch", error.reason
  end

  test "the guard refuses a System instruction riding along with the transfer" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    from_ata, _ = Solana::SplToken.find_associated_token_address(wallet.to_base58, Solana::Config::USDC_MINT)

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_instruction(**Solana::SplToken.transfer_instruction(
      from: from_ata, to: destination, authority: wallet.public_key_bytes, amount: AMOUNT
    ))
    # SystemProgram::Transfer (index 2, u32 LE) draining the fee payer — the
    # exact thing the admin signature must never be spent on.
    tx.add_instruction(
      program_id: Solana::Transaction::SYSTEM_PROGRAM_ID,
      accounts: [
        { pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: true, is_writable: true },
        { pubkey: wallet.public_key_bytes, is_signer: false, is_writable: true }
      ],
      data: ([2].pack("V") + [1_000_000_000].pack("Q<")).b
    )
    wire_b64 = tx.serialize_partial_base64(
      additional_signers: [Solana::Keypair.admin.public_key_bytes, wallet.public_key_bytes]
    )

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_judge(wire_b64, wallet: wallet, destination: destination)
    end
    # The old guard had a NAMED rule for System instructions. The expectation
    # needs none: the cash-out builds exactly one instruction, so a second one
    # is refused whatever program it names — and the message still says which.
    assert_equal "unexpected_instruction", error.reason
    assert_match(/program System was not built/, error.message)
  end

  test "the guard refuses a Lighthouse MemoryWrite naming the house fee payer" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    from_ata, _ = Solana::SplToken.find_associated_token_address(wallet.to_base58, Solana::Config::USDC_MINT)

    # A correct cash-out transfer (house fee payer, player authority) PLUS a
    # crafted Lighthouse MemoryWrite (discriminator 0) whose `payer` account is
    # the house. The house already signs this wire, so an unguarded admit would
    # make it fund an attacker-sized "memory" PDA and lock its SOL — draining the
    # fee payer stops all gasless cash-outs and entries. Carl's exploit.
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_instruction(**Solana::SplToken.transfer_instruction(
      from: from_ata, to: destination, authority: wallet.public_key_bytes, amount: AMOUNT
    ))
    tx.add_instruction(
      program_id: Solana::Cosign::LIGHTHOUSE_PROGRAM_ID,
      accounts: [
        { pubkey: Solana::Cosign::LIGHTHOUSE_PROGRAM_ID,     is_signer: false, is_writable: false },
        { pubkey: Solana::Transaction::SYSTEM_PROGRAM_ID,    is_signer: false, is_writable: false },
        { pubkey: Solana::Keypair.admin.public_key_bytes,    is_signer: true,  is_writable: true  }, # payer = house
        { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: true  }, # memory PDA
        { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }  # source
      ],
      data: ([0, 0, 255].pack("CCC") + [10_000].pack("Q<") + "\x00").b
    )
    wire_b64 = tx.serialize_partial_base64(
      additional_signers: [Solana::Keypair.admin.public_key_bytes, wallet.public_key_bytes]
    )

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_judge(wire_b64, wallet: wallet, destination: destination)
    end
    assert_equal "lighthouse_memory_write", error.reason
  end

  test "the guard admits a Phantom Lighthouse assertion alongside the transfer" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    from_ata, _ = Solana::SplToken.find_associated_token_address(wallet.to_base58, Solana::Config::USDC_MINT)

    # A real assertion discriminator (6, AssertAccountInfoMulti) from mainnet —
    # the cash-out guard must keep admitting it so a protected Phantom cash-out
    # is not rejected.
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_instruction(**Solana::SplToken.transfer_instruction(
      from: from_ata, to: destination, authority: wallet.public_key_bytes, amount: AMOUNT
    ))
    tx.add_instruction(
      program_id: Solana::Cosign::LIGHTHOUSE_PROGRAM_ID,
      accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: false, is_writable: false }],
      data: ["06040203000001000000000000000000"].pack("H*")
    )
    wire_b64 = tx.serialize_partial_base64(
      additional_signers: [Solana::Keypair.admin.public_key_bytes, wallet.public_key_bytes]
    )
    phantom = Base64.strict_encode64(phantom_signs(wire_b64, wallet))

    assert cashout_judge(phantom, wallet: wallet, destination: destination)
  end

  test "the guard refuses a wire that does not name the house as fee payer" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    from_ata, _ = Solana::SplToken.find_associated_token_address(wallet.to_base58, Solana::Config::USDC_MINT)

    # The PRE-FIX shape: the player alone, so the player pays.
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_instruction(**Solana::SplToken.transfer_instruction(
      from: from_ata, to: destination, authority: wallet.public_key_bytes, amount: AMOUNT
    ))
    wire_b64 = tx.serialize_partial_base64(additional_signers: [wallet.public_key_bytes])

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_judge(wire_b64, wallet: wallet, destination: destination)
    end
    assert_equal "fee_payer_mismatch", error.reason
    assert_match(/account 0 is #{wallet.address}/, error.message,
                 "the refusal names who the wire put in the fee-payer seat")
  end

  # --- the signer set: two signatures, house then player ----------------------
  #
  # pin-cashout-cosign-signer-count. The house pays 5_000 lamports of base fee
  # for every signature this wire declares, whether the send lands clean or
  # lands and fails, and the failed-send cap bounds only HOW MANY landings it
  # pays for. The guard used to ask only that the player sit somewhere in the
  # signer region, so a player could append signer slots they fill themselves.

  # The cash-out transfer under an arbitrary signer list, keyless. When the
  # player is NOT in the list, the transfer's authority meta is demoted so the
  # serializer does not promote the player back into a signer slot: the guard
  # compares the transfer's account KEYS, not their signer flags.
  def cashout_wire(wallet:, destination:, signers:, extra_ixs: [])
    from_ata, _ = Solana::SplToken.find_associated_token_address(wallet.to_base58, Solana::Config::USDC_MINT)
    transfer = Solana::SplToken.transfer_instruction(
      from: from_ata, to: destination, authority: wallet.public_key_bytes, amount: AMOUNT
    )
    unless signers.any? { |s| s.b == wallet.public_key_bytes.b }
      transfer = transfer.merge(accounts: transfer[:accounts].map { |m| m.merge(is_signer: false) })
    end

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    extra_ixs.each { |ix| tx.add_instruction(**ix) }
    tx.add_instruction(**transfer)
    tx.serialize_partial(additional_signers: signers)
  end

  def cashout_guard(wire_bytes, wallet:, destination:)
    cashout_judge(Base64.strict_encode64(wire_bytes), wallet: wallet, destination: destination)
  end

  # The ComputeBudget pair at the CEILING this house will cosign. The two
  # derived constants that used to spell it (COSIGN_MAX_COMPUTE_UNIT_PRICE and
  # COSIGN_MAX_PRIORITY_FEE_MICROLAMPORTS) are gone: `Solana::Cosign.fee_caps`
  # computes the same numbers from the builder's own price and limit, which is
  # what both the builder and every expectation now use, so the worst case this
  # test constructs follows the app instead of a constant kept in step by hand.
  def budget_ixs
    max_price, = Solana::Cosign.fee_caps(
      compute_unit_price: Solana::Vault::PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS,
      compute_unit_limit: Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT,
      margin: Solana::Vault::COSIGN_FEE_MARGIN
    )
    [Solana::ComputeBudget.set_compute_unit_price(max_price),
     Solana::ComputeBudget.set_compute_unit_limit(Solana::Vault::PARTIAL_TX_COMPUTE_UNIT_LIMIT)]
  end

  test "REGRESSION: the guard refuses a cash-out wire declaring a THIRD signer" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    extra       = Solana::Keypair.generate

    two = cashout_wire(wallet: wallet, destination: destination, signers: [admin_bytes, wallet.public_key_bytes])
    assert cashout_guard(two, wallet: wallet, destination: destination),
           "control: the same transfer under exactly house + player must pass"

    # The player and their accomplice key both sign; only the house slot is empty.
    three = cashout_wire(wallet: wallet, destination: destination,
                         signers: [admin_bytes, wallet.public_key_bytes, extra.public_key_bytes])
    three = Solana::Transaction.cosign_wire(three, signer: wallet, require_complete: false)
    three = Solana::Transaction.cosign_wire(three, signer: extra, require_complete: false)

    # SET EQUALITY, not a count. The old guard capped the number of signers; the
    # expectation requires the signer set to be EXACTLY house + player, so the
    # refusal names the key that does not belong rather than a number.
    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_guard(three, wallet: wallet, destination: destination)
    end
    assert_equal "signer_set_mismatch", error.reason
    assert_match(/unexpected signer\(s\) \[#{extra.address}\]/, error.message)
    assert_match(/missing signer\(s\) \[\]/, error.message, "the player and the house are both where they belong")
  end

  test "REGRESSION: the worst-case padded wire is refused -- ten signers fit the packet" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    extras      = Array.new(8) { Solana::Keypair.generate.public_key_bytes }

    # The most signers a cash-out wire can declare and still fit Solana's
    # 1_232-byte packet, with the priority fee at its ceiling. Unpinned, the house
    # paid 10 x 5_000 base + 100_000 priority = 150_000 lamports per failed landing.
    wire = cashout_wire(wallet: wallet, destination: destination, extra_ixs: budget_ixs,
                        signers: [admin_bytes, wallet.public_key_bytes, *extras])
    assert_operator wire.bytesize, :<=, 1_232, "the padded wire must be one that could really land"

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_guard(wire, wallet: wallet, destination: destination)
    end
    assert_equal "signer_set_mismatch", error.reason
    # Every one of the eight is named, which is strictly more than the count the
    # old refusal carried: a padded wire cannot hide a key in an aggregate.
    extras.each do |key|
      assert_match(/#{Solana::Keypair.encode_base58(key)}/, error.message)
    end
  end

  test "REGRESSION: the guard refuses a cash-out wire whose second signer is not the player" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address
    stranger    = Solana::Keypair.generate

    wire = cashout_wire(wallet: wallet, destination: destination,
                        signers: [admin_bytes, stranger.public_key_bytes])

    error = assert_raises(Solana::Cosign::WireRejected) do
      cashout_guard(wire, wallet: wallet, destination: destination)
    end
    assert_equal "signer_set_mismatch", error.reason
    assert_match(/unexpected signer\(s\) \[#{stranger.address}\]/, error.message,
                 "the stranger is named as the key that does not belong…")
    assert_match(/missing signer\(s\) \[#{wallet.address}\]/, error.message,
                 "…and the player is named as the consent that is absent")
  end

  # --- the $0.99 floor --------------------------------------------------------

  test "the Phantom builder refuses a withdrawal below the floor" do
    wallet = Solana::Keypair.generate

    error = assert_raises(Solana::Vault::BelowMinimumWithdrawalError) do
      build_cashout(wallet: wallet, destination: Solana::Keypair.generate.address, amount: 400_000)
    end
    assert_match(/Minimum withdrawal is \$0\.99/, error.message)
  end

  test "the floor sits at exactly $0.99, not above it" do
    wallet = Solana::Keypair.generate

    assert_equal 990_000, Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS
    out = build_cashout(wallet: wallet, destination: Solana::Keypair.generate.address,
                        amount: Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS)
    assert out[:serialized_tx].present?, "$0.99 exactly is ABOVE the floor and must build"

    assert_raises(Solana::Vault::BelowMinimumWithdrawalError) do
      build_cashout(wallet: wallet, destination: Solana::Keypair.generate.address,
                    amount: Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS - 1)
    end
  end

  test "the MANAGED builder carries the same floor, so it cannot be routed around" do
    user_keypair = Solana::Keypair.generate

    error = assert_raises(Solana::Vault::BelowMinimumWithdrawalError) do
      vault.build_user_usdc_transfer(
        user_keypair: user_keypair,
        destination_token_account: Solana::Keypair.generate.address,
        amount_lamports: 400_000
      )
    end
    assert_match(/Minimum withdrawal is \$0\.99/, error.message)
  end
end
