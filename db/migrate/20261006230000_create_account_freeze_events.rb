class CreateAccountFreezeEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :account_freeze_events do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :admin, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :source, null: false
      t.string :reason, null: false
      # Audit-only: created_at, no updated_at (mirrors impersonation_logs).
      t.datetime :created_at, null: false

      t.index [:user_id, :created_at]
    end
  end
end
