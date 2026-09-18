require "test_helper"

# INTEGRATION — the signer-set tier for pin-cashout-cosign-signer-count. Drives
# the wire each REAL Phantom-first builder emits through the whole cosign
# lifecycle: build, Phantom signs its own slot, the guard runs, the house fills
# the fee-payer slot. Then it does it again as an attacker would: the same
# builder's wire re-serialized with one extra signer slot the player fills
# themselves.
#
# Why it matters: Solana charges the fee payer 5_000 lamports per declared
# signature, and charges it on a landing that fails. The house is the fee payer
# on all three guarded flows (cash-out, entry, contest create), so every extra
# signer slot a guard admits is house SOL. The pinned rule is two signatures,
# the house in slot 0 and the player in slot 1 -- what every builder emits and
# what all five real mainnet Phantom wires declare.
#
# Like LighthouseCosignGuardLifecycleTest, this runs the ACTUAL Solana::Vault
# cosign path against full wires. The controller tests go through FakeVault and
# never reach it.
#
# THE GUARD AND THE COSIGN ARE ONE CALL NOW. The three hand-written
# `assert_*_cosign_safe!` guards are deleted; `Cosign::Completer#cosign` judges
# the returned wire against the expectation, checks every cosigner's own
# signature slot, and only then fills the house's. So "refused before any house
# signature" — the property the second test in each pair exists for — is no
# longer an ordering a caller could get wrong: the house key is unreachable
# from a wire that failed. Each flow below states its expectation the way its
# controller does, which is the other half of what changed:
#
#   cash-out  REBUILT from the ramp row (wallet + destination + amount); there
#             is no stored wire, the row holds the facts.
#   entry     read from the wire the SERVER STORED and handed out, because the
#             entry re-prepares seconds before signing and must judge the exact
#             bytes the player saw.
#   create    REBUILT from the draft's own on-chain params, so a slate whose
#             first kickoff moved is refused rather than funded.
#
# The signer-set rule itself is now SET EQUALITY rather than a count: exactly
# the house plus the named cosigner, no extra and none missing. A padded wire is
# refused because the accomplice is not in the set, not because three is more
# than two — which also closes the swap a count cannot see.
class CosignSignerSetLifecycleTest < ActiveSupport::TestCase
  SLUG   = "signer-set-lifecycle".freeze
  AMOUNT = 19_000_000

  FakeContest = Struct.new(:slug)
  FakeEntry   = Struct.new(:id, :entry_number, :contest)

  CREATE_PARAMS = {
    entry_fee_by_currency: [19_000_000], max_entries: 29,
    payout_amounts: [300_000_000, 50_000_000], prize_pool: 350_000_000,
    season_id: 1, lock_timestamp: 0
  }.freeze

  def fake_client
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    CosignFakeClient.teach(client)
    client
  end

  def vault
    @vault ||= Solana::Vault.new(client: fake_client)
  end

  def house
    Solana::Keypair.admin
  end

  # --- wire readers -----------------------------------------------------------

  def signature_slots(wire)
    bytes = wire.b
    count, cursor = Solana::Transaction.read_compact_u16(bytes, 0)
    Array.new(count) { |i| bytes.byteslice(cursor + (i * 64), 64) }
  end

  def empty_slot?(slot)
    slot == ("\x00".b * 64)
  end

  # The attacker's move, applied to a real builder's wire: decode the message,
  # keep every instruction, account, flag and the blockhash, and re-serialize it
  # with `extra` appended to the signer set. Nothing else about the wire changes,
  # so a guard that passes the original and refuses this is refusing the signer
  # slot and nothing else.
  def pad_with_signer(wire, extra)
    bytes = wire.b
    sig_count, c = Solana::Transaction.read_compact_u16(bytes, 0)
    c += sig_count * 64
    num_req, ro_signed, ro_unsigned = bytes.byteslice(c, 3).unpack("CCC")
    key_count, c = Solana::Transaction.read_compact_u16(bytes, c + 3)
    keys = Array.new(key_count) { |i| bytes.byteslice(c + (i * 32), 32) }
    c += key_count * 32
    blockhash = Solana::Keypair.encode_base58(bytes.byteslice(c, 32))
    c += 32

    writable = lambda do |i|
      i < num_req ? i < num_req - ro_signed : i < key_count - ro_unsigned
    end

    tx = Solana::Transaction.new
    tx.set_recent_blockhash(blockhash)
    ix_count, c = Solana::Transaction.read_compact_u16(bytes, c)
    ix_count.times do
      program_index = bytes.getbyte(c)
      acct_len, c = Solana::Transaction.read_compact_u16(bytes, c + 1)
      indices = Array.new(acct_len) { |i| bytes.getbyte(c + i) }
      data_len, c = Solana::Transaction.read_compact_u16(bytes, c + acct_len)
      data = bytes.byteslice(c, data_len)
      c += data_len
      tx.add_instruction(
        program_id: keys[program_index],
        accounts: indices.map { |i| { pubkey: keys[i], is_signer: i < num_req, is_writable: writable.call(i) } },
        data: data
      )
    end
    tx.serialize_partial(additional_signers: keys.first(num_req) + [extra.public_key_bytes])
  end

  # Phantom's half, and the accomplice's: every non-house slot signed.
  def signed_by(wire, *keypairs)
    keypairs.reduce(wire) { |w, kp| Solana::Transaction.cosign_wire(w, signer: kp, require_complete: false) }
  end

  # --- the three guarded flows, each from its REAL builder ---------------------

  # Judge-and-cosign, the way each flow's controller reaches the house key: one
  # call, refusal first. Raises Cosign::WireRejected, or returns the Cosigned
  # struct carrying the completed wire.
  def cosigner_for(expectation)
    ->(bytes) { vault.cosign_completer.cosign(Base64.strict_encode64(bytes), expectation: expectation) }
  end

  FLOWS = {
    cashout: lambda do |t, player|
      destination = Solana::Keypair.generate.address
      wire = Base64.decode64(t.vault.build_user_usdc_transfer_unsigned(
        wallet_address: player.to_base58, destination_token_account: destination, amount_lamports: AMOUNT
      )[:serialized_tx])
      [wire, t.cosigner_for(t.vault.usdc_transfer_expectation(
        wallet_address: player.to_base58, destination_token_account: destination, amount_lamports: AMOUNT
      ))]
    end,
    entry: lambda do |t, player|
      built = t.vault.build_enter_contest(player.to_base58, SLUG, 0, currency_idx: 0, season_id: 1)
      [Base64.decode64(built[:serialized_tx]), t.cosigner_for(t.vault.cosign_expectation(
        built[:serialized_tx], wallet_address: player.to_base58,
        last_valid_block_height: built[:last_valid_block_height]
      ))]
    end,
    create: lambda do |t, player|
      built = t.vault.build_create_contest(player.to_base58, SLUG, **CREATE_PARAMS, admin_signs: false)
      [Base64.decode64(built[:serialized_tx]), t.cosigner_for(t.vault.create_contest_expectation(
        wallet_address: player.to_base58, contest_slug: SLUG, onchain_params: CREATE_PARAMS
      ))]
    end
  }.freeze

  FLOWS.each do |flow, setup|
    test "#{flow}: the builder's two-signer wire rides build -> Phantom sign -> guard -> house cosign" do
      player = Solana::Keypair.generate
      wire, guard = setup.call(self, player)

      assert_equal 2, signature_slots(wire).size, "the #{flow} builder declares house + player"
      signed = signed_by(wire, player)

      cosigned = guard.call(signed)
      assert cosigned, "the expectation must admit the wire this builder itself produced"

      completed = Base64.decode64(cosigned.wire_base64)
      assert signature_slots(completed).none? { |s| empty_slot?(s) }, "the house cosign completes the wire"
      assert cosigned.signature.present?,
             "the transaction's id is known from the bytes before anything is sent"
    end

    test "#{flow}: the same wire padded with a player-filled third signer is refused before any house signature" do
      player     = Solana::Keypair.generate
      accomplice = Solana::Keypair.generate
      wire, guard = setup.call(self, player)

      padded = signed_by(pad_with_signer(wire, accomplice), player, accomplice)
      slots  = signature_slots(padded)
      assert_equal 3, slots.size
      assert empty_slot?(slots[0]), "only the house slot is left"

      # Without the guard nothing stops the house: cosign_wire completes the
      # padded wire happily, and the house pays for three signatures.
      assert Solana::Transaction.cosign_wire(padded, signer: house),
             "control: the cosign primitive itself does not refuse a padded wire"

      error = assert_raises(Solana::Cosign::WireRejected) { guard.call(padded) }
      assert_equal "signer_set_mismatch", error.reason
      assert_match(/unexpected signer\(s\) \[#{accomplice.address}\]/, error.message,
                   "the refusal names the key that does not belong, not merely a count")
      assert empty_slot?(signature_slots(padded)[0]), "validate-then-cosign: the house never signed"
    end
  end
end
