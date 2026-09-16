require "test_helper"

# `read_vault_state` must decode ALL FIVE signer slots.
#
# ── THE DEFECT THIS PINS ─────────────────────────────────────────────────────
#
# Every reader in this app stopped at three. turf-vault v0.26 APPENDS
# `signers_ext: [Pubkey; 2]` at struct offset 1443 — carved out of the old
# `_reserved`, so the account stays 1515 bytes and those two slots are readable
# on BOTH program versions. A five-signer vault therefore rendered as three,
# silently under-reporting who can move money on the page an operator opens to
# decide who to evict. No test would have caught it, because the shape is
# identical and the missing keys simply never appeared.
#
# Offsets asserted here against turf-vault `accepted`'s own layout comments:
#   signers            96  @0      (8 with the Anchor discriminator)
#   threshold           1  @96
#   bump                1  @97
#   paused              1  @98
#   payout_mint        32  @99
#   treasury_authority 32  @131
#   accepted_currencies 1280 @163
#   signers_ext        64  @1443
#   total                  1507 (+8 = 1515 on chain)
class Solana::VaultSignerSlotsTest < ActiveSupport::TestCase
  ACCOUNT_LEN = 1515
  EMPTY = Solana::SignerRotation::EMPTY

  SLOT1 = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  SLOT2 = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  SLOT3 = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  SLOT4 = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  SLOT5 = "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf".freeze

  # A minimal stand-in for Solana::Client that serves ONE account. Used instead
  # of stubbing `read_vault_state` itself, because the thing under test IS the
  # decode — a stubbed reader would assert nothing about the bytes.
  class OneAccountClient
    def initialize(data, length: nil)
      @data = data
      @length = length
    end

    def get_account_info(_address, commitment: nil)
      return nil if @data.nil?

      { "value" => { "data" => [Base64.strict_encode64(@data), "base64"], "owner" => "x" } }
    end
  end

  # Build a VaultState account with the given slots. Everything else is zeroed,
  # which is what a decode test wants: a wrong offset then reads the sentinel
  # rather than another field's plausible-looking bytes.
  def vault_account(signers: [SLOT1, SLOT2, SLOT3], ext: [EMPTY, EMPTY],
                    threshold: 2, bump: 254, paused: 0, length: ACCOUNT_LEN)
    data = "\x00".b * length

    signers.each_with_index do |key, i|
      data[8 + i * 32, 32] = Solana::Keypair.decode_base58(key)
    end
    data.setbyte(8 + 96, threshold)
    data.setbyte(8 + 97, bump)
    data.setbyte(8 + 98, paused)

    ext.each_with_index do |key, i|
      offset = Solana::Vault::SIGNERS_EXT_OFFSET + i * 32
      next if offset + 32 > length

      data[offset, 32] = Solana::Keypair.decode_base58(key)
    end

    data
  end

  def read(**opts)
    Solana::Vault.new(client: OneAccountClient.new(vault_account(**opts))).read_vault_state
  end

  test "a never-rotated vault reads three live signers and two empty slots" do
    # This is what BOTH clusters actually read today (measured 2026-09-15:
    # 1515-byte accounts, three signers, slots 4 and 5 zero).
    state = read

    assert_equal [SLOT1, SLOT2, SLOT3, EMPTY, EMPTY], state[:signer_slots]
    assert_equal [EMPTY, EMPTY], state[:signers_ext]
    assert_equal [SLOT1, SLOT2, SLOT3], state[:active_signers]
    assert_equal 3, state[:active_signer_count]
  end

  test "a rotated five-signer vault reports all five, not three" do
    state = read(ext: [SLOT4, SLOT5])

    assert_equal [SLOT1, SLOT2, SLOT3, SLOT4, SLOT5], state[:signer_slots]
    assert_equal 5, state[:active_signer_count]
    assert_includes state[:active_signers], SLOT5,
                    "slot 5 must survive the decode — this is the whole defect"
  end

  test "a four-signer vault left-packs and drops the trailing empty" do
    state = read(ext: [SLOT4, EMPTY])

    assert_equal [SLOT1, SLOT2, SLOT3, SLOT4], state[:active_signers]
    assert_equal 4, state[:active_signer_count]
    assert_equal [SLOT1, SLOT2, SLOT3, SLOT4, EMPTY], state[:signer_slots]
  end

  test "the legacy three-slot key is UNCHANGED so existing readers cannot shift" do
    # `signers` must keep meaning "the first three slots". Widening it in place
    # would silently change what every existing view and test reads, on pages
    # nobody reviewed for it — which is the same class of mistake as widening
    # the on-chain array instead of appending to it.
    state = read(ext: [SLOT4, SLOT5])

    assert_equal [SLOT1, SLOT2, SLOT3], state[:signers]
    assert_equal 3, state[:signers].length
  end

  test "an off-by-one offset yields a WRONG key, never an error — which is why it is pinned" do
    # THE FAILURE MODE THIS GUARDS IS SILENT. A zero-copy account has no
    # name-keyed decode and no version tag: byte range 1451..1483 is called
    # `signers_ext[0]` because that is where it sits, not because anything on
    # chain says so. Read it one byte early and 31 of the 32 bytes still land,
    # so the decode SUCCEEDS and returns a valid-looking base58 key that is not
    # the key on chain — no exception, no warning, and a page that names the
    # wrong wallet as a vault signer.
    #
    # So the assertion is not "it comes back empty". It is: a shifted read
    # produces a DIFFERENT key, and only the documented offset produces the
    # right one.
    shifted = vault_account(ext: [EMPTY, EMPTY])
    shifted[Solana::Vault::SIGNERS_EXT_OFFSET - 1, 32] = Solana::Keypair.decode_base58(SLOT4)
    misread = Solana::Vault.new(client: OneAccountClient.new(shifted))
                           .read_vault_state[:signers_ext].first

    assert_not_equal SLOT4, misread,
                     "a key written one byte early must not decode as slot 4"
    assert_not_equal EMPTY, misread,
                     "and it does not fail loudly either — it returns a plausible wrong key, " \
                     "which is exactly why the offset is a constant with a test on it"

    # The control: the SAME key at the documented offset does decode correctly.
    aligned = vault_account(ext: [SLOT4, EMPTY])
    assert_equal SLOT4,
                 Solana::Vault.new(client: OneAccountClient.new(aligned))
                              .read_vault_state[:signers_ext].first
  end

  test "SIGNERS_EXT_OFFSET matches turf-vault's documented struct offset" do
    assert_equal 8 + 1443, Solana::Vault::SIGNERS_EXT_OFFSET
    assert_equal ACCOUNT_LEN, Solana::Vault::SIGNERS_EXT_OFFSET + 64,
                 "signers_ext consumes the reserve exactly to the end of the account"
  end

  test "an account too short for the ext slots reports them empty rather than raising" do
    # A shorter account is one this build cannot explain. Two empty slots is the
    # honest answer; a raise would take down the whole authority page over a
    # field that is absent by definition on the shape it is describing.
    short = vault_account(length: Solana::Vault::SIGNERS_EXT_OFFSET + 8)
    state = Solana::Vault.new(client: OneAccountClient.new(short)).read_vault_state

    assert_equal [EMPTY, EMPTY], state[:signers_ext]
    assert_equal 3, state[:active_signer_count]
  end
end
