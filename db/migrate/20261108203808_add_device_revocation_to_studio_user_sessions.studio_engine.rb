# This migration comes from studio_engine (originally 20261108120000)
# Lets a logout end one device's session on the server (Studio::UserSession,
# docs/DEVICE_SESSIONS.md). `sid` is the random id the device's cookie carries in
# its mark; every row of that device session carries it. `revoked_at` is stamped
# on logout, and a request whose sid is revoked is signed out.
#
# Both columns are nullable with no default, so the add is a catalog-only change
# and no existing row is rewritten. Rows from before this migration have no sid;
# their cookies get one on their next request (Studio::UserSession.track).
#
# A host without the table (it has not installed CreateStudioUserSessions) is a
# no-op here; the model checks for these columns and stays off until they exist.
class AddDeviceRevocationToStudioUserSessions < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:studio_user_sessions)

    add_column :studio_user_sessions, :sid, :string, if_not_exists: true
    add_column :studio_user_sessions, :revoked_at, :datetime, if_not_exists: true
    add_index :studio_user_sessions, :sid, if_not_exists: true
  end

  def down
    return unless table_exists?(:studio_user_sessions)

    remove_index :studio_user_sessions, :sid, if_exists: true
    remove_column :studio_user_sessions, :revoked_at, if_exists: true
    remove_column :studio_user_sessions, :sid, if_exists: true
  end
end
