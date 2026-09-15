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
    assert vault.assert_usdc_transfer_cosign_safe!(
      signed_b64,
      wallet_address: wallet.to_base58,
      destination_token_account: destination,
      amount_lamports: AMOUNT
    )

    cosigned = vault.cosign_usdc_transfer(signed_b64)
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

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_usdc_transfer_cosign_safe!(
        signed_b64, wallet_address: wallet.to_base58,
        destination_token_account: ours, amount_lamports: AMOUNT
      )
    end
    assert_match(/token_accounts_mismatch/, error.message)
  end

  test "the guard refuses a wire that inflates the amount" do
    wallet      = Solana::Keypair.generate
    destination = Solana::Keypair.generate.address

    out        = build_cashout(wallet: wallet, destination: destination, amount: 500_000_000)
    signed_b64 = Base64.strict_encode64(phantom_signs(out[:serialized_tx], wallet))

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_usdc_transfer_cosign_safe!(
        signed_b64, wallet_address: wallet.to_base58,
        destination_token_account: destination, amount_lamports: AMOUNT
      )
    end
    assert_match(/token_data_mismatch/, error.message)
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

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_usdc_transfer_cosign_safe!(
        wire_b64, wallet_address: wallet.to_base58,
        destination_token_account: destination, amount_lamports: AMOUNT
      )
    end
    assert_match(/system_program_ix/, error.message)
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

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_usdc_transfer_cosign_safe!(
        wire_b64, wallet_address: wallet.to_base58,
        destination_token_account: destination, amount_lamports: AMOUNT
      )
    end
    assert_match(/fee_payer_not_admin/, error.message)
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
