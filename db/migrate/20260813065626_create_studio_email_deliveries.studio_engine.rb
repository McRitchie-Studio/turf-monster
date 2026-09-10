# This migration comes from studio_engine (originally 20260614000000)
class CreateStudioEmailDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_email_deliveries do |t|
      t.string :email_key, null: false
      t.string :to
      t.string :mailer, null: false
      t.string :action, null: false
      t.jsonb :args, null: false, default: []
      t.jsonb :kwargs, null: false, default: {}
      t.boolean :sent, null: false, default: false
      t.datetime :sent_at
      t.text :error
      t.references :user, foreign_key: true

      t.timestamps
    end

    add_index :studio_email_deliveries, :sent
    add_index :studio_email_deliveries, :email_key
    add_index :studio_email_deliveries, :created_at
  end
end
