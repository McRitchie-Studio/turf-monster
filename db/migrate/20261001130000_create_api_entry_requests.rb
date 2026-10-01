# The idempotency record behind POST /api/v1/contests/:slug/entries
# (epic turf-agent-api, piece 3; docs/AGENT_API.md "Retrying safely").
#
# An agent retries. An entry spends an on-chain token that cannot be given
# back. So every create carries an Idempotency-Key, and this row is what makes
# the second request with that key find the first one's outcome instead of
# spending again. One row per (player, key); the unique index is the guard.
#
# Schema only: no backfill, nothing to run after deploy.
class CreateApiEntryRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :api_entry_requests do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :contest, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :api_key, foreign_key: { on_delete: :nullify }, index: false
      t.references :entry, foreign_key: { on_delete: :nullify }

      t.string :idempotency_key, null: false
      # SHA-256 of what was asked for (contest, picks, allow_usdc). The same key
      # with a different fingerprint is a client bug and is refused.
      t.string :fingerprint, null: false
      t.jsonb :matchup_ids, null: false, default: []
      t.boolean :allow_usdc, null: false, default: false

      t.string :state, null: false, default: "executing"
      t.integer :attempts, null: false, default: 0
      t.datetime :attempted_at, null: false
      # Set when an attempt may have reached the chain and we could not tell.
      t.datetime :spend_uncertain_at
      t.string :last_error_code

      t.string :funding_method
      t.boolean :token_consumed
      t.integer :response_status
      # The first response's JSON, as text and not jsonb: a replay is the same
      # bytes, and jsonb does not keep key order.
      t.text :response_body

      t.timestamps
    end

    add_index :api_entry_requests, %i[user_id idempotency_key], unique: true
    add_index :api_entry_requests, %i[user_id contest_id state]
  end
end
