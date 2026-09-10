# The standard profile columns, hand-written and named to match the engine's
# future migration EXACTLY. THIS APP ALREADY OWNS ALL THREE — the file exists for
# its NAME, not its effect.
#
# WHY A NO-OP MIGRATION IS THE RIGHT ANSWER HERE. Engine migrations are
# install-COPIED (`bin/rails studio_engine:install:migrations`), never referenced,
# and the copy is a manual step a gem bump does not perform. So there is a window
# between the engine shipping a migration and every consumer installing it, and
# during that window test/lib/engine_pin_contract_test.rb — THIS app's — goes RED:
# it asserts `engine_migration_names - installed_migration_names` is empty, and it
# has no acknowledgement map, so it cannot be silenced, only satisfied.
#
# Going CONSUMER-FIRST closes that window entirely. That gate compares BARE names
# (leading timestamp stripped, `.studio_engine` suffix stripped), so this app is
# satisfied the moment the engine ships its own, and `install:migrations` then
# SKIPS it — "Migration with the same name already exists". `create_studio_links`
# and `allow_null_image_cache_owner` are already in exactly this state here, and
# the guard's own comment calls that "correct rather than drift".
#
# SO THE NAME IS LOAD-BEARING, character for character. Rename either side and
# the arrangement collapses into the red window it exists to avoid.
#
# WHERE THIS APP'S COLUMNS ACTUALLY CAME FROM, which is why `up` adds nothing:
#   last_name             — db/migrate/20260524000008_create_users.rb, this app's
#                           own create_table, long before the engine had a notion
#                           of standard profile columns.
#   joined_email_list_at  — 20260605215004_add_quest_newsletter_columns_to_users,
#   left_email_list_at      added for the seeds/quest flow, again this app's own.
# The engine's AddStandardUserProfileColumns adds NEITHER last_name nor the
# newsletter pair, so nothing upstream supplied them either.
#
# NO PROVENANCE HEADER, deliberately. engine_migration_content_test.rb compares
# only files carrying the `.studio_engine` suffix or a
# "# This migration comes from studio_engine" line. A plain migration matches
# neither, so it is never compared and cannot be reported as drift against the
# engine's copy — correct, because the two are independent files that happen to
# share a name and an intended effect.
class AddLastNameAndNewsletterColumns < ActiveRecord::Migration[8.1]
  def up
    # An app that keeps its accounts under another name is simply skipped, same
    # as the engine's standard-columns migration.
    return unless table_exists?(:users)

    # `if_not_exists` on every add, for the reason the engine's own
    # AddStandardUserProfileColumns uses it: the apps disagree TODAY. This app
    # owns all three already; mcritchie-studio owned only last_name. One file has
    # to be correct on all of them — here it adds nothing and that is the
    # expected outcome, not a sign the migration is wrong.
    add_column :users, :last_name, :string, if_not_exists: true
    add_column :users, :joined_email_list_at, :datetime, if_not_exists: true
    add_column :users, :left_email_list_at, :datetime, if_not_exists: true
  end

  def down
    return unless table_exists?(:users)

    # REFUSES, and here the danger is at its sharpest: `up` created NOTHING on
    # this app, so Rails' auto inverse would drop three columns this app has
    # owned since before the file existed — last_name since create_users, the
    # newsletter pair since the quest flow shipped. `if_exists` is not the fix;
    # it asks "does the column exist", and here it does, which IS the hazard.
    raise ActiveRecord::IrreversibleMigration, <<~MSG
      AddLastNameAndNewsletterColumns cannot be reversed safely.

      Its `up` adds last_name, joined_email_list_at and left_email_list_at with
      `if_not_exists`, and on THIS app it added none of them — all three predate
      it (last_name from create_users, the newsletter pair from the quest flow).
      Reversing would drop columns this migration never created and destroy the
      data in them.

      If you truly want one of these columns gone, drop it by hand, in its own
      migration, having checked what depends on it.
    MSG
  end
end
