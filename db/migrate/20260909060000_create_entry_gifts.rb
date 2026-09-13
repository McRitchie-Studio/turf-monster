# The operator's "send my friend a free entry" ledger.
#
# WHY A ROW AND NOT JUST A MINT. The gift is addressed to an EMAIL, and at the
# moment it is sent there is no account, no wallet, and therefore no on-chain
# address to mint an EntryTokenAccount to. The row is what carries the promise
# across that gap: sent → claimed (they clicked, an account now exists) → minted
# (the token is on chain). Each step stamps its own column, so a gift stuck
# between two of them is visible on /admin/entry_gifts rather than lost.
#
# `mint_ref` IS THE IDEMPOTENCY KEY, and it is a stored random rather than the
# row id on purpose. It seeds the on-chain source_ref, whose PDA the program
# `init`s — so re-minting the same ref collides on chain and CANNOT double-grant
# (the same argument Tokens::LevelUpGrant makes at length). A row id would be
# deterministic too, but it repeats across a reseeded database and a restored
# dump, which is exactly when a stray second mint would be hardest to explain.
class CreateEntryGifts < ActiveRecord::Migration[8.1]
  def change
    create_table :entry_gifts do |t|
      t.string     :recipient_email, null: false
      t.references :sender,     null: false, foreign_key: { to_table: :users }
      t.references :contest,    null: true,  foreign_key: true
      t.references :claimed_by, null: true,  foreign_key: { to_table: :users }
      t.text       :note

      # Seeds the on-chain source_ref. Unique so two gifts can never key the
      # same EntryTokenAccount PDA.
      t.string     :mint_ref, null: false

      t.datetime   :claimed_at
      t.datetime   :minted_at
      t.string     :mint_signature
      # The address the token actually landed on — recorded rather than derived,
      # because User#solana_address prefers web3 and a gifted account may link
      # Phantom later, which would make a derived answer disagree with history.
      t.string     :wallet_address
      # Why the mint has not happened yet. Cleared on success; carried on the
      # ledger row so an unpayable gift names its own reason.
      t.string     :mint_error

      t.timestamps
    end

    add_index :entry_gifts, :mint_ref, unique: true
    add_index :entry_gifts, :recipient_email
    # The ledger's default ordering, newest first.
    add_index :entry_gifts, :created_at
  end
end
