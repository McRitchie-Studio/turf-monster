require "test_helper"

# Contract for the studio-engine pin.
#
# The Gemfile pin is `~> 0.43`, which permits anything below 1.0 — so the pin
# string alone does NOT tell you what this app runs. That gap has bitten twice.
# Reading the pin as the version is how "turf is on 0.31" got believed while the
# lockfile said 0.39; and `~> 0.42` later let the lockfile reach 0.43 with nobody
# ADOPTING 0.43, which is what installs its migrations — the drift the columns
# below now assert against.
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
  #   0.43 — EmailCatalog records WHOSE a background is at registration, so a
  #          host that ships its own artwork can layer. 0.42 gated it on the
  #          ENGINE owning the flat image, and this app owns its own .jpg — so
  #          on 0.42 the sign-in email silently falls back to the flat banner.
  #          That is the failure this floor exists to catch: nothing raises, the
  #          email just stops carrying the artwork.
  MINIMUM = Gem::Version.new("0.43.0")

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)
    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(the email-free local-review CTA needs >= 0.36; Studio::EmailSetting needs >= 0.42; " \
                    "a host-owned layered banner needs >= 0.43)"
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
    #
    # 0.43 adds the body, the CTA and the shared footer. This list stopped at the
    # 0.42 columns while the resolved gem moved to 0.43 — because a two-segment
    # `~> 0.42` PERMITS 0.43, so the lockfile advanced without anyone ADOPTING
    # 0.43, and adopting is what installs its migrations.
    %w[header header_fallback subtext subject
       body cta_text cta_color cta_enabled discord_url].each do |column|
      assert_includes Studio::EmailSetting.column_names, column,
                      "studio_email_settings.#{column} is missing — a follow-up migration did not run"
    end
  end

  # THE PATH THAT ACTUALLY BREAKS, and the reason the column list above is not
  # enough on its own.
  #
  # Studio::EmailSetting.table_ready? checks only table_exists?, never columns,
  # so nothing raises at boot. READS survive too — the table is empty in a fresh
  # app, so the &. chain short-circuits before touching a missing column. The
  # SAVE path is unconditional: Studio::EmailsController#copy assigns
  # record.body=, which is a NoMethodError against a 0.42-era table.
  #
  # So /admin/emails renders perfectly and cannot save, and it is silent until
  # somebody presses Save. Asserting the WRITE is what turns that from luck into
  # a mechanism.
  test "an operator can save every field /admin/emails offers" do
    setting = Studio::EmailSetting.find_or_initialize_by(email_key: "magic_link")

    assert_nothing_raised do
      setting.update!(
        header: "Welcome {name}!", header_fallback: "Your Magic Link",
        subtext: "your sign-in link is below", subject: "Your {app} sign-in link",
        body: "Hi {name}, tap the button below.",
        cta_text: "Sign in", cta_color: "#4BAF50", cta_enabled: true,
        discord_url: "https://discord.gg/example"
      )
    end

    assert_equal "Hi {name}, tap the button below.", setting.reload.body
  end
end
