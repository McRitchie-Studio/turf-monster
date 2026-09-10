class CreateCoinflowPurchases < ActiveRecord::Migration[7.2]
  def change
    create_table :coinflow_purchases do |t|
      t.references :user, null: false, foreign_key: true
      # Our own opaque handle for this checkout (== the slug). Sent to Coinflow
      # as the x-coinflow-auth-user-id / callback reference and echoed back on
      # the settlement webhook, the way PayPal echoes the invoice_id. Null is
      # never persisted (set to the slug in the same request the row is created),
      # but the column allows nil so the unique index tolerates the create seam.
      t.string :coinflow_reference
      # Coinflow's settlement payment id (webhook `id`). Doubles as the webhook
      # dedup key (a Settled event can be redelivered) AND the capture id stamped
      # atomically by the pending -> captured CAS. Unique + nullable.
      t.string :coinflow_payment_id
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
      t.index :coinflow_reference, unique: true
      t.index :coinflow_payment_id, unique: true
    end
  end
end
