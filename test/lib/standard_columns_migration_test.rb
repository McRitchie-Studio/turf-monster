require "test_helper"

# [integration] The hand-written AddLastNameAndNewsletterColumns.
#
# WHY THIS APP CARRIES A MIGRATION THAT ADDS NOTHING. Engine migrations are
# install-COPIED, never referenced, and the copy is a manual step a gem bump does
# not perform — so between the engine shipping one and every consumer installing
# it, engine_pin_contract_test's name gate goes RED here. That gate has no
# acknowledgement map: it can only be SATISFIED. Holding a migration of the same
# BARE NAME satisfies it the moment the engine ships, and install:migrations then
# skips it ("Migration with the same name already exists").
#
# So this file guards a NAME and a REFUSAL, not a schema change. All three
# columns already exist here — last_name since create_users (20260524000008),
# the newsletter pair since the quest flow (20260605215004) — which is why
# running it moved only the schema VERSION line.
class StandardColumnsMigrationTest < ActiveSupport::TestCase
  MIGRATION_DIR = Rails.root.join("db/migrate")

  # MIRRORS engine_migration_content_test's own detector, character for
  # character: anchored at the START of the file and requiring the
  # `(originally <timestamp>)` clause. Nothing less will do.
  #
  # The first version of this assertion searched the whole body for the bare
  # phrase and FAILED — on this test file's own sibling comment, which explains
  # the header in prose. A scanner that cannot tell a header from a sentence
  # about headers reports the documentation as the defect; the same shape as an
  # ERB comment tripping an ERB-leak check.
  PROVENANCE = /\A#[ \t]*This migration comes from ([a-z_]+) \(originally (\d+)\)[ \t]*\r?\n/

  def migration_file
    @migration_file ||= Dir.children(MIGRATION_DIR)
                           .grep(/add_last_name_and_newsletter_columns\.rb\z/)
                           .first
  end

  # THE NAME IS THE WHOLE POINT, so it is pinned character for character. A
  # rename on either side reopens the red window this file exists to close, and
  # nothing else in the suite would notice — the columns would still be there and
  # every other test would stay green.
  test "the migration carries the exact bare name the engine will ship" do
    refute_nil migration_file, "no add_last_name_and_newsletter_columns migration in db/migrate"

    bare = migration_file.sub(/\A\d+_/, "").sub(/\.(studio_engine|studio)\.rb\z|\.rb\z/, "")
    assert_equal "add_last_name_and_newsletter_columns", bare
  end

  # AND IT MUST NOT LOOK LIKE AN ENGINE COPY. engine_migration_content_test
  # compares only files carrying the `.studio_engine` suffix or a
  # "This migration comes from studio_engine" line; a provenance header here
  # would enrol this independent file in a content diff against the engine's and
  # report drift forever.
  test "the migration is not disguised as an engine copy" do
    refute_match(/\.studio(_engine)?\.rb\z/, migration_file)

    body = File.read(File.join(MIGRATION_DIR, migration_file))
    refute_match(PROVENANCE, body,
                 "a provenance header would enrol this file in the content-drift comparison")
  end

  # THE COLUMNS IT NAMES ARE ALL PRESENT, which is what makes it a no-op here.
  # Asserted against the live schema rather than the file, because the claim is
  # about this app's database, not about what the migration says.
  test "all three columns exist on this app" do
    %w[last_name joined_email_list_at left_email_list_at].each do |column|
      assert_includes User.column_names, column
    end
  end

  # IT REFUSES TO REVERSE, and here the danger is at its sharpest: `up` created
  # NOTHING on this app, so Rails' auto inverse would drop three columns that
  # predate the file — last_name since create_users, the pair since the quest
  # flow. A silent `down` would take real data with it.
  test "reversing raises rather than dropping columns it never created" do
    version = migration_file[/\A\d+/].to_i
    migration = ActiveRecord::MigrationContext
                .new(MIGRATION_DIR.to_s)
                .migrations
                .find { |m| m.version == version }
    refute_nil migration, "migration #{version} not found in #{MIGRATION_DIR}"

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migration.migrate(:down) }
    assert_match(/cannot be reversed safely/, error.message)
    # `predate\nit` in the heredoc — match the word, not the wrapped phrase.
    assert_match(/predate/, error.message, "the refusal must say WHY reversing is unsafe here")
  end

  # AND THE COLUMNS SURVIVE THE ATTEMPT. The refusal is only worth having if it
  # fires before anything is dropped — a raise after the first remove_column
  # would still have destroyed a column.
  test "a refused reversal leaves every column in place" do
    version = migration_file[/\A\d+/].to_i
    migration = ActiveRecord::MigrationContext
                .new(MIGRATION_DIR.to_s)
                .migrations
                .find { |m| m.version == version }

    assert_raises(ActiveRecord::IrreversibleMigration) { migration.migrate(:down) }

    User.reset_column_information
    %w[last_name joined_email_list_at left_email_list_at].each do |column|
      assert_includes User.column_names, column,
                      "#{column} was dropped before the refusal fired"
    end
  end
end
