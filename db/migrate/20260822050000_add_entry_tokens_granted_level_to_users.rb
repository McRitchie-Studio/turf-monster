# Two columns for LevelUpTokenMintJob: what the user has been PAID, and when
# the sweep last LOOKED at them. They answer different questions and must never
# be conflated — that conflation is how a sweep silently marks an unpaid user
# as settled.
#
# `entry_tokens_granted_level` — the high-water mark of level-up free-entry
# grants: the highest level L for which EVERY level 2..L has a minted
# EntryTokenAccount on-chain. A FILTER HINT, not a source of truth (the
# on-chain token list is, exactly as `users.seeds` mirrors the on-chain seed
# count). It advances ONLY on proof that a token exists. Default 1 (= level 1,
# nothing owed at signup) matches `users.level`'s default, so every existing
# row reads as "no grants made yet" and the first sweep backfills whatever the
# chain already shows.
#
# `entry_tokens_swept_at` — the sweep's ROTATION CURSOR. Stamped on every pass
# over a candidate whatever the outcome: minted, nothing owed, unevaluable, or
# raised. It is not a claim that anything was paid; it only records that this
# row has had its turn. Ordering the batch by it is what stops a permanently
# stuck row from occupying the batch forever and starving every user behind it.
# Default is the epoch, i.e. "never swept" — existing rows sort to the front.
class AddEntryTokensGrantedLevelToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :entry_tokens_granted_level, :integer, default: 1, null: false
    add_column :users, :entry_tokens_swept_at, :datetime,
               default: "1970-01-01 00:00:00", null: false

    # Partial index keyed for the EXACT query LevelUpTokenMintJob.candidates
    # issues:
    #
    #   WHERE level > entry_tokens_granted_level
    #   ORDER BY entry_tokens_swept_at, id
    #   LIMIT 25
    #
    # The WHERE is the index's own predicate, so the index holds only rows that
    # are owed something; the leading key is the ORDER BY, so the batch is read
    # straight off the index in rotation order and stops at LIMIT — no sort, no
    # heap scan of settled users. `id` tie-breaks the (very common) case of
    # several rows sharing the epoch default, keeping the ordering total.
    #
    # Deliberately NOT keyed on [level, entry_tokens_granted_level]: those two
    # columns appear only inside the predicate, which the partial index already
    # encodes, so leading on them buys nothing and cannot serve the ORDER BY.
    #
    # Stays small: a row leaves the index the moment the job grants its token.
    add_index :users, [:entry_tokens_swept_at, :id],
              name: "index_users_on_pending_level_up_grants",
              where: "level > entry_tokens_granted_level"
  end
end
