# api_keys.name was created nullable while ApiKey validates its presence, so
# the model and the table disagreed about what a key is. The model is right
# (the name is how a player tells their keys apart when one has to be revoked);
# this makes the table say so too.
#
# BACKFILL FIRST, in the same transaction. Nothing the app does writes a NULL
# name — ApiKey.mint! is the only writer and it validates — so this is expected
# to touch zero rows. It is here so the constraint cannot fail the release phase
# on a row written some other way (a console, a script): such a key keeps
# working and reads "Unnamed key" on the account card.
#
# Table-rewrite cost: none. SET NOT NULL scans the table once under a brief
# lock; api_keys holds at most five live rows per player.
class RequireApiKeyName < ActiveRecord::Migration[8.1]
  BACKFILL_NAME = "Unnamed key".freeze

  def up
    execute <<~SQL.squish
      UPDATE api_keys SET name = #{connection.quote(BACKFILL_NAME)} WHERE name IS NULL
    SQL
    change_column_null :api_keys, :name, false
  end

  def down
    change_column_null :api_keys, :name, true
  end
end
