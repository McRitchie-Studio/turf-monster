require "test_helper"

# THE DOUBLE-GRANT RACE, at the layer it actually happens.
#
# /admin/free_entries and Tokens::LevelUpGrant are two independent minters for the
# same debt. The page minted under Solana::Vault.operator_source_ref — a RANDOM
# ref — while the sweep minted under the deterministic one, and because the
# EntryTokenAccount PDA is derived from sha256(source_ref) ALONE, two different
# refs are two different PDAs. An operator clicking Mint while a sweep was in
# flight for the same user therefore hit no `init` collision whatsoever and BOTH
# tokens landed: one free entry nobody earned, plus permanent admin rent for the
# second account.
#
# The page's own OPSEC-030 `user.with_lock` could not prevent it, because nothing
# on the sweep side ever took that lock — the serialization was one-sided and
# inert. Locking both sides would have held a Postgres row lock across up to five
# Solana confirmations inside a 25-user sweep, so the fix is to share the REF
# instead: the two minters now collide on chain, which is the guard the whole
# design already rests on.
class Admin::FreeEntriesMintRefTest < ActionDispatch::IntegrationTest
  # Records what was minted and answers the two reads the owed math needs.
  class RecordingVault < FakeVault
    attr_reader :minted_refs

    def initialize(seeds:, tokens: [])
      super(tokens: tokens)
      self.sync_balance_seeds = seeds
      @minted_refs = []
    end

    def mint_entry_token(wallet_address:, source:, source_ref:, **opts)
      @minted_refs << source_ref
      super
    end
  end

  setup do
    @admin  = users(:alex)
    @wallet = users(:sam)
    @wallet.update_columns(seeds: 250, level: 3, slug: "sam-test")
    log_in_as(@admin)
  end

  test "the admin page mints the level-up ref, not a random operator ref" do
    vault = RecordingVault.new(seeds: 250)
    address = @wallet.solana_address

    Solana::Vault.stub :new, vault do
      post admin_mint_free_entries_path(user_slug: @wallet.slug)
    end

    expected = [2, 3].map { |l| Tokens::LevelUpGrant.source_ref(address, l) }

    assert_equal expected, vault.minted_refs,
      "the operator and the sweep must derive IDENTICAL refs for the same level — " \
      "a random ref derives a different PDA, so a concurrent sweep mint finds " \
      "nothing to collide with and both tokens land"
  end

  test "a level already on chain is not offered again" do
    paid  = { pda: "pda-2", source_ref: Tokens::LevelUpGrant.source_ref(@wallet.solana_address, 2),
              source: 0, consumed: false }
    vault = RecordingVault.new(seeds: 250, tokens: [paid])

    Solana::Vault.stub :new, vault do
      post admin_mint_free_entries_path(user_slug: @wallet.slug)
    end

    assert_equal [Tokens::LevelUpGrant.source_ref(@wallet.solana_address, 3)], vault.minted_refs,
      "level 2 is paid; re-offering it is the double-grant this closes"
  end

  test "mint_all keys every user's tokens to their own levels" do
    vault = RecordingVault.new(seeds: 250)

    Solana::Vault.stub :new, vault do
      post admin_mint_all_free_entries_path
    end

    refute_empty vault.minted_refs
    vault.minted_refs.each do |ref|
      assert_match(/\Alevelup:/, ref,
        "mint_all took the same path as mint — a random ref here reopens the race " \
        "for every user on the page at once")
    end
  end
end
