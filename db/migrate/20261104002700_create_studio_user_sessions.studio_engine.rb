# This migration comes from studio_engine (originally 20261103120000)
# One row per signed-in browser session (Studio::UserSession). A small, cached
# record every app keeps the same way. No foreign key: a host's users table is
# its own, and a deleted user's sessions may stay as counts.
class CreateStudioUserSessions < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_user_sessions do |t|
      t.bigint :user_id, null: false
      t.boolean :admin, null: false, default: false
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index :user_id
      t.index :last_seen_at
    end
  end
end
