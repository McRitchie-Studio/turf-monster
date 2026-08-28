require "test_helper"

# Contract for the studio-engine pin.
#
# The Gemfile pin is `~> 0.43`, which permits anything below 1.0 — so the pin
# string alone does NOT tell you what this app runs. That gap has bitten twice.
# Reading the pin as the version is how "turf is on 0.31" got believed while the
# lockfile said 0.39; and `~> 0.42` later let the lockfile reach 0.43 with nobody
# ADOPTING 0.43, which is what installs its migrations — the drift the migration
# check below now asserts against.
# These assert the FLOOR we actually depend on, so a `bundle update` that walked
# the resolved version backwards fails here instead of at runtime.
#
# THE CONTRACT IS NOW DERIVED, NOT ENUMERATED. This file used to answer "is the
# schema current?" with a hand-written list of `studio_email_settings` columns.
# That list went stale at the 0.42 columns while the lockfile resolved 0.43 —
# green test, drifted app — and re-typing it only resets the clock. Worse, a
# column list can only ever defend the ONE table somebody thought to list: when
# 0.46 added the standard user-profile columns to `users`, this file stayed green
# through the entire drift, because `users` was not on the list and never would
# have been. The migration check below asks the general question instead.
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
  #   0.46 — Studio::OnboardingController serves the first-name step, and
  #          Studio.first_name_outstanding? / FIRST_NAME_SKIP_SESSION_KEY /
  #          draw_onboarding_routes / onboarding_steps_resolver are the seam this
  #          app adopted it through. This app DELETED its local copy, so below
  #          0.46 the routes are never drawn and the onboarding modal's two
  #          hardcoded POSTs 404 — the chain stalls on the first-name step.
  #   0.52 — Studio.draw_profile_routes serves the shared /profile page,
  #          Studio::ProfileSections is the registry this app declares its own
  #          rows through (config/initializers/studio.rb replaces the newsletter
  #          row and appends quests), and Studio::Newsletter backs both. The
  #          Gemfile comment moved to 0.52 when that landed; THIS constant did
  #          not, which is the drift the file exists to catch and did not.
  #   0.54 — studio/fields/_date_of_birth, the engine's one DOB field.
  #          app/views/modals/_birthday renders it instead of its old forked
  #          copy of the three selects. This is the sharpest floor in the list
  #          because it fails LOUDLY and immediately: below 0.54 the partial does
  #          not exist, so the age-gate modal raises on render rather than
  #          degrading. It also carries /profile/edit's birthday row off the
  #          retired calendar popover onto the same three selects.
  #   0.56 — studio/_hold_button + studio/_fizz_layer + Studio::FizzHelper, and
  #          the ACTION family (.hold-btn / .hold-stack / .fizz-bit) in
  #          engine-motion.css. This app DELETED its local copy of all four —
  #          the two partials, the helper, and ~500 lines of duplicated CSS — so
  #          below 0.56 the contest board's confirm button raises on render, and
  #          the entry-token modals with it. Same shape as the 0.54 floor: it
  #          fails loudly rather than degrading, which is the kind of floor
  #          worth having.
  #   0.57 — the geo primitive this app now RENDERS instead of carrying:
  #          Studio::GeoDetection (detection, the geo_* helpers,
  #          require_geo_allowed), Studio::GeoSetting + the studio_geo_settings
  #          table, the /admin/geo manager and the public /geo/check probe drawn
  #          by config.draw_geo_routes, components/_geo_badge, and the 52 US
  #          state flags as gem assets. This app DELETED its local model, helper,
  #          controller, view, badge partial, geocoder initializer, routes and
  #          public/state-flags, so below 0.57 ApplicationController raises at
  #          `include Studio::GeoDetection` and the app does not boot at all —
  #          the loudest floor in this list, which is the kind worth having.
  MINIMUM = Gem::Version.new("0.62.2")

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)
    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(the email-free local-review CTA needs >= 0.36; Studio::EmailSetting needs >= 0.42; " \
                    "a host-owned layered banner needs >= 0.43; the adopted first-name onboarding " \
                    "endpoints need >= 0.46; the shared /profile page and its section registry need " \
                    ">= 0.52; the shared date-of-birth field rendered by modals/_birthday needs " \
                    ">= 0.54; the rail-row and close-x chrome primitives this app RENDERS need >= 0.61, and an UNESCAPED rail-row click handler needs >= 0.62.2)"
  end

  # SELF-FIRING, and that is the whole design.
  #
  # The layer-scale ADOPTION SHIM — a local :root in application.css mirroring
  # the engine's --z-* tiers — was CORRECT while the pin predated the gem that
  # ships them, and became a liability the instant it did not. application.css
  # imports the engine build at the top and the shim's :root came after it, so on
  # equal specificity and later source order THE SHIM WON. This app kept a frozen
  # private copy of the shared scale while believing it shared one, and the next
  # engine layer change would simply not have arrived. Nothing failed. Nothing
  # looked wrong. It was found by a reviewer reading another repo's diff.
  #
  # A code comment or a ledger entry saying "delete at the bump" is a reminder,
  # not a gate — the previous one lived in a task's agent_context, which archives
  # away with the task. This asks the question the bump itself answers: once the
  # RESOLVED engine defines a tier, any local definition of it is drift. Silent
  # while the pin is old; red the instant it is not.
  #
  # TWO THINGS IT DELIBERATELY DOES DIFFERENTLY FROM THE HUB'S FIRST CUT of this
  # guard, both found in review there and not worth inheriting:
  #
  #   1. NO TRAILING SEMICOLON IS REQUIRED. The hub matched
  #      /(--z-[a-z-]+):\s*-?\d+;/, so a legal `:root { --z-modal: 999 }` — last
  #      declaration in a block, no `;` — evaded it in silence. This matches the
  #      NAME and its colon and does not care what follows, which also catches a
  #      redefinition to a var() or a calc() rather than only to an integer.
  #   2. IT SCANS EVERY SOURCE CSS FILE THIS APP SHIPS, not one filename. The
  #      hub scanned application.css alone while a second stylesheet was imported
  #      after the engine with identical outranking power, so a tier relocated by
  #      one line into that file evaded the guard completely. The order matters
  #      and the filename does not: everything this app ships is loaded after the
  #      engine build it imports first.
  test "no local CSS redefines a layer tier the resolved engine already ships" do
    engine_css = Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css").read
    tiers = engine_css[/^:root \{(.*?)^\}/m].to_s.scan(/(--z-[a-z-]+)\s*:/).flatten.uniq

    # ASSERTED, NOT SKIPPED, and the assertion is on the guard's own input. A
    # `skip` would switch this off silently and keep its name on the ratchet; an
    # empty tier list would do the same thing without even announcing it, since
    # a scan over no needles finds no offenders and passes forever. The
    # precondition is worth failing on in its own right: this app is pinned to an
    # engine that ships the scale, so an engine that does not means the pin
    # walked backwards.
    assert_includes tiers, "--z-modal",
                    "the resolved studio-engine (#{Studio::VERSION}) no longer defines the layer " \
                    "scale in its :root — either the pin walked backwards or that block moved, " \
                    "and this guard is reading nothing either way"

    files = source_css_files
    assert_includes files.map { |f| f.relative_path_from(Rails.root).to_s },
                    "app/assets/tailwind/application.css",
                    "the CSS entrypoint is not in this guard's file list, so the file the shim " \
                    "actually lived in is no longer being scanned"

    offenders = files.flat_map do |path|
      # Comments EXPLAIN the tiers — including this deletion — so scanning them
      # would make documenting the fix impossible, which is the opposite of the
      # point.
      body = path.read.gsub(%r{/\*.*?\*/}m, " ")
      tiers.select { |tier| body.match?(/#{Regexp.escape(tier)}\s*:/) }
           .map { |tier| "#{path.relative_path_from(Rails.root)} → #{tier}" }
    end

    assert_empty offenders,
                 "the resolved engine ships the layer scale, so these local definitions now " \
                 "OUTRANK it — every stylesheet here is loaded after the engine build " \
                 "application.css imports first, and later source order wins on equal " \
                 "specificity:\n  #{offenders.join("\n  ")}\n" \
                 "Delete them and read the engine's tiers through var(--z-*)."
  end

  # THE FLOOR AND THE PIN MUST AGREE. Two places state the same fact — the
  # Gemfile's `~> x.y` and MINIMUM above — and the interesting failure is not
  # either one being wrong, it is them DISAGREEING, which is what happened
  # between 0.52 and this commit: the Gemfile said 0.52 while MINIMUM still said
  # 0.46, so a resolve back to 0.46 would have passed this file and broken the
  # app. Asserting the relationship costs one test and closes that gap for good.
  #
  # `~>` on two segments allows anything below the next MAJOR, so the pin can
  # never be a ceiling here — only its lower bound is meaningful, and that lower
  # bound is what must match.
  # A SOURCE OVERRIDE IS NOT DRIFT. studio-engine's consumer-CI lane rewrites this
  # app's Gemfile to build against the engine commit under test —
  # `sed 's|^gem "studio-engine".*|gem "studio-engine", path: "../studio"|'` in
  # .github/workflows/consumer-ci.yml. In that mode there is no version pin BY
  # DESIGN, so there is no lower bound and the pin-vs-MINIMUM relationship this
  # test guards is not expressible. Asserting it anyway failed EVERY engine PR
  # from the day this test landed (2026-08-16, aabfb8b) — a CSS-only engine change
  # went red here while the engine suite, both browser lanes and the sibling
  # consumer lane were green. The guard was right; it just never met the rewrite.
  #
  # So: skip when the gem is sourced by path/git, and keep biting whenever a real
  # version pin is present. The skip is NARROW — a MISSING studio-engine line, or
  # one pinned some other way, still fails.
  test "the Gemfile pin's lower bound is the floor this file declares" do
    gemfile = Rails.root.join("Gemfile").read
    declaration = gemfile[/^\s*gem\s+["']studio-engine["'].*$/]

    assert declaration, "no `gem \"studio-engine\"` line found in the Gemfile at all"

    # STRIP THE COMMENT BEFORE READING THE LINE. This declaration carries a
    # multi-thousand-character hand-written comment that GROWS on every floor
    # bump — it documents every historical floor back to 0.31. Scanning the raw
    # line let that prose vote twice: a comment mentioning a `path:` override
    # would trip the skip below and silently pass genuine drift, and the pin
    # regex could read a version out of the history instead of the pin. Neither
    # is reachable with today's comment text, but the comment is DESIGNED to
    # accumulate, so the exposure grows every time someone documents a bump.
    declaration = declaration.sub(/#.*/, "")

    if declaration.match?(/\b(?:path|git|github|branch):/)
      skip "studio-engine is sourced by override (#{declaration.strip}) — no version pin to compare"
    end

    pin = declaration[/["']~>\s*([\d.]+)["']/, 1]

    assert pin, "no `gem \"studio-engine\", \"~> x.y\"` line found in the Gemfile"
    assert_equal Gem::Version.new(pin).segments.first(2), MINIMUM.segments.first(2),
                 "the Gemfile pins ~> #{pin} but MINIMUM says #{MINIMUM}. One of them was moved " \
                 "and the other was not — the version this app actually requires must be stated " \
                 "the same way in both places."
  end

  # THE TEST THAT CATCHES A GEM BUMP OUTRUNNING AN ADOPTION.
  #
  # `studio_engine:install:migrations` COPIES the gem's migrations into this
  # repo, renumbering each to the install time and appending a `.studio_engine`
  # scope suffix — so the version never survives the copy and only the bare name
  # does. That copy is a MANUAL step: bumping the gem does not perform it, and an
  # app that skips it boots perfectly, passes its suite, and is missing columns
  # the gem's own code writes to.
  #
  # A pending-migration check cannot answer this. The test schema is loaded from
  # schema.rb, which stamps every version as already run, so a migration that was
  # never copied is not "pending" — it is invisible. Comparing NAMES is the
  # honest question, and it is the same question install:migrations itself asks.
  #
  # This is not hypothetical here: engine 0.46 shipped
  # add_standard_user_profile_columns and this app did not install it, while
  # every other assertion in this file stayed green.
  #
  # IT IS THE NAME HALF OF THE CONTRACT, AND ONLY THE NAME HALF. Reducing both
  # sides to the bare name is what makes the comparison possible — the installer
  # renumbers every copy — and it is equally this test's ceiling: a migration
  # whose BODY changed in the gem keeps its name, so this stays green while the
  # installed copy is a stale fork. That happened on 2026-08-13.
  # `test/lib/engine_migration_content_test.rb` is the content half.
  test "every migration the resolved engine ships has been installed here" do
    assert_empty missing_engine_migrations,
                 "the resolved studio-engine (#{Studio::VERSION}) ships migrations this app never " \
                 "copied: #{missing_engine_migrations.join(", ")}. Run " \
                 "`bin/rails studio_engine:install:migrations && bin/rails db:migrate` — " \
                 "bumping the gem does NOT do it for you."
  end

  test "the engine tables this app's mounted pages read actually exist" do
    # The engine ships these as migrations; a host that skips
    # `studio_engine:install:migrations` boots fine and then 500s on the page
    # that touches them. This app was missing all three at 0.39 — the adoption
    # installed them, and this keeps a future host-schema reset honest.
    # studio_geo_settings joins the list because the geo gate READS it on every
    # request: Studio::GeoSetting.blocked? decides whether a visitor may enter a
    # contest or move funds. A missing table is nil-safe by design (the gate then
    # blocks nobody), which is exactly why its absence has to fail HERE rather
    # than silently un-enforce the legal exclusion list in production.
    %w[studio_links studio_email_settings studio_email_deliveries studio_enumerals
       studio_geo_settings].each do |table|
      assert ActiveRecord::Base.connection.table_exists?(table),
             "#{table} is missing — run bin/rails studio_engine:install:migrations && db:migrate"
    end
  end

  test "Studio::EmailSetting is usable, not just present" do
    # Table-exists is not the same as the model working: the 0.42 migrations add
    # `copy` and `subject` columns in two follow-ups, and a host that ran only
    # the create would pass the check above and still break /admin/emails.
    assert_nothing_raised { Studio::EmailSetting.limit(1).to_a }
  end

  # THE COLUMN LIST THAT USED TO LIVE ABOVE IS DELIBERATELY GONE.
  #
  # It named the same nine columns the save below writes, so it asserted a strict
  # SUBSET of what this test proves — a missing column is a NoMethodError on
  # assignment, which fails here first and with a better message. Keeping both
  # bought nothing and cost the thing that actually hurt: the list had to be
  # hand-extended on every engine release, and the release it was NOT extended
  # for is the one that drifted. The general question ("is any engine migration
  # uninstalled?") is now asked once, above, for every engine table at once.
  #
  # THE PATH THAT ACTUALLY BREAKS:
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

  private

    # EVERY SOURCE CSS FILE THIS APP SHIPS — not the entrypoint alone.
    #
    # app/assets/builds is deliberately absent: it holds the COMPILED output and
    # the generated engine import wrapper, so scanning it would report the
    # engine's own scale as a local redefinition on every run.
    def source_css_files
      (Dir[Rails.root.join("app/assets/tailwind/**/*.css")] +
       Dir[Rails.root.join("app/assets/stylesheets/**/*.css")]).map { |path| Pathname(path) }
    end

    # Engine migration names with no counterpart in this repo's db/migrate.
    #
    # Both sides are reduced to the bare name, because the copy rewrites
    # everything else: the gem's
    # `20260813220000_add_standard_user_profile_columns.rb` installs here as
    # `20260813222322_add_standard_user_profile_columns.studio_engine.rb`, so the
    # timestamp and the scope suffix are both noise. The suffix is STRIPPED by
    # pattern rather than matched literally, because it has been spelled both
    # `.studio_engine` and `.studio` across the engine's history.
    #
    # THIS APP COVERS TWO ENGINE MIGRATIONS WITH ITS OWN NATIVES, and that is
    # correct rather than drift: `create_studio_links` and
    # `allow_null_image_cache_owner` exist here as hand-written migrations
    # (db/migrate/20260621120000_create_studio_links.rb and
    # 20260621120001_allow_null_image_cache_owner.rb) that predate the engine
    # shipping its own. `install:migrations` itself skips them for exactly this
    # reason ("Migration with the same name already exists"). Matching on the
    # bare name — not on the suffix — is what makes this check agree with the
    # installer instead of reporting two permanent false positives.
    def missing_engine_migrations
      @missing_engine_migrations ||= engine_migration_names - installed_migration_names
    end

    def engine_migration_names
      Studio::Engine.paths["db/migrate"].existent
                    .flat_map { |dir| Dir.children(dir) }
                    .grep(/\.rb\z/)
                    .map { |file| bare_migration_name(file) }
    end

    def installed_migration_names
      Dir.children(Rails.root.join("db/migrate"))
         .grep(/\.rb\z/)
         .map { |file| bare_migration_name(file) }
    end

    def bare_migration_name(file)
      file.sub(/\A\d+_/, "").sub(/\.[a-z_]+\.rb\z/, "").sub(/\.rb\z/, "")
    end
end
