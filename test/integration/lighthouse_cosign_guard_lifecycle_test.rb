require "test_helper"

# INTEGRATION — the onchain "multi-instruction lifecycle" tier for
# guard-lighthouse-memory-payer. Drives a Phantom-first entry wire that carries
# Phantom-injected Lighthouse instructions ALL THE WAY through the cosign
# boundary — build a multi-instruction wire, the wallet signs its own slot, the
# guard (#assert_entry_cosign_safe!) runs, then the house fills the fee-payer
# slot — and proves:
#   * a REAL mainnet Phantom Lighthouse assertion (discriminator 6) rides the
#     whole lifecycle: guard admits it, the house cosign completes the wire; and
#   * a Lighthouse MemoryWrite (discriminator 0) naming the house as payer is
#     REFUSED by the guard, so the house slot is NEVER filled — validate before
#     the irreversible cosign, the money-path invariant this task defends.
#
# Unlike the controller cosign tests (which run through FakeVault and never
# reach the real guard), this exercises the ACTUAL Solana::Vault guard against
# a full wire the way production does.
class LighthouseCosignGuardLifecycleTest < ActiveSupport::TestCase
  SLUG = "lighthouse-lifecycle".freeze

  FakeContest = Struct.new(:slug)
  FakeEntry   = Struct.new(:id, :entry_number, :contest)

  # A real mainnet Phantom Lighthouse assertion (AssertAccountInfoMulti,
  # discriminator 6) decoded from house-cosigned wire 2Fv91MyX… at finalized
  # 2026-09-16 — the shape the guard must keep admitting.
  REAL_ASSERTION_HEX = "06040203000001000000000000000000".freeze

  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client
  end

  def vault
    @vault ||= Solana::Vault.new(client: fake_client)
  end

  # --- wire readers -----------------------------------------------------------

  def signature_slots(wire_bytes)
    bytes = wire_bytes.b
    count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    [count, Array.new(count) { |i| bytes.byteslice(cursor + (i * 64), 64) }]
  end

  def empty_slot?(slot)
    slot == ("\x00".b * 64)
  end

  # --- wire builders (Phantom-first: both signer slots start empty) -----------

  def lighthouse_ix(data, accounts:)
    { program_id: Solana::Vault::LIGHTHOUSE_PROGRAM_ID, accounts: accounts, data: data.b }
  end

  def real_assertion_ix
    lighthouse_ix([REAL_ASSERTION_HEX].pack("H*"),
                  accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: false, is_writable: false }])
  end

  def memory_write_ix_naming_fee_payer
    lighthouse_ix([0, 0, 255].pack("CCC") + [10_000].pack("Q<") + "\x00".b,
                  accounts: [
                    { pubkey: Solana::Vault::LIGHTHOUSE_PROGRAM_ID,      is_signer: false, is_writable: false },
                    { pubkey: Solana::Transaction::SYSTEM_PROGRAM_ID,    is_signer: false, is_writable: false },
                    { pubkey: Solana::Keypair.admin.public_key_bytes,    is_signer: true,  is_writable: true  },
                    { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: true  },
                    { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }
                  ])
  end

  def phantom_first_entry_wire(wallet, lighthouse_ixs)
    entry_pda = vault.entry_pda(SLUG, wallet.to_base58, 0).first
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    accounts = Array.new(Solana::Vault.enter_contest_entry_pda_position) do
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: false }
    end
    accounts << { pubkey: entry_pda, is_signer: false, is_writable: true }
    tx.add_instruction(
      program_id: Solana::Keypair.decode_base58(Solana::Config::PROGRAM_ID),
      accounts: accounts,
      data: Solana::Transaction.anchor_discriminator("enter_contest") + ("\x00".b * 8)
    )
    lighthouse_ixs.each { |ix| tx.add_instruction(**ix) }
    # admin FIRST (fee payer), then the entrant — the Phantom-first ordering.
    tx.serialize_partial_base64(additional_signers: [Solana::Keypair.admin.public_key_bytes, wallet.public_key_bytes])
  end

  def entry_for(wallet)
    FakeEntry.new(7, 0, FakeContest.new(SLUG))
  end

  # --- the lifecycle ----------------------------------------------------------

  test "a real Phantom Lighthouse assertion rides build -> sign -> guard -> house cosign" do
    wallet = Solana::Keypair.generate
    wire   = phantom_first_entry_wire(wallet, [real_assertion_ix])

    # Wallet signs its own slot; the house slot stays empty (Phantom-first).
    signed = Solana::Transaction.cosign_wire(Base64.decode64(wire), signer: wallet, require_complete: false)
    _count, slots = signature_slots(signed)
    assert empty_slot?(slots[0]), "the house has not signed yet"
    assert_not empty_slot?(slots[1]), "the entrant filled its own slot"

    # The guard admits the wire (a real assertion is safe to cosign).
    assert vault.assert_entry_cosign_safe!(Base64.strict_encode64(signed),
                                           entry: entry_for(wallet), wallet_address: wallet.to_base58)

    # Only now does the house cosign, completing the wire.
    completed = Solana::Transaction.cosign_wire(signed, signer: Solana::Keypair.admin, require_complete: false)
    _count, final = signature_slots(completed)
    assert_not empty_slot?(final[0]), "the house signature slot is filled by the cosign"
    assert_not empty_slot?(final[1]), "the entrant's signature is untouched"
  end

  test "a Lighthouse MemoryWrite naming the house is refused before any cosign" do
    wallet = Solana::Keypair.generate
    wire   = phantom_first_entry_wire(wallet, [real_assertion_ix, memory_write_ix_naming_fee_payer])
    signed = Solana::Transaction.cosign_wire(Base64.decode64(wire), signer: wallet, require_complete: false)

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.assert_entry_cosign_safe!(Base64.strict_encode64(signed),
                                      entry: entry_for(wallet), wallet_address: wallet.to_base58)
    end
    assert_match(/lighthouse_memory_write/, error.message)

    # Validate-then-cosign: the house slot is STILL empty. The guard raised, so
    # the cosign step never ran and no house-signed wire can be broadcast.
    _count, slots = signature_slots(signed)
    assert empty_slot?(slots[0]), "the house must never have signed a MemoryWrite-bearing wire"
  end
end
