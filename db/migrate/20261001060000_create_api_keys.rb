# Agent API keys (epic turf-agent-api, piece 1).
#
# A key lets an LLM agent act for ONE player without a browser cookie. Only the
# SHA-256 digest of the key is stored — the raw value is shown once at mint and
# is unrecoverable afterwards — plus a short display prefix so the player can
# tell their keys apart on /account.
#
# The eligibility_* columns are the ATTESTATION: what the player's own browser
# request looked like at mint (geo verdict, age-gate verdict). API requests
# arrive from an agent's servers, so their IP says nothing about where the
# player is; eligibility is checked once, in the browser, and carried by the key.
class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.string :token_digest, null: false
      t.string :prefix, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.string :eligibility_geo_country
      t.string :eligibility_geo_state
      t.string :eligibility_geo_result, null: false
      t.string :eligibility_age_result, null: false
      t.datetime :eligibility_attested_at, null: false

      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
