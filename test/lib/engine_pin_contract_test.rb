require "test_helper"

# Contract for the studio-engine pin.
#
# The Gemfile pin is `~> 0.31`, which permits anything below 1.0 — so the pin
# string alone does NOT tell you what this app runs, and reading it as the
# version is how "turf is on 0.31" got believed while the lockfile said 0.39.
# These assert the FLOOR we actually depend on, so a `bundle update` that walked
# the resolved version backwards fails here instead of at runtime.
class EnginePinContractTest < ActiveSupport::TestCase
  # Raised deliberately by the 0.42 adoption. Each entry is a feature this app
  # now relies on, with the version that introduced it — so the floor is
  # justified rather than aspirational.
  #
  #   0.36 — Studio::LocalReviewsController resolves the reviewer itself
  #          (Studio.local_review_email, else the seeded admin), which is what
  #          makes the task board's email-free WAITING APPROVAL button work.
  #   0.42 — Studio::EmailSetting backs the operator-editable layered email
  #          banner on /admin/emails, a page this app mounts from the engine.
  MINIMUM = Gem::Version.new("0.42.0")

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)
    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(the email-free local-review CTA needs >= 0.36; Studio::EmailSetting needs >= 0.42)"
  end

  test "the engine tables this app's mounted pages read actually exist" do
    # The engine ships these as migrations; a host that skips
    # `studio_engine:install:migrations` boots fine and then 500s on the page
    # that touches them. This app was missing all three at 0.39 — the adoption
    # installed them, and this keeps a future host-schema reset honest.
    %w[studio_links studio_email_settings studio_email_deliveries studio_enumerals].each do |table|
      assert ActiveRecord::Base.connection.table_exists?(table),
             "#{table} is missing — run bin/rails studio_engine:install:migrations && db:migrate"
    end
  end

  test "Studio::EmailSetting is usable, not just present" do
    # Table-exists is not the same as the model working: the 0.42 migrations add
    # `copy` and `subject` columns in two follow-ups, and a host that ran only
    # the create would pass the check above and still break /admin/emails.
    assert_nothing_raised { Studio::EmailSetting.limit(1).to_a }
    # The two follow-ups add the banner's WORDS (add_copy → header,
    # header_fallback, subtext) and its subject line (add_subject → subject).
    # Named by the columns they create, not by the migration filenames: the
    # "copy" migration adds no column called `copy`, and asserting the filename's
    # noun is how this test first failed.
    %w[header header_fallback subtext subject].each do |column|
      assert_includes Studio::EmailSetting.column_names, column,
                      "studio_email_settings.#{column} is missing — a follow-up migration did not run"
    end
  end
end
