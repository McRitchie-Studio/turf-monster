require "test_helper"

# The token-funded entry path CONSUMES its EntryTokenAccount. It does not burn it.
#
# Two different Anchor instructions, and the difference is not cosmetic:
#
#   * `enter_contest_with_token` — the entry path. The on-chain handler sets
#     `entry_token.consumed = true` + `consumed_at`, guarded by `!entry_token.consumed`
#     (VaultError::EntryTokenAlreadyConsumed). It never sets the burn tombstone.
#   * `burn_entry_token` — the operator claw-back, a 1-of-3 vault-signer instruction
#     the holder never signs. It ALSO sets `consumed = true` (that is what blocks the
#     spend) and additionally sets the burned flag in the `source` high bit.
#
# So `burned` is a strict SUPERSET of `consumed`: every burned token is consumed,
# and a token consumed by an entry is NOT burned. That asymmetry is the whole reason
# the flag exists — `Solana::Vault#decode_entry_token` calls it out as telling "a
# claw-back apart from a genuine redemption". Calling a redemption a burn destroys
# exactly the distinction the flag was added to carry.
#
# `Solana::EntryTokenBurnTest` already pins the DECODE side of that asymmetry
# ("a SPENT token is not reported as burned"). What was unpinned, and is pinned here,
# is the INSTRUCTION side: that the entry path actually emits the consume
# discriminator and never the burn one. Nothing asserted that a comment claiming the
# entry path "burned" a token was describing a different instruction than the code
# broadcasts.
class Solana::EntryConsumeNotBurnTest < ActiveSupport::TestCase
  # No RPC. Building an entry TX needs a blockhash; the send hands us the wire.
  def vault_with_sink
    sink = []
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client.define_singleton_method(:send_and_confirm) do |wire|
      sink << wire
      "entry_sig_#{SecureRandom.hex(4)}"
    end
    [Solana::Vault.new(client: client), sink]
  end

  def broadcast_entry_wire
    vault, sink = vault_with_sink
    user   = Solana::Keypair.generate
    wallet = Solana::Keypair.encode_base58(user.public_key_bytes)
    token  = Solana::Keypair.encode_base58(Solana::Keypair.generate.public_key_bytes)

    vault.enter_contest_with_token(wallet, "consume-not-burn-contest", 0, token,
                                   user_keypair: user, season_id: 1)

    assert_equal 1, sink.length, "the entry path must broadcast exactly one transaction"
    Base64.decode64(sink.first)
  end

  test "the token-funded entry path broadcasts the consume instruction" do
    wire = broadcast_entry_wire

    assert_includes wire, Solana::Transaction.anchor_discriminator("enter_contest_with_token"),
      "the entry path must carry the enter_contest_with_token discriminator"
  end

  test "the token-funded entry path never broadcasts a burn" do
    wire = broadcast_entry_wire

    refute_includes wire, Solana::Transaction.anchor_discriminator("burn_entry_token"),
      "entering a contest consumes the token; burning it is burn_entry_token, a " \
      "separate operator claw-back the holder never signs"
  end

  # CONTROL: the assertion above can actually fail — the harness can see a burn
  # discriminator in a wire when one is really there. Without this, `refute_includes`
  # would pass just as happily against a wire that carries no instructions at all,
  # or against a discriminator helper that returned nil.
  test "the burn discriminator is detectable in a wire that really burns" do
    sink = []
    client = Object.new
    client.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    client.define_singleton_method(:send_and_confirm) { |wire| sink << wire; "burn_sig" }
    vault = Solana::Vault.new(client: client)

    vault.burn_entry_token(wallet_address: Solana::Keypair.encode_base58(Solana::Keypair.generate.public_key_bytes),
                           source_ref: "operator:consume-not-burn:1")

    wire = Base64.decode64(sink.first)
    assert_includes wire, Solana::Transaction.anchor_discriminator("burn_entry_token"),
      "control: a real burn must be visible to the same check the entry test relies on"
    refute_equal Solana::Transaction.anchor_discriminator("enter_contest_with_token"),
                 Solana::Transaction.anchor_discriminator("burn_entry_token"),
                 "the two instructions must not share a discriminator, or neither test means anything"
  end
end
