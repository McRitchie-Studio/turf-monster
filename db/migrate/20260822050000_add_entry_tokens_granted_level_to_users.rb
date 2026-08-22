# The high-water mark of level-up free-entry grants: the highest level L for
# which EVERY level 2..L has a minted EntryTokenAccount on-chain.
#
# This is a FILTER HINT, not a source of truth — the on-chain token list is,
# exactly as `users.seeds` mirrors the on-chain seed count. Its job is to let
# LevelUpTokenMintJob find the users who are actually owed something with a
# plain indexable WHERE instead of spending two RPCs per levelled user, per
# run, to rediscover that nobody is owed anything.
#
# Default 1 (= level 1, nothing owed at signup) matches `users.level`'s default,
# so every existing row reads as "no grants made yet" and the first sweep
# backfills whatever the chain already shows.
class AddEntryTokensGrantedLevelToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :entry_tokens_granted_level, :integer, default: 1, null: false

    # Partial index on exactly the sweep's predicate — levelled users whose
    # grants have not caught up. Stays tiny: a row leaves the index as soon as
    # the job grants its token.
    add_index :users, [:level, :entry_tokens_granted_level],
              name: "index_users_on_pending_level_up_grants",
              where: "level > entry_tokens_granted_level"
  end
end
