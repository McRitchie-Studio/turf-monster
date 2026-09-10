class CreateAeropayPurchases < ActiveRecord::Migration[7.2]
  def change
    create_table :aeropay_purchases do |t|
      t.references :user, null: false, foreign_key: true
      # Our own opaque handle for this deposit (== the slug). Sent to Aeropay as
      # the create-deposit `externalId` and echoed back on the settlement
      # webhook, the way Coinflow echoes the callback reference. Null is never
      # persisted (set to the slug in the same request the row is created), but
      # the column allows nil so the unique index tolerates the create seam.
      t.string :aeropay_reference
      # Aeropay's deposit transaction id (returned by create_deposit; echoed by
      # the `transaction_completed` webhook). Doubles as the webhook dedup key
      # AND the capture id stamped by the pending -> captured CAS. Unique +
      # nullable (stamped just after the row is created).
      t.string :aeropay_transaction_id
      t.string :pack_id, null: false
      t.integer :quantity, default: 1, null: false
      t.integer :price_cents, null: false
      t.string :wallet_address
      t.string :contest_slug
      t.string :status, default: "pending", null: false
      t.text :mint_tx_signatures
      t.datetime :captured_at
      t.datetime :minted_at
      t.datetime :refunded_at
      t.string :refund_reason
      t.string :slug, null: false
      t.timestamps null: false

      t.index :slug, unique: true
      t.index :aeropay_reference, unique: true
      t.index :aeropay_transaction_id, unique: true
    end
  end
end
