# This migration comes from studio_engine (originally 20261029120000)
# The voice row on /profile (Studio.voice_profile): one speaker embedding on the
# user's own record, the model it came from, and when it was saved.
#
# A HOST-TABLE MIGRATION, the engine's second after
# add_standard_user_profile_columns, and built the same way for the same reason:
# one definition the apps install (`bin/rails studio_engine:install:migrations`)
# instead of a hand-written copy per app.
#
#   voice_embedding            jsonb  the averaged unit vector (256 floats for
#                                     the wespeaker embedder). A pattern of the
#                                     voice, never audio: the takes stay on the
#                                     device.
#   voice_embedding_model      string which embedder and revision made it
#                                     (Studio::VoiceMatch::EMBEDDERS ids). Vectors
#                                     from different models are not comparable,
#                                     so the matcher filters on this.
#   voice_embedding_updated_at datetime
#
# Every add is `if_not_exists`, and an app with no users table is skipped, as in
# the standard-columns migration.
#
# THE DOWN DROPS THEM, unlike the standard-columns migration, which refuses. That
# one could not tell its columns from columns the host already owned
# (first_name, birth_year). These three names are the engine's own coinage, and
# no consumer had any of them when this shipped (mcritchie-studio,
# turf-monster, mcritchie-industries, cyvasse and moms-app checked 2026-10-29),
# so a drop removes only what this migration added.
class AddVoiceProfileToUsers < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:users)

    add_column :users, :voice_embedding, :jsonb, if_not_exists: true
    add_column :users, :voice_embedding_model, :string, if_not_exists: true
    add_column :users, :voice_embedding_updated_at, :datetime, if_not_exists: true
  end

  def down
    return unless table_exists?(:users)

    remove_column :users, :voice_embedding_updated_at, if_exists: true
    remove_column :users, :voice_embedding_model, if_exists: true
    remove_column :users, :voice_embedding, if_exists: true
  end
end
