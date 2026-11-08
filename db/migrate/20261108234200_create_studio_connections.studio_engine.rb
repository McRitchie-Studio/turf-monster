# This migration comes from studio_engine (originally 20261108130000)
# CONNECTIONS (docs/CONNECTIONS.md): one row per third-party account a host app
# has connected over OAuth 2.0, for any provider the host declares with
# Studio.define_connection. The engine names no provider; `provider` is the
# host's key for one.
#
# One row per provider and account (`account_key`, unique within a provider):
# the account itself (a domain, a company id), or a keyed digest of it when the
# provider declares the account private, in which case the id is kept only in
# `account_secret`, encrypted. Every token column is encrypted with the app's
# Active Record encryption keys; a host without them cannot store a row.
#
# Installing the table changes nothing on its own: no route is drawn and no
# provider exists until the host declares one.
class CreateStudioConnections < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_connections do |t|
      t.string   :provider, null: false
      t.string   :account_key, null: false
      t.text     :account_secret
      t.string   :label
      t.text     :access_token
      t.text     :refresh_token
      t.datetime :access_expires_at
      t.datetime :refresh_expires_at
      t.json     :metadata, null: false, default: {}
      t.string   :connected_by
      t.datetime :connected_at, null: false
      t.datetime :last_refreshed_at

      t.timestamps
    end

    add_index :studio_connections, [:provider, :account_key], unique: true
  end
end
