# This migration comes from studio_engine (originally 20260812000000)
# Per-email, per-APP settings an operator can change from /admin/emails without
# a deploy — starting with the banner scrim.
#
# Separate from ImageCache (which holds the uploaded banner) because this is a
# NUMBER, not an asset, and separate from the registry (which is code) because
# the whole point is that an operator can tune it against real artwork and see
# the result. The registry stays the default; a row here is an override.
class CreateStudioEmailSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_email_settings do |t|
      # The registry key — "magic_link", "contest_winnings". Not a foreign key:
      # the catalogue is code, and an app may unregister an email without
      # wanting its saved settings destroyed.
      t.string  :email_key, null: false

      # Scrim as a PERCENT (0-100) rather than a float. It is what the operator
      # types and what the page shows; storing the same units the human uses
      # keeps the round-trip lossless and the value obvious in the console.
      t.integer :scrim_percent

      t.timestamps
    end

    add_index :studio_email_settings, :email_key, unique: true
  end
end
