# This migration comes from studio_engine (originally 20260812220000)
# The subject line, editable beside the banner's words.
#
# Its OWN migration, and that is the point rather than an oversight. The subject
# column was first written into AddCopyToStudioEmailSettings, which a host had
# already run — so the column silently never appeared, and the manager offered a
# field backed by nothing. Editing an applied migration does not re-apply it; it
# only makes the file disagree with the database it claims to describe.
class AddSubjectToStudioEmailSettings < ActiveRecord::Migration[7.2]
  def change
    # Nullable, because nil means INHERIT the registry default — the same
    # distinction every other copy column carries. A NOT NULL default would
    # collapse "never set" into "set to empty".
    add_column :studio_email_settings, :subject, :string
  end
end
