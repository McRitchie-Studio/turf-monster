require "test_helper"
require "open3"

# Contract for the studio-engine pin.
#
# The Gemfile pin reads `"~> 0.69", ">= 0.69.5"`. The `~>` half permits anything
# below 1.0, so a pin string alone does NOT tell you what this app runs. That gap
# has bitten three times. Reading the pin as the version is how "turf is on 0.31"
# got believed while the lockfile said 0.39; `~> 0.42` later let the lockfile
# reach 0.43 with nobody ADOPTING 0.43, which is what installs its migrations —
# the drift the migration check below now asserts against; and most recently
# `~> 0.64` said nothing whatever about the 0.69.5 this app had come to require,
# because a two-segment `~>` CANNOT state a patch-level floor. That is why the
# pin carries a second requirement, why the guard reads the requirement's
# effective lower bound at full precision, and why there is now a guard that
# derives the question from the source instead of from a number.
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
  #   0.63 — the shared LAYER SCALE, and the QUIETEST floor in this list. The
  #          0.54 and 0.57 floors above fail loudly — a missing partial raises
  #          on render, a missing concern raises at boot. This one raises
  #          nothing at all, which is why it is asserted rather than trusted.
  #          0.63.0 first defines the --z-* tiers in engine.css's :root, ships the
  #          body.modal-open lift for the bar stack AND the app banner, and
  #          defaults the toast seams to the tiers in layouts/studio/_flash. This
  #          app MIRRORED all three in an application.css adoption shim until
  #          delete-turf-layer-shim removed the mirror — it sat after the engine
  #          import, so it OUTRANKED the gem it was copying. With no local copy
  #          left, below 0.63.0 every var(--z-*) here resolves to nothing and the
  #          modal backdrop, navbar, drawer, docked slip and toasts all fall to
  #          z-index:auto — the page silently loses its stacking order entirely.
  #   0.64 — the WALLET surface, and the only floor in this list that stops the
  #          app BOOTING. Three adoptions land on one version:
  #            * `Studio.wallet_debug_sink` and `Studio.wallet_sign_in_statement`
  #              (via the wallet_sign_in_statement_builder accessor) first exist
  #              in 0.64.0's lib/studio.rb. config/initializers/studio.rb SETS
  #              the first of them, so below 0.64.0 `Studio.configure` raises
  #              NoMethodError and nothing boots — louder even than the 0.57 geo
  #              floor, which at least got as far as the concern.
  #            * the solana_sessions/phantom_callback template — the mobile
  #              return leg. This app DELETED both halves of the round trip
  #              (app/javascript/phantom_deeplink.js and its own phantom_callback
  #              view), and the callback half is STILL the engine's, so below
  #              0.64.0 the return leg has no template at all.
  #
  #          WHAT LEFT THIS FLOOR ON 2026-09-01, and why the floor did not move:
  #          /tasks/turf-rides-gem-modals moved the PARTIALS to solana-studio.
  #          studio/solana/_phantom_deeplink, studio/modals/_wallet_connect and
  #          studio/modals/_web3_step_up are no longer rendered from the engine
  #          here, so they no longer justify an engine floor — their floor is now
  #          solana-studio 0.5.3 (see SOLANA_STUDIO_MINIMUM below), and the same
  #          goes for the shared picker's `canDeepLink` getter, which travelled
  #          with the picker.
  #
  #          THE ENGINE FLOOR STAYS AT 0.64.0 ANYWAY, on the two bullets above,
  #          and BOTH are independent of the partials: the accessors are set in
  #          this app's initializer (a BOOT failure) and the callback template is
  #          still the engine's. The migration therefore removes a REASON without
  #          moving the NUMBER. There is a third tie besides: the gem's
  #          _phantom_deeplink itself reads Studio.wallet_sign_in_statement, so
  #          the partials depend on studio-engine >= 0.64 at RENDER time even
  #          from inside solana-studio.
  #          DERIVED BY DATING EVERY SURFACE, not by reading a changelog — the
  #          gem's CHANGELOG files everything after 0.39 under "Unreleased", so
  #          it cannot date anything here. Each partial rendered, accessor
  #          configured and symbol named was traced to its FIRST appearance
  #          across the installed 0.4.13-0.65.2 trees; 0.64.0 is the maximum.
  #   0.69.5 — Studio::FULL_NAME_MAX_LENGTH, and the FIRST floor in this list
  #          that is a PATCH rather than a minor. turf-modal-caps-forty
  #          (PR 573) made the constant a RENDER-TIME dependency on EVERY
  #          page. It still is, but by a different route since
  #          turf-adopts-first-name: layouts/application renders the ENGINE's
  #          studio/modals/onboarding/first_name unconditionally and the
  #          <template x-if> wrapper is CLIENT-side, so the ERB evaluates on
  #          every request and that partial reads the constant for the field's
  #          maxlength. Below 0.69.5 that is a NameError on every
  #          page render — a TOTAL outage, the same class as the 0.64 boot
  #          failure above, not a degraded field.
  #          DATED TWO WAYS, because the number is the whole point here,
  #          and BOTH ARE STATED AS A MINIMUM RATHER THAN AS A LIST:
  #          grepping every installed studio-engine tree, across both Ruby
  #          gem homes, for the ASSIGNMENT `FULL_NAME_MAX_LENGTH =` under
  #          lib/ and app/ finds the LOWEST version defining it to be
  #          0.69.5, and NO version below it defines it (the COUNT of those
  #          versions is deliberately absent: it describes one laptop's
  #          unpacked gems, not the gem);
  #          and in the gem repo the EARLIEST tag containing the commit
  #          that adds it (f2c2d1c, 2026-09-06) is v0.69.5, while that
  #          commit's own version.rb still reads 0.69.4 — so 0.69.4 is the
  #          last release WITHOUT it.
  #          WHY "EARLIEST" AND "LOWEST" RATHER THAN A LIST — this sentence
  #          learned it by rotting. It used to read "contained by exactly
  #          the v0.69.5 and v0.70.0 tags", and that was TRUE WHEN IT WAS
  #          WRITTEN AND FALSE FIVE MINUTES LATER — the sharper version of
  #          the lesson, because no care at writing time prevents it.
  #          e68837c3 wrote the sentence at 00:24:22; v0.71.0's TAG OBJECT
  #          was created at 00:29:14, 4m52s AFTER. The author was still in
  #          the line: 4f5c3e76 rewrote it at 00:31:55, 2m41s past false,
  #          and shipped it; it was still false at the #581 merge
  #          (01:07:18), and v0.72.0 was tagged 01:09:11. All times
  #          2026-09-07 -0600. THE CLOCK IS THE TAG OBJECT'S OWN DATE
  #          (`git for-each-ref --format='%(taggerdate:iso-strict)'
  #          refs/tags/v0.71.0`), NOT the tagged commit's (00:12:26, `git
  #          log -1 --format=%cI v0.71.0^{}`), because `git tag --contains`
  #          answers about tags that EXIST — and reading the second as the
  #          first is what INVERTED the first telling of this story.
  #          Measured 2026-09-07, four tags contain f2c2d1c. An enumeration
  #          of containing tags is a CLOCK, not a fact — every release
  #          falsifies it — so the note whose whole job is to keep a floor
  #          from rotting rotted in under five minutes. The EARLIEST one moves
  #          only if a release DELETES the constant, and that is what the
  #          derived guard below catches. The citation is now asserted
  #          rather than trusted: see "the floor note's tag citation names
  #          the EARLIEST tag containing the commit it names" below.
  #          WHY THE PIN GREW A SECOND REQUIREMENT, and why the guard below
  #          changed shape with it: `~> 0.69` means `>= 0.69, < 1.0`, so it
  #          ADMITS 0.69.0 through 0.69.4 — the exact window that raises. A
  #          two-segment `~>` CANNOT express a patch floor. The pin now reads
  #          `"~> 0.69", ">= 0.69.5"`, and the pin guard below compares the
  #          requirement's EFFECTIVE lower bound at full precision instead of
  #          the `~>` operand's first two segments — which is what let a floor
  #          five releases too low agree with itself here.
  #   0.72.0 — the two first-name-card LOCALS this app passes, and the QUIETEST
  #          floor in this list by some distance. turf-adopts-first-name deleted
  #          app/views/modals/_onboarding.html.erb and now renders the engine's
  #          studio/modals/onboarding/first_name from both host registration
  #          lists. THE PARTIAL IS NOT THE FLOOR — it exists back to 0.66.2 — so
  #          unlike the 0.54 and 0.57 floors above, nothing here raises.
  #          DERIVED FROM THE GEM REPO by reading that partial at each tag:
  #          v0.70.0 and v0.71.0 carry NEITHER local below, v0.72.0 carries
  #          both, and `required` alone first appears in 0.70.0.
  #            placeholder_names — the opt-in typed placeholder. Below 0.72.0
  #              the local is not read and the field silently falls back to a
  #              static placeholder.
  #            detail.saved on the done event — the sharp one.
  #              layouts/application's onboarding-step-done listener BRANCHES on
  #              it before clearing $store.session.firstNameRequired and
  #              re-dispatching first-name-saved, which is how
  #              contests/_turf_totals_board resumes an entry its first-name
  #              gate interrupted. Below 0.72.0 the key is undefined on every
  #              path, so the branch never fires and a held entry never resumes
  #              — a dead hold-to-confirm with nothing logged anywhere.
  # 0.73.0 — solana_sessions/phantom_callback first dispatches a pending wallet_dl
  #          journal to SolanaStudio.walletOps.resume BEFORE its legacy signIn
  #          path. This app now sends contest entries out over the redirect
  #          transport, so the RETURN leg is not optional: below 0.73.0 the
  #          callback does not recognise the journal, falls through to the legacy
  #          branch, and hands a returning ENTRY to a sign-in flow that has no
  #          idea what a contest entry is. The user approves a transaction in
  #          their wallet, comes back, and lands nowhere — nothing raises, nothing
  #          logs, no test fails. DERIVED by unpacking every published gem across
  #          the boundary: 0.72.0, 0.72.1, 0.72.2 and 0.72.3 all contain ZERO
  #          occurrences of the dispatch guard; 0.73.0 contains it. Stated as the
  #          EARLIEST containing version, because a list of versions goes stale on
  #          the next release while "earliest" is a fact about the code.
  MINIMUM = Gem::Version.new("0.73.0")

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)
    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(the email-free local-review CTA needs >= 0.36; Studio::EmailSetting needs >= 0.42; " \
                    "a host-owned layered banner needs >= 0.43; the adopted first-name onboarding " \
                    "endpoints need >= 0.46; the shared /profile page and its section registry need " \
                    ">= 0.52; the shared date-of-birth field rendered by modals/_birthday needs " \
                    ">= 0.54; the rail-row and close-x chrome primitives this app RENDERS need >= 0.61, and an UNESCAPED rail-row click handler needs >= 0.62.2; and the shared layer scale this app no longer mirrors locally needs >= 0.63; and the wallet surface needs >= 0.64 — config.wallet_debug_sink is SET in this app's initializer, so below it Studio.configure raises at boot; and Studio::FULL_NAME_MAX_LENGTH needs >= 0.69.5 — the engine's studio/modals/onboarding/first_name reads it for the field maxlength and layouts/application renders that partial on EVERY page, so below it every request raises NameError; and the first-name card's placeholder_names local and its done-event detail.saved key need >= 0.72.0, both of which fail SILENTLY below it — the typed placeholder goes static, and the entry-gate resume never fires)"
  end

  # ── THE FLOOR, ASKED OF THE SOURCE INSTEAD OF OF A NUMBER ───────────────
  #
  # MINIMUM above is hand-written, and a hand-written floor rots in exactly one
  # way: the app grows a reference to something NEWER than the number, and
  # nothing says so. That is not hypothetical here — it is what this test was
  # written for. turf-modal-caps-forty adopted Studio::FULL_NAME_MAX_LENGTH,
  # which first exists in 0.69.5, while MINIMUM still read 0.64.0 and the pin
  # still read `~> 0.64`. Every resolve in [0.64.0, 0.69.4] passed the guard
  # above — the guard that exists to catch a backwards resolve — and then raised
  # NameError on every page render. Bumping the number closes that window and
  # leaves the MECHANISM intact: the next adoption reopens it in silence.
  #
  # This asks the question the number was standing in for, and derives both
  # sides. The app's side is every `Studio::` constant its own source NAMES; the
  # engine's side is what the RESOLVED gem actually defines. A backwards resolve
  # fails here without anyone having remembered anything, and so does a constant
  # the engine REMOVES on the way up — which no floor can ever catch.
  #
  # WHY IT DOES NOT DATE CONSTANTS ACROSS GEM VERSIONS, which is the guard that
  # first suggests itself: "resolve the earliest engine version defining each
  # reference, and fail when the pin sits below the maximum of those" computes a
  # better answer — it would tell you the floor IS 0.69.5 rather than merely
  # that today's resolve is wrong. It needs every historical gem tree to do it.
  # Locally that is 128 unpacked studio-engine trees at 22 MB each, 1.1 GB. CI
  # installs from Gemfile.lock (`bundler-cache: true`), so it has exactly ONE
  # tree — the resolved one — and a guard that can only run on the laptop that
  # happens to have the other 127 is not a guard. This version needs no history
  # at all: whatever bundler resolved is on disk by definition, so it runs
  # everywhere the suite runs, which is the property that makes it bite.
  #
  # It is the WEAKER question and the STRONGER guard, and the pair is the point:
  # the pin refuses the bad resolve, and this catches it if the pin is ever
  # wrong again.
  test "every Studio constant this app names is defined by the resolved engine" do
    scan       = studio_source_scan
    references = scan.fetch(:references)

    # ── CONTROLS. A source-scanning test is exit-blind: a glob that matches
    # nothing, a root that moved, or an encoding guard that swallows every file
    # produces an EMPTY scan, and an empty scan satisfies the real assertion
    # below perfectly. These prove the scan read the input before its verdict is
    # allowed to mean anything.
    assert_operator scan.fetch(:files_read), :>, 500,
                    "the scan read #{scan.fetch(:files_read)} files — this app has ~1000 under " \
                    "#{SCANNED_ROOTS.inspect}, so a number this low means the walk is not reaching " \
                    "them and the verdict below is vacuous, not clean"

    SCANNED_ROOTS.each do |root|
      assert references.values.flatten.any? { |path| path.start_with?("#{root}/") },
             "the scan found no Studio constant anywhere under #{root}/ — every one of these roots " \
             "holds at least one today, so an empty root means that subtree was not walked"
    end

    # And the SUBTRACTION has to be doing its job, or the verdict swings on
    # whether an app-defined constant under the engine's namespace happened to
    # be loaded. If this app stops opening any constant inside Studio::, delete
    # this control along with STUDIO_CONSTANT_DEFINITION — do not just relax it.
    assert_includes scan.fetch(:app_defined), "UsernameGeneratorTest",
                    "the scan collected no definition of Studio::UsernameGeneratorTest, which " \
                    "test/lib/studio/username_generator_test.rb opens — so app-defined names are " \
                    "not being subtracted and this verdict depends on test load order"

    # The reference that MOTIVATED this guard, named on purpose. If it ever goes
    # away this fails, and that is correct: it is the fact holding the floor at
    # 0.69.5, so its removal is a reason to revisit MINIMUM rather than something
    # to route around. Re-point the control at another live reference then.
    assert_includes references.keys, "FULL_NAME_MAX_LENGTH",
                    "the scan did not see Studio::FULL_NAME_MAX_LENGTH, which " \
                    "test/integration/onboarding_name_cap_test.rb asserts the rendered field against " \
                    "— either the scanner stopped reading, or the reference that holds the 0.69.5 " \
                    "entry is gone and that entry needs revisiting. It is no longer this app's " \
                    "TOP floor (see the 0.72.0 entry), but it is still a live reference: the app " \
                    "stopped NAMING the constant in a view when turf-adopts-first-name deleted " \
                    "modals/_onboarding, and the engine's partial reads it instead."

    # And the resolver half has to DISCRIMINATE, or the verdict is "nothing is
    # ever missing". Fed a name the engine does not define, it must say so. The
    # name is written as a bare symbol and never as a Studio:: token, because
    # this file is inside the scanned tree and a literal would make the test
    # report itself.
    absent = :AConstantTheEngineHasNeverDefined
    assert_not Studio.const_defined?(absent, false),
               "the negative control #{absent} is actually defined by the engine — pick a name " \
               "that is not, or this control proves nothing"
    assert_equal [absent.to_s], undefined_engine_constants(absent.to_s => ["<negative control>"]).keys,
                 "the resolver did not report a constant the engine does not define — it cannot " \
                 "report a real one either"

    missing = undefined_engine_constants(references)

    assert_empty missing,
                 "this app names #{missing.size} Studio constant(s) the resolved studio-engine " \
                 "#{Studio::VERSION} does not define: " +
                 missing.map { |name, paths| "Studio::#{name} (#{paths.uniq.sort.first(3).join(', ')})" }.join("; ") +
                 ". Either the resolve walked BELOW the floor this app depends on — raise the " \
                 "Gemfile pin and MINIMUM, and write the floor note — or the engine dropped a " \
                 "constant on the way UP and these call sites need to move."
  end

  # The roots this app's own source lives under. Walked whole, including the one
  # GENERATED tree inside them — app/assets/builds, which is gitignored but on
  # disk. That is left in deliberately rather than filtered: a compiled artifact
  # naming a constant the engine does not define is a real inconsistency, not a
  # false positive, and it holds no `Studio::` token at all today. It does mean
  # files_read moves a little depending on whether assets have been built, which
  # is why the control below is a floor rather than an exact count.
  SCANNED_ROOTS = %w[app lib config test].freeze

  # A NAMED reference: `Studio::` followed by one constant segment. Only the
  # first segment is captured, deliberately — `Studio::Geo::Lookup` is recorded
  # as `Geo`, because resolving the parent is the question this guard can answer
  # honestly and a nested miss would need the parent loaded to even ask.
  #
  # A MENTION IN PROSE COUNTS, and that is the intended reading rather than an
  # accident of scanning whole files. This file's own comments name a dozen
  # engine constants; so do several others. A comment naming a constant the
  # engine does not define is wrong in the same way the code would be — it is
  # documentation describing a surface that is not there — and comments are
  # exactly where a floor's justification is written down, so they are the last
  # place worth exempting. The cost is that removing a constant from the engine
  # means updating the prose that discusses it, not just the call sites. That is
  # the correct amount of work.
  STUDIO_CONSTANT_REFERENCE = /\bStudio::([A-Z][A-Za-z0-9_]*)/

  # A DEFINITION, not a reference — this app OPENING a constant inside the
  # engine's namespace. test/lib/studio/username_generator_test.rb does exactly
  # that, and such a constant is supplied by this app rather than depended on
  # from the gem, so it is subtracted from the references before the verdict.
  #
  # SUBTRACTED BY NAME, not skipped by line, and the difference is a flake this
  # guard had while it was being written. Skipping only the definition LINE left
  # every other mention of the same name — a comment in this very file — reading
  # as a reference, and whether it resolved then depended on whether that test
  # file happened to be loaded in the run. It passed a full suite and failed a
  # two-file one. Collecting the names and subtracting them makes the verdict
  # independent of load order, which is what a contract test has to be.
  STUDIO_CONSTANT_DEFINITION = /^\s*(?:class|module)\s+Studio::([A-Z][A-Za-z0-9_]*)/

  def studio_source_scan
    references  = Hash.new { |hash, key| hash[key] = [] }
    app_defined = []
    files_read  = 0

    SCANNED_ROOTS.each do |root|
      Dir.glob(Rails.root.join(root, "**", "*")).sort.each do |path|
        next unless File.file?(path)

        # BINARY FILES ARE SKIPPED BY ASKING, not by extension list. An
        # enumerated list of image suffixes goes stale the first time somebody
        # commits a .webp; "is this text?" never does.
        content = File.read(path, mode: "rb", encoding: "UTF-8")
        next unless content.valid_encoding?

        files_read += 1
        relative = path.delete_prefix("#{Rails.root}/")

        content.each_line do |line|
          app_defined.concat(line.scan(STUDIO_CONSTANT_DEFINITION).flatten)
          line.scan(STUDIO_CONSTANT_REFERENCE) { |(name)| references[name] << relative }
        end
      end
    end

    references.except!(*app_defined)

    { references: references, app_defined: app_defined.uniq.sort, files_read: files_read }
  end

  # Reads the RESOLVED engine, and only the engine's own namespace — `inherit`
  # is false so a same-named top-level constant cannot answer for one the engine
  # does not have. It never triggers an autoload: a pending Zeitwerk autoload
  # already counts as defined, which is the whole question, and loading a
  # controller to ask it would drag the database in for nothing.
  def undefined_engine_constants(references)
    references.reject { |name, _paths| Studio.const_defined?(name, false) }
  end

  # ── The solana-studio floor, which is a DIFFERENT KIND of floor ────────
  #
  # 0.5.3 is where solana_studio/modals/_wallet_connect, _web3_step_up,
  # _phantom_deeplink and _deeplink_assets FIRST EXIST. Derived by unpacking the
  # published .gem artifacts rather than reading a changelog: 0.5.0 and 0.5.1
  # ship two files under app/, 0.5.2 ships three (network_guard.js,
  # auth/_wallet_credential, modals/_network_mismatch), and 0.5.3 ships seven.
  #
  # WHY THIS ONE IS NOT INVISIBLE TO THE RESOLVER, unlike every studio-engine
  # bump above. Those were all two-segment pins, so the old `~>` already admitted
  # the new floor and only the COMMENT moved. This app's pin was `~> 0.5` and it
  # DID already admit 0.5.3 — but Gemfile.lock resolved 0.5.1, and measured in
  # this app on 2026-09-01 all four partials above resolved MISSING through a
  # real LookupContext while studio-engine's copies still resolved FOUND. A
  # missing partial in a `render` call raises NOTHING: the Connect-Wallet picker,
  # the step-up card and the whole mobile Phantom leg would each have rendered as
  # an EMPTY modal. That is why the Gemfile pin is three segments now, and why
  # this assertion reads the RESOLVED version rather than the pin string.
  # 0.9.0 — the picker's mobile handoff rows (mobileHandoffs + openInWallet). The
  #         redirect TRANSPORT itself arrived in 0.8.0 and fails LOUDLY below that
  #         (SolanaStudio.walletOps undefined, walletOps.run throws on the first
  #         hold-to-confirm). 0.9.0 is the floor that moved this constant because
  #         it fails SILENTLY: this app now loads the registry those getters read,
  #         and below 0.9.0 the picker never asks it, so Solflare and Backpack
  #         fall back to their DESKTOP EXTENSION download rows on a phone with
  #         nothing raised, logged, or failed.
  SOLANA_STUDIO_MINIMUM = Gem::Version.new("0.9.0")

  test "the resolved solana-studio is at or above the floor this app renders from" do
    resolved = Gem::Version.new(Gem.loaded_specs.fetch("solana-studio").version.to_s)
    assert_operator resolved, :>=, SOLANA_STUDIO_MINIMUM,
                    "solana-studio #{resolved} is below the #{SOLANA_STUDIO_MINIMUM} floor this " \
                    "app renders from — solana_studio/modals/_wallet_connect, " \
                    "solana_studio/modals/_web3_step_up and solana_studio/_phantom_deeplink " \
                    "first exist in 0.5.3, and below it every one of those render calls " \
                    "resolves to NOTHING without raising: empty modals, no error"
  end

  # The floor above is only worth having if the partials it names actually
  # resolve. This asks the question the render sites ask, through the same
  # LookupContext they use, and it is what a version assertion alone cannot say.
  test "every partial this app renders from solana-studio actually resolves" do
    lookup    = ApplicationController.new.lookup_context
    app_views = Rails.root.join("app/views").to_s

    { "wallet_connect"   => "solana_studio/modals",
      "web3_step_up"     => "solana_studio/modals",
      "phantom_deeplink" => "solana_studio" }.each do |name, prefix|
      template =
        begin
          lookup.find(name, [ prefix ], true)
        rescue ActionView::MissingTemplate
          flunk "#{prefix}/#{name} does not resolve — the render site for it comes up " \
                "EMPTY, silently, with nothing raised in production"
        end

      # Install-agnostic, deliberately: NOT a "/gems/" match, which cannot pass
      # in a consumer-CI lane that bundles the gem as a path checkout.
      assert_not template.identifier.start_with?(app_views),
                 "#{prefix}/#{name} resolved to #{template.identifier}, inside this app's own " \
                 "app/views — a local copy is shadowing the gem at its own virtual path"
    end

    # THE CONTROL, and it is not decoration. A LookupContext that resolved
    # everything — a stubbed lookup, a prefix that silently falls back — would
    # make all three assertions above vacuously true. This proves the probe can
    # still say no.
    assert_raises(ActionView::MissingTemplate,
                  "the lookup resolved a partial that does not exist, so the three " \
                  "assertions above prove nothing") do
      lookup.find("definitely_not_a_partial", [ "solana_studio/modals" ], true)
    end
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
      body = without_css_comments(path.read)
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

  # THE GUARD ON THE STRIPPER. A stripper that returns "" makes every assertion
  # downstream of it pass forever, so the stripper is asserted on its INPUT and
  # its OUTPUT rather than trusted because the guard above went green.
  test "the CSS comment stripper keeps the code it is meant to scan" do
    # 1. ON THE REAL FILES: what survives is a plausible fraction of the source,
    #    not near-empty. The size floor is deliberate — the sprockets manifest at
    #    app/assets/stylesheets/application.css is ~90% banner comment and would
    #    false-RED any percentage rule, and a false red trains people to delete
    #    the guard. This is what goes red if anyone swaps the balance check back
    #    out for a bare span-strip and a stray opener appears.
    gutted = source_css_files.filter_map do |path|
      raw = path.read
      next if raw.length < 2_000

      share = without_css_comments(raw).length.to_f / raw.length
      "#{path.relative_path_from(Rails.root)} kept #{(share * 100).round}%" if share < 0.20
    end

    assert_empty gutted,
                 "comment stripping is eating these stylesheets, so the tier scan reads almost " \
                 "nothing in them and passes for the wrong reason:\n  #{gutted.join("\n  ")}"

    # 2. ON THE SHAPES THAT BREAK COMMENT STRIPPING. Each fixture holds a live
    #    `--z-modal` declaration the guard must still be able to see. The second
    #    is the one the naive span-strip actually fails: an opener inside a
    #    string pairs with a genuine closer below it and swallows the code in
    #    between.
    {
      "unterminated opener" =>
        ":root { --z-modal: 1 }\n/* never closed\n.live { color: red }\n",
      "opener in a string, real closer below" =>
        %(a::after { content: "/*" }\n:root { --z-modal: 1 }\n.x { color: red } /* real */\n),
      "closer inside url()" =>
        %(a { background: url("x*/y.png") }\n:root { --z-modal: 1 }\n),
      "nested-looking opener" =>
        "/* /* still one comment */\n:root { --z-modal: 1 }\n"
    }.each do |shape, css|
      assert_includes without_css_comments(css), "--z-modal",
                      "the stripper ate a live declaration on a #{shape} — that is the fail-open " \
                      "mode this guard exists for: the scan still runs and reads nothing"
    end

    # 3. AND IT MUST STILL STRIP. Without this, a stripper that returned its
    #    input unchanged would satisfy every assertion above — and the guard
    #    would then ban documenting the tiers, failing in the other direction.
    assert_not_includes without_css_comments("/* mentions --z-modal: 9 */\n.live { color: red }\n"),
                        "--z-modal",
                        "a BALANCED comment must still be stripped, or the guard bans its own docs"
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
  #
  # ONE PATTERN, THREE GUARDS. The two pin guards below and the tag-citation
  # guard further down all answer this same question — "is this declaration a
  # source override rather than a version pin?" — and each carried its own copy
  # of the regex. Three copies is three chances to widen one and not the others,
  # which turns a NARROW skip into a silent pass on exactly the drift these
  # guards exist to catch. Named once, read three times.
  SOURCE_OVERRIDE = /\b(?:path|git|github|branch):/

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

    if declaration.match?(SOURCE_OVERRIDE)
      skip "studio-engine is sourced by override (#{declaration.strip}) — no version pin to compare"
    end

    requirements = declaration.scan(/["']([^"']+)["']/).flatten.drop(1)

    assert requirements.any?,
           "the studio-engine pin carries no version requirement at all — an unpinned engine " \
           "resolves to whatever is newest, which is the opposite of a floor"

    floor = requirement_floor(Gem::Requirement.new(requirements))

    # THE MESSAGE NAMES THE ACTUAL CAUSE SET, which it used not to. An EXACT pin
    # (`gem "studio-engine", "0.69.5"`) reached here and was told it stated no
    # lower bound — a constraint that was present, exact, and the tightest one
    # expressible. requirement_floor reads `=` now, so the only requirements that
    # can arrive here are ceilings and `>`, and the sentence says so.
    assert floor,
           "the studio-engine pin states no LOWER bound this guard can read " \
           "(#{requirements.inspect}) — a `< x.y` ceiling alone permits every version below it, " \
           "which is what this file exists to refuse, and a `> x.y.z` names no least version to " \
           "compare (see requirement_floor). `~>`, `>=` and an EXACT `= x.y.z` all state a floor " \
           "and are read as one."

    # COMPARED AT FULL PRECISION, and that is the fix rather than the style. This
    # assertion used to read `Gem::Version.new(pin).segments.first(2)` against
    # `MINIMUM.segments.first(2)` — major and minor only. That truncation is what
    # let a floor five releases too low agree with itself: `~> 0.64` and MINIMUM
    # 0.64.0 matched on [0, 64] while the app had already come to depend on
    # Studio::FULL_NAME_MAX_LENGTH from 0.69.5, and every resolve in
    # [0.64.0, 0.69.4] passed HERE and then raised on every page render. The two
    # segments were never enough to state the floor, because a patch-level floor
    # cannot be written as a two-segment `~>` at all: `~> 0.69` admits 0.69.0.
    # So the pin now carries a second requirement, and this reads the EFFECTIVE
    # lower bound of the whole requirement list instead of one operator's operand.
    assert_equal MINIMUM, floor,
                 "the Gemfile's studio-engine requirement #{requirements.inspect} has an effective " \
                 "floor of #{floor}, but MINIMUM says #{MINIMUM}. One of them was moved and the " \
                 "other was not — the version this app actually requires must be stated the same " \
                 "way in both places, to the PATCH. A two-segment `~> x.y` cannot state a " \
                 "patch-level floor (it admits x.y.0); pair it with an explicit `>= x.y.z`."
  end

  # The lowest version a requirement list actually admits, or nil when it states
  # no lower bound at all. `~>`, `>=` and `=` all pin from below at their own
  # operand, and the tightest of them wins; `<`, `<=` and `!=` bound from above
  # and say nothing about the floor.
  #
  # `=` IS HERE BECAUSE ITS ABSENCE MISDESCRIBED THE FAILURE, not because an
  # exact pin was ever accepted. `gem "studio-engine", "0.69.5"` parses as
  # `= 0.69.5` — a requirement whose least admitted version is 0.69.5, plainly a
  # lower bound — and this returned nil for it, so the assertion above reported
  # "the studio-engine pin states no LOWER bound". That FAILS CLOSED, which is
  # why it was never urgent: an exact pin went red rather than silently passing.
  # But the sentence sent the reader hunting for a missing constraint that was
  # present, exact, and the tightest one expressible. A guard that refuses for
  # the wrong stated reason costs the next person the time it saves.
  #
  # `>` STAYS DELIBERATELY ABSENT, and the difference is real rather than
  # stylistic: `> 0.69.5` admits everything ABOVE 0.69.5 and not 0.69.5 itself,
  # so it has no least element at all and treating its operand as the floor
  # would be off by an unknowable amount. `= 0.69.5` has a least element and it
  # is exactly the operand. So `>` still returns nil and still reports "no lower
  # bound" — which for `>` is the honest description.
  #
  # A list that pairs `=` with a HIGHER `>=` is unsatisfiable, and `.max` would
  # report the `>=` operand for it. That is bundler's refusal to make, not this
  # guard's: the resolver never gets past such a Gemfile, so the suite that
  # reads it never runs.
  def requirement_floor(requirement)
    requirement.requirements.filter_map { |op, version| version if ["~>", ">=", "="].include?(op) }.max
  end

  # WHY THE LOCKFILE IS NOT GUARDED HERE, written down because the obvious guard
  # is INERT and was very nearly shipped.
  #
  # The floor is stated in three files, not two: the Gemfile pin, MINIMUM above,
  # and Gemfile.lock's DEPENDENCIES entry (`studio-engine (~> 0.69, >= 0.69.5)`, a
  # separate fact from the resolved version in the GEM section). A test asserting
  # the third against the first looks like the natural completion of the pair
  # above. It cannot work, in BOTH directions:
  #
  #   locally  a non-frozen bundler REWRITES Gemfile.lock to agree with the
  #            Gemfile during boot — so by the time any test reads the file the
  #            drift has already been repaired. Measured on 2026-08-30: editing
  #            the DEPENDENCIES entry to `~> 0.63` and running this file left it
  #            reading `~> 0.64` afterwards, and the assertion passed. Every
  #            mutation of that guard is erased by the act of running it.
  #   frozen   `bundle install --deployment` / BUNDLE_FROZEN compares exactly
  #            those two and REFUSES, before Rails boots. The suite never runs,
  #            so the test could not report even if it were right.
  #
  # So bundler already owns this seam at both ends, and owns it better than a
  # test could: it repairs the drift where repair is safe and refuses where it is
  # not. What is left for this file is the pair bundler CANNOT see — the pin
  # against MINIMUM (above) and against the floor note (below), both of which are
  # prose-and-constant agreements no resolver has an opinion about.

  # THE FLOOR NOTE AND THE PIN MUST AGREE — the third statement of the same fact,
  # and the one that actually drifted into this task.
  #
  # The pin carries a hand-written chain of floor notes, each opening
  # `<version> is the real floor, and the pin SAYS so.` and demoting its
  # predecessor to `PRIOR FLOOR NOTE, still true:`. That leading version is a
  # THIRD copy of the floor, in prose — and prose is exactly what goes stale
  # while the constants stay in step. The 0.63 note kept claiming 0.63 was the
  # real floor for the whole window in which this app adopted the engine's
  # Phantom deep link and its wallet accessors, which moved the true floor to
  # 0.64 (see MINIMUM's 0.64 entry). Nothing was red: the pin and MINIMUM agreed
  # with each other and both were wrong together.
  #
  # This asserts the note's leading version against the pin, so a bump that moves
  # the numbers without writing the paragraph that JUSTIFIES them fails here. It
  # cannot check that the paragraph is TRUE — only a human dating the gem trees
  # can — but it can guarantee the paragraph is about the version actually pinned,
  # which is what makes the rest of the comment worth reading.
  test "the Gemfile floor note documents the version the pin declares" do
    gemfile = Rails.root.join("Gemfile").read
    declaration = gemfile[/^\s*gem\s+["']studio-engine["'].*$/]

    assert declaration, "no `gem \"studio-engine\"` line found in the Gemfile at all"

    code, comment = declaration.split("#", 2)

    skip "studio-engine is sourced by override — no version pin to compare" if
      code.match?(SOURCE_OVERRIDE)

    pin = requirement_floor(Gem::Requirement.new(code.scan(/["']([^"']+)["']/).flatten.drop(1)))

    assert pin, "no lower-bounded `gem \"studio-engine\", \"~> x.y\"` requirement found in the Gemfile"
    assert comment, "the studio-engine pin carries no floor note at all — the chain of derivations " \
                    "explaining WHY each floor exists is the point of this pin, not decoration"

    documented = comment[/\A\s*([\d.]+) is the real floor/, 1]

    assert documented,
           "the floor note does not open with `<version> is the real floor, and the pin SAYS so.` " \
           "— that opening is the convention every note in this chain follows, and it is what " \
           "makes the current floor readable without diffing. Note begins: " \
           "#{comment.strip[0, 120].inspect}"

    # ALSO FULL PRECISION NOW, for the same reason the pin guard above is. This
    # compared the first two segments, so a note reading "0.69.0 is the real
    # floor" would have documented a pin whose real floor is 0.69.5 — the note
    # would be off by exactly the five releases this task is about, and green.
    assert_equal pin, Gem::Version.new(documented),
                 "the Gemfile's studio-engine floor is #{pin} but its floor note derives " \
                 "#{documented}. The pin moved and the paragraph explaining WHY did not — write " \
                 "the new note (naming the engine capability that first appears in #{pin} and what " \
                 "breaks below it) and demote the old one to `PRIOR FLOOR NOTE, still true:`."
  end


  # ── THE NOTE'S TAG CITATION, ASSERTED INSTEAD OF TRUSTED ────────────────
  #
  # THE FAILURE THIS EXISTS FOR IS THIS NOTE'S OWN. The floor note dated
  # Studio::FULL_NAME_MAX_LENGTH by naming the gem commit that adds it and the
  # tags containing that commit — and it ENUMERATED them: "contained by exactly
  # two tags, v0.69.5 and v0.70.0". That sentence was TRUE WHEN IT WAS WRITTEN
  # AND FALSE FIVE MINUTES LATER. e68837c3 committed it at 00:24:22; v0.71.0's
  # TAG OBJECT was created at 00:29:14 — 4m52s AFTER. The author had not even
  # left the line: 4f5c3e76 re-edited it at 00:31:55, 2m41s after it had gone
  # false, and shipped it; it was still false at the #581 merge (01:07:18), and
  # v0.72.0 was tagged 01:09:11. All times 2026-09-07 -0600, read off the TAG
  # OBJECT's own creation date rather than its tagged commit's (00:12:26),
  # because `git tag --contains` answers about tags that EXIST. The note whose
  # entire job is to keep a floor from rotting rotted in five minutes, and
  # nothing was red.
  #
  # TRUE-THEN-FALSE IS THE WORSE FAILURE, AND THE WHOLE ARGUMENT FOR COMPUTING
  # THIS. A claim that is false on arrival is an author's mistake, and one
  # careful reader catches it. A claim that is true when written and false
  # before its author stops editing the line cannot be caught by care at all —
  # the world moved, not the sentence. Only re-deriving it on every run catches
  # that, which is what this test does.
  #
  # THE FIX IS THE SHAPE OF THE CLAIM, NOT THE NUMBERS IN IT. A list of
  # containing tags is a clock: every release falsifies it, so it is guaranteed
  # to be wrong and merely a question of when. The EARLIEST containing tag is a
  # fact about the commit — it moves only if a release DELETES the constant,
  # which is the one case the derived guard above already catches. So the note
  # now says "the EARLIEST tag containing … is vX.Y.Z", and this reads that
  # sentence back and checks it.
  #
  # NO VERSION LITERAL APPEARS BELOW, deliberately. The expected value is
  # MINIMUM, so a floor bump moves the note, the pin and this guard together or
  # goes red. A guard pinning "v0.69.5" would be the same class of statement
  # that just rotted — a hand-copied number with nothing keeping it honest.
  #
  # IT RUNS IN TWO HALVES, because only one of them can run everywhere:
  #
  #   ALWAYS — the note is parsed and the version it cites is compared to
  #     MINIMUM. Needs nothing but the Gemfile, so CI runs it.
  #   WHERE THE GEM'S GIT CHECKOUT IS REACHABLE — the earliest containing tag
  #     is COMPUTED from the commit the note names and compared to MINIMUM.
  #     CI installs from Gemfile.lock and has no gem repo, so this half skips
  #     there, narrowly and loudly: the skip fires only when no checkout
  #     carrying the `v<MINIMUM>` tag can be found. A checkout that HAS that
  #     tag and does not know the commit is a wrong SHA and fails.
  TAG_CITATION = /EARLIEST tag containing the commit that adds it \(([0-9a-f]{7,40})[^)]*\) is v(\d+(?:\.\d+)+)/

  test "the floor note's tag citation names the EARLIEST tag containing the commit it names" do
    assert_tag_citation_names_earliest_tag(Rails.root.join("Gemfile").read)
  end

  # A SOURCE OVERRIDE HAS NO FLOOR NOTE, BY CONSTRUCTION — the same exemption the
  # two pin guards above already take, arriving here late and at the cost of every
  # studio-engine PR in between. That lane rewrites this app's declaration with
  # `sed 's|^gem "studio-engine".*|gem "studio-engine", path: "../studio"|'`
  # (.github/workflows/consumer-ci.yml), and the trailing `.*` eats the whole
  # line — the floor note with it. MEASURED 2026-09-07: 21,373 characters before
  # the sed and 0 after, and that CI step's own
  # `grep -q '^gem "studio-engine", path: "../studio"$'` asserts the emptiness on
  # purpose, because replacing the declaration WHOLE is the point of the rewrite.
  #
  # So the control below fired on a lane where a note cannot exist: from the hour
  # this guard landed (2026-09-07, 38ce4822) every engine PR went red on
  # `turf_monster suite vs this engine`, and the engine could neither merge nor
  # publish. The guard was RIGHT — it detected a genuinely stripped comment; it
  # had simply never met the rewrite, which is word for word what happened to the
  # pin guard above on 2026-08-16. A guard that has never met the rewrite is the
  # recurring shape here, not a one-off, which is why the pattern is now named
  # once and this file has a regression that drives both outcomes.
  #
  # THE CONTROL STAYS, AND IS NOW ITSELF GUARDED. Deleting it would have "fixed"
  # the lane by making every assertion under it vacuous — an empty comment
  # contradicts none of them. The regression below drives this method with a note
  # that is well-formed but SHORT, which nothing here can fail on EXCEPT the
  # control, so the control cannot be dropped without going red.
  #
  # IT TAKES THE GEMFILE'S TEXT rather than reading the file, so that regression
  # can hand it the consumer-CI rewrite and an emptied note and watch what this
  # code actually does. A regression asserting its own copy of the rule would go
  # on passing after the rule changed.
  def assert_tag_citation_names_earliest_tag(gemfile)
    code, comment = studio_engine_pin_parts(gemfile)

    skip "studio-engine is sourced by override (#{code.strip}) — the rewrite that produces it " \
         "replaces the declaration WHOLE, floor note and all, so there is no note here to read" if
      code.match?(SOURCE_OVERRIDE)

    # ── CONTROL: the read actually reached the note. A missing Gemfile, a
    # renamed gem, or a declaration that lost its comment all produce an empty
    # string, and an empty string satisfies a "does not contradict MINIMUM"
    # reading of everything below perfectly.
    assert_operator comment.length, :>, 2_000,
                    "the studio-engine floor note read back as #{comment.length} characters — it is " \
                    "a multi-thousand-character chain of derivations, so a number this small means " \
                    "the comment was not read and every assertion below is vacuous"

    citation = comment.match(TAG_CITATION)

    assert citation,
           "the floor note no longer carries a tag citation in the form `the EARLIEST tag " \
           "containing the commit that adds it (<sha>, …) is v<version>`. That phrasing is not " \
           "decoration: it is what makes the claim un-rottable, because a LIST of containing tags " \
           "is falsified by the next release and this note has already been falsified that way " \
           "once. Restore the sentence, or move this guard with it."

    # ── CONTROL: the parser DISCRIMINATES. A regex that matched a constant, or
    # one whose captures were transposed, would agree with MINIMUM by luck. Fed
    # a sentence naming a different commit and a different version, it has to
    # come back with THOSE.
    control = "the EARLIEST tag containing the commit that adds it (abc1234, 1999-01-01) is v9.8.7"
    control_match = TAG_CITATION.match(control)
    assert control_match, "the citation pattern cannot match its own documented form"
    assert_equal [ "abc1234", "9.8.7" ], control_match.captures,
                 "the citation pattern does not read its captures off the sentence it is given, so " \
                 "the real one below proves nothing about the real note"

    sha, cited = citation.captures

    # THE HALF THAT RUNS EVERYWHERE.
    assert_equal MINIMUM, Gem::Version.new(cited),
                 "the floor note cites v#{cited} as the earliest tag containing #{sha}, but this " \
                 "app's floor is #{MINIMUM}. The pin moved and the derivation naming WHY did not — " \
                 "re-derive the earliest containing tag for the commit that adds the capability " \
                 "#{MINIMUM} is the floor for, and write that."

    # THE HALF THAT NEEDS THE GEM'S HISTORY.
    expected_tag = "v#{MINIMUM}"
    repo = studio_engine_git_repo(expected_tag)

    unless repo
      skip "no studio-engine git checkout carrying #{expected_tag} is reachable from here — the " \
           "tag half of this citation cannot be recomputed (CI installs from Gemfile.lock and has " \
           "no gem repo). Set STUDIO_ENGINE_REPO to check it locally."
    end

    assert git_knows_commit?(repo, sha),
           "#{repo} carries #{expected_tag} but has never heard of #{sha} — the floor note names a " \
           "commit that does not exist in studio-engine's history, so its whole derivation is " \
           "unverifiable rather than merely stale"

    # ── CONTROL: the computation VARIES WITH ITS INPUT. A helper that returned
    # the newest tag, the first line of anything, or a cached string would agree
    # with the assertion below for the wrong reason. The highest tag strictly
    # BELOW the floor must date to itself, not to the floor.
    previous_tag = highest_tag_below(repo, MINIMUM)
    assert previous_tag,
           "#{repo} carries no tag below #{MINIMUM}, so the discrimination control below cannot " \
           "run and the computation is unproven"
    assert_equal previous_tag, earliest_tag_containing(repo, "#{previous_tag}^{commit}"),
                 "asked for the earliest tag containing #{previous_tag}'s own commit, the " \
                 "computation did not answer #{previous_tag} — it is not reading the commit it is " \
                 "given, so the verdict below means nothing"
    assert_not_equal expected_tag, earliest_tag_containing(repo, "#{previous_tag}^{commit}"),
                     "the computation returns #{expected_tag} for a commit released BEFORE it, so " \
                     "it would return #{expected_tag} for anything"

    assert_equal expected_tag, earliest_tag_containing(repo, sha),
                 "#{sha} is first contained by #{earliest_tag_containing(repo, sha).inspect}, not " \
                 "by #{expected_tag}. Either the floor note names the wrong commit, or the " \
                 "capability it dates arrived in a different release than the pin claims — and the " \
                 "pin is what a `bundle update` obeys."
  end

  # ── THE GUARD'S TWO OUTCOMES, BOTH ASSERTED ────────────────────────────
  #
  # BOTH, because either alone is a wrong fix. A test that only proved the skip
  # would pass just as happily against a guard that had been deleted outright —
  # it would document the lane being switched off. A test that only proved the
  # failure would leave the consumer-CI lane red, which is the bug. And the two
  # halves fail INDEPENDENTLY: the skip can be inert while the control bites,
  # and the suite is green either way, so neither half stands in for the other.
  #
  # EVERY FIXTURE IS CUT FROM THE REAL GEMFILE, never typed out here. A
  # hand-written declaration is a second copy of the thing under test: it would
  # keep agreeing with itself after the real pin changed shape. The override
  # fixture is produced by re-running consumer-CI's own sed and is then held to
  # the `grep -q` that step runs to confirm its work, so a rewrite that changes
  # moves this fixture with it instead of leaving it testing a lane nobody runs.
  test "the tag-citation guard skips a source-overridden Gemfile and still bites a pinned one" do
    real = Rails.root.join("Gemfile").read
    real_code, real_note = studio_engine_pin_parts(real)
    sha = real_note[TAG_CITATION, 1]

    # THE FIXTURES ARE CUT FROM THIS FILE, so the one lane that has no floor note
    # cannot supply them either. consumer-CI rewrites the declaration before the
    # suite runs, and a regression deriving its fixtures from THAT goes red there
    # for its own reasons — reintroducing, one test over, the exact red lane this
    # change exists to clear. MEASURED: without any skip here, a run under the
    # rewrite came back 1 failure and the failure was this test.
    #
    # GATED ON WHETHER THE FIXTURES EXIST, NOT ON THE RULE UNDER TEST, and the
    # difference is the whole value of the line. This first read `skip … if
    # real_code.match?(SOURCE_OVERRIDE)` — the very predicate the assertions below
    # exist to check — which let the test SWITCH ITSELF OFF: mutating
    # SOURCE_OVERRIDE to /\bgem\b/, so that every declaration reads as an
    # override, skipped all four guards AND this regression, and the suite came
    # back 17 runs, 0 failures, 4 skips. Asking instead whether a citation can be
    # READ from the note cannot be disabled by the thing being tested, and it is
    # the honest precondition anyway: no citation, no fixture to cut. A note that
    # exists but has LOST its citation is not swallowed here — the guard above
    # fails on it directly, which is what that guard is for.
    skip "the working Gemfile's studio-engine declaration (#{real_code.strip}) carries no floor " \
         "note with a tag citation, so there is nothing here to cut fixtures from — consumer-CI " \
         "replaces that declaration whole before the suite runs" unless sha

    # ── HALF ONE: THE CONSUMER-CI LANE. The sed re-run here over the real file
    # exactly as .github/workflows/consumer-ci.yml runs it over the checkout.
    overridden = real.sub(/^gem "studio-engine".*/, 'gem "studio-engine", path: "../studio"')

    assert_match %r{^gem "studio-engine", path: "\.\./studio"$}, overridden,
                 "the rewritten fixture does not satisfy the `grep -q` consumer-CI runs against " \
                 "its own sed, so it is not the line that lane actually produces"
    assert_equal "", studio_engine_pin_parts(overridden).last,
                 "the rewrite left a floor note behind, so this fixture no longer reproduces the " \
                 "condition the skip exists for and half one proves nothing"

    skipped = assert_raises(Minitest::Skip) { assert_tag_citation_names_earliest_tag(overridden) }

    assert_includes skipped.message, 'path: "../studio"',
                    "the guard skipped without naming the override it saw, so it is not reading " \
                    "the declaration it was handed and would skip anything"

    # ── HALF TWO: A REAL VERSION PIN WHOSE NOTE IS EMPTY. Nothing about the
    # source has changed, so the guard must still bite.
    emptied = with_floor_note(real, "")

    assert_equal "", studio_engine_pin_parts(emptied).last
    assert_no_match SOURCE_OVERRIDE, studio_engine_pin_parts(emptied).first,
                     "the emptied fixture reads as a source override, so half two would prove " \
                     "nothing that half one does not already"

    emptied_failure = assert_raises(Minitest::Assertion) do
      assert_tag_citation_names_earliest_tag(emptied)
    end

    assert_not_kind_of Minitest::Skip, emptied_failure,
                       "the guard SKIPPED a version-pinned Gemfile whose floor note is empty — " \
                       "the skip has widened past the source-override lane and is now swallowing " \
                       "the drift this guard exists to catch"

    # ── HALF TWO, SHARPENED ONTO THE CONTROL. This note is WELL-FORMED — right
    # citation, right commit, right version — and merely SHORT, so every
    # assertion in the guard except the >2000 control passes on it. Loosen or
    # delete that control and this fixture stops failing, which is what makes
    # this the one assertion standing between the lane being FIXED and the lane
    # being switched off.
    short = with_floor_note(real, " #{MINIMUM} is the real floor, and the pin SAYS so. The " \
                                  "EARLIEST tag containing the commit that adds it (#{sha}, " \
                                  "2026-09-06) is v#{MINIMUM}.")
    short_note = studio_engine_pin_parts(short).last

    assert_operator short_note.length, :>, 0
    assert_operator short_note.length, :<=, 2_000,
                    "the well-formed fixture grew past the control's own threshold, so it can no " \
                    "longer tell whether the control is there at all"
    assert_match TAG_CITATION, short_note,
                 "the well-formed fixture carries no citation the guard can read, so it would " \
                 "fail on the citation assertion rather than on the control and prove nothing " \
                 "about the control"

    control_failure = assert_raises(Minitest::Assertion) do
      assert_tag_citation_names_earliest_tag(short)
    end

    assert_not_kind_of Minitest::Skip, control_failure,
                       "the guard skipped a short but otherwise valid floor note instead of " \
                       "failing on its length — the >2000 control is gone, and with it every " \
                       "assertion it makes non-vacuous"
  end

  # `gemfile` with the studio-engine declaration's floor note replaced by `note`,
  # leaving the pin itself alone. Fixtures are cut from the real file this way so
  # they carry a real version pin: a hand-typed declaration drifts from the one
  # the guards actually read, and then agrees with itself forever.
  def with_floor_note(gemfile, note)
    gemfile.sub(/^(\s*gem\s+["']studio-engine["'][^#\n]*)#.*$/) { "#{Regexp.last_match(1)}##{note}" }
  end

  # The studio-engine declaration split at its `#` into the CODE half — the gem
  # name and whatever sources or pins it — and the COMMENT, which is where every
  # floor note in the chain lives. Empty string rather than nil for either half,
  # so a caller measuring a length gets a number instead of a NoMethodError.
  #
  # IT TAKES THE GEMFILE'S TEXT rather than reading the file, so the guard above
  # can be driven with a synthetic one and asked what it actually does.
  def studio_engine_pin_parts(gemfile)
    declaration = gemfile[/^\s*gem\s+["']studio-engine["'].*$/].to_s
    code, comment = declaration.split("#", 2)
    [ code.to_s, comment.to_s ]
  end

  # A studio-engine git checkout that carries `tag`. Absent in CI by design, so
  # every caller must handle nil rather than assume a repo.
  #
  # THE TAG IS THE GATE, not the directory's existence: a shallow or
  # tag-less clone answers a containment question with silence, which would read
  # as "no containing tags" and fail for the wrong reason.
  def studio_engine_git_repo(tag)
    candidates = []
    candidates << ENV["STUDIO_ENGINE_REPO"] if ENV["STUDIO_ENGINE_REPO"].present?

    # The consumer-CI lane bundles the engine as a path checkout, which IS a git
    # repo — worth asking, even though it is usually tag-less.
    spec = Gem.loaded_specs["studio-engine"]
    candidates << spec.full_gem_path if spec

    # A sibling checkout: /Users/…/projects/studio-engine from an app root or a
    # worktree desk two or three levels under it. `studio` is the directory name
    # studio-engine's own consumer-CI lane checks the gem out as.
    dir = Rails.root
    4.times do
      dir = dir.parent
      candidates << dir.join("studio-engine").to_s
      candidates << dir.join("studio").to_s
    end

    candidates.uniq.find { |path| git_tag_present?(path, tag) }
  end

  def git_tag_present?(path, tag)
    return false unless File.directory?(path)

    out, _err, status = Open3.capture3("git", "-C", path, "tag", "--list", tag)
    status.success? && out.strip.present?
  end

  def git_knows_commit?(repo, sha)
    _out, _err, status = Open3.capture3("git", "-C", repo, "cat-file", "-e", "#{sha}^{commit}")
    status.success?
  end

  # The lowest-versioned tag whose history contains `rev`, or nil when git
  # cannot answer.
  def earliest_tag_containing(repo, rev)
    out, _err, status = Open3.capture3("git", "-C", repo, "tag", "--contains", rev)
    return nil unless status.success?

    lowest_version_tag(out.split("\n"))
  end

  def highest_tag_below(repo, version)
    out, _err, status = Open3.capture3("git", "-C", repo, "tag", "--list", "v*")
    return nil unless status.success?

    highest_version_tag(out.split("\n").select { |tag| below?(tag, version) })
  end

  def below?(tag, version)
    version_tags([ tag ]).any? { |_name, parsed| parsed < version }
  end

  # THE TWO SELECTIONS, NAMED SO A TEST CAN ASK THEM DIRECTLY. They exist as
  # their own methods rather than as inline `min_by`/`max_by` for one reason:
  # the gem's real tags cannot tell a version ordering from a lexical one (see
  # version_tags), so an ordering asserted only through earliest_tag_containing
  # is asserted by a computation that would agree either way.
  def lowest_version_tag(tags)
    version_tags(tags).min_by(&:last)&.first
  end

  def highest_version_tag(tags)
    version_tags(tags).max_by(&:last)&.first
  end

  # `v`-prefixed tags paired with their parsed version, ORDERABLE. A tag that
  # does not name a version (`latest`, a branch-shaped tag, a blank line) is
  # dropped rather than ordered, because there is no answer to where it sits —
  # and because Gem::Version.new("atest") raises, so ordering it would take this
  # whole file down rather than answer.
  #
  # THE ORDERING IS BY Gem::Version AND NOT BY STRING, and the difference is not
  # cosmetic: `v0.9.0` sorts ABOVE `v0.70.0` lexically, so a lexical "first"
  # names the wrong earliest tag the moment a project passes a two-digit minor —
  # or, later, a three-digit one.
  #
  # IT IS ASSERTED AGAINST A SYNTHETIC LIST rather than against the gem's own
  # tags, and that is the whole point of the test below. Every tag containing
  # the commit the floor note names has a two-digit minor today (v0.69.5,
  # v0.70.0, v0.71.0, v0.72.0), and those order identically under both rules —
  # so deleting the version ordering changes no answer the real-repo test can
  # see. Measured 2026-09-07: that mutation SURVIVED the real-repo assertions,
  # which is why the ordering was extracted to here and pinned directly.
  def version_tags(tags)
    tags.filter_map { |tag|
      name = tag.to_s.strip
      number = name.delete_prefix("v")
      [ name, Gem::Version.new(number) ] if name.start_with?("v") && Gem::Version.correct?(number)
    }
  end

  # ── THE ORDERING, PINNED WHERE THE REAL TAGS CANNOT PIN IT ──────────────
  #
  # WHY THIS IS NOT DRIVEN OFF THE GEM'S TAGS. The test above computes the
  # earliest tag containing the floor note's commit and gets v0.69.5. It gets
  # v0.69.5 under a VERSION ordering and under a plain LEXICAL one alike,
  # because every containing tag today has a two-digit minor and "0.69.5" <
  # "0.70.0" reads the same either way. So deleting the version ordering
  # altogether changes no answer that test can see, and it survives — measured,
  # not assumed. A guard whose recompute agrees with the value it checks for the
  # wrong reason is inert, and that is the exact defect this task family is
  # about.
  #
  # SO THE ORDERING IS ASKED A QUESTION THE TWO RULES ANSWER DIFFERENTLY, off a
  # synthetic list — which also means it runs in CI, where no gem checkout
  # exists and the test above skips.
  test "the tag ordering is by VERSION, where a lexical one would answer differently" do
    tags = [ "v0.70.0", "v0.9.0", "v0.100.0" ]

    # ── CONTROL: the fixture DISCRIMINATES. If lexical and version order agreed
    # on this list, everything below would pass under either rule and prove
    # nothing — which is precisely the trap the gem's real tags fall into. Here
    # the two rules disagree at BOTH ends, so either selection reading strings
    # instead of versions is visible.
    assert_equal "v0.100.0", tags.min, "lexically the LOWEST of these is v0.100.0"
    assert_equal "v0.9.0", tags.max, "and lexically the HIGHEST is v0.9.0 — the fixture disagrees " \
                                     "with version order at both ends, which is what makes it a fixture"

    # ASKED OF THE SELECTIONS THEMSELVES — these are the two methods
    # earliest_tag_containing and highest_tag_below delegate to, so pinning them
    # here pins the ordering at the only place it is decided.
    assert_equal "v0.9.0", lowest_version_tag(tags),
                 "0.9.0 is the lowest VERSION here; a lexical ordering answers v0.100.0, and the " \
                 "floor note would then be dated to a release that does not contain its commit"
    assert_equal "v0.100.0", highest_version_tag(tags),
                 "and 0.100.0 is the highest; a lexical ordering answers v0.9.0"
    assert_not_equal lowest_version_tag(tags), highest_version_tag(tags),
                     "the two selections must not be one method wearing two names"

    # NON-VERSION TAGS ARE DROPPED, not ordered.
    assert_equal [ "v0.9.0" ], version_tags([ "latest", "v0.9.0", "", "main" ]).map(&:first)
    assert_empty version_tags([ "latest", "main", "" ])

    # AND "STARTS WITH v" IS NOT ENOUGH ON ITS OWN, which is why the parse is
    # asked as well. `vnext` clears the prefix rule and `Gem::Version.new("next")`
    # RAISES — so a repo that ever carries such a tag would take this whole file
    # down with an ArgumentError instead of answering. Measured: without this
    # fixture, deleting the Gem::Version.correct? guard survives every other
    # assertion here, because nothing else in the list starts with a `v`.
    assert_empty version_tags([ "vnext", "v-old", "vlatest" ])
    assert_equal [ "v0.9.0" ], version_tags([ "vnext", "v0.9.0" ]).map(&:first)
    assert_nil lowest_version_tag([ "latest", "main" ]), "no version tag means no answer, not a crash"
    assert_nil highest_version_tag([])

    # AND A TAG WITHOUT THE `v` IS NOT ONE OF OURS. Every studio-engine tag
    # carries it; accepting a bare `0.9.0` would silently widen what this reads.
    assert_empty version_tags([ "0.9.0" ])
  end

  # ── requirement_floor, ASKED DIRECTLY ───────────────────────────────────
  #
  # THE DEFECT: an EXACT pin was read as no pin at all. `gem "studio-engine",
  # "0.69.5"` parses as `= 0.69.5`, whose least admitted version is plainly
  # 0.69.5 — and requirement_floor returned nil for it, so the guard above
  # refused with "the studio-engine pin states no LOWER bound". It FAILED
  # CLOSED, which is why it was never urgent: the exact pin went red rather than
  # passing. What it cost was the next reader's afternoon — the message sent
  # them looking for a missing constraint that was present, exact, and the
  # tightest one expressible.
  #
  # ASKED OF THE FUNCTION, NOT THROUGH THE GEMFILE, on purpose. Driving this
  # through the real pin would be inert: this app's pin has a `>=` in it, so the
  # `=` branch would never fire and the test would pass identically with the
  # defect in place. Fixtures are the only way to reach a branch the real input
  # does not exercise.
  #
  # EVERY OPERATOR IS ASSERTED ON ITS OWN. A single mixed requirement would let
  # one branch carry the others: `["~> 1.2", ">= 1.2.3", "= 1.2.3"]` yields
  # 1.2.3 whether or not `=` is read at all. One operator per assertion is what
  # makes each branch's absence visible.
  #
  # THE FIXTURE VERSIONS ARE UNRELATED TO THIS APP'S FLOOR, so nothing here can
  # pass by coincidentally matching MINIMUM.
  test "requirement_floor reads a floor from every operator that states one" do
    assert_equal Gem::Version.new("1.2"), requirement_floor(Gem::Requirement.new("~> 1.2"))
    assert_equal Gem::Version.new("1.2.3"), requirement_floor(Gem::Requirement.new(">= 1.2.3"))
    assert_equal Gem::Version.new("1.2.3"), requirement_floor(Gem::Requirement.new("= 1.2.3"))

    # THE SHAPE THE DEFECT WAS ABOUT. A bare version string in a Gemfile is what
    # anyone writing an exact pin actually types, and Gem::Requirement parses it
    # as `=` — so this and the assertion above are the same branch reached the
    # two ways a Gemfile can reach it.
    assert_equal Gem::Version.new("1.2.3"), requirement_floor(Gem::Requirement.new("1.2.3")),
                 "a bare `gem \"studio-engine\", \"1.2.3\"` is an EXACT pin — the tightest floor " \
                 "expressible — and reading it as no floor at all makes the guard above refuse a " \
                 "correct pin while blaming a missing constraint"

    # THE TIGHTEST LOWER BOUND WINS, which is the shape this app's own pin has.
    assert_equal Gem::Version.new("1.2.3"),
                 requirement_floor(Gem::Requirement.new([ "~> 1.2", ">= 1.2.3" ]))

    # AND CEILINGS ARE IGNORED rather than mistaken for floors.
    assert_equal Gem::Version.new("1.2.3"),
                 requirement_floor(Gem::Requirement.new([ ">= 1.2.3", "< 2.0" ]))
  end

  # THE OTHER HALF OF THE SAME FUNCTION, and it has to be asserted separately or
  # the operator list could simply be "everything" and still pass above.
  test "requirement_floor reports no floor for requirements that state none" do
    [ "< 2.0", "<= 2.0", "!= 1.2.3" ].each do |ceiling|
      assert_nil requirement_floor(Gem::Requirement.new(ceiling)),
                 "#{ceiling} bounds from above and says nothing about the floor"

      # And the guard's refusal SENTENCE has to be true of them: it tells the
      # reader a ceiling "permits every version below it". Asserted, because a
      # message describing the wrong cause is exactly the defect this pair fixes.
      assert Gem::Requirement.new(ceiling).satisfied_by?(Gem::Version.new("0.0.1")),
             "#{ceiling} is supposed to admit versions far below its operand — if it does not, " \
             "the refusal message above describes the wrong failure"
    end

    # `>` IS EXCLUDED DELIBERATELY AND IS NOT A CEILING. `> 1.2.3` admits
    # everything above 1.2.3 and not 1.2.3 itself, so it has no least element to
    # compare and treating its operand as the floor would be off by an
    # unknowable amount. It returns nil for a DIFFERENT reason than the three
    # above, which is why it is asserted apart from them and why the refusal
    # message names it.
    assert_nil requirement_floor(Gem::Requirement.new("> 1.2.3"))
    assert_not Gem::Requirement.new("> 1.2.3").satisfied_by?(Gem::Version.new("0.0.1")),
               "`>` does bound from below — it just has no least element — so it must not be " \
               "described to the reader as a ceiling"
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

    # Comments EXPLAIN the tiers — application.css documents this very deletion
    # using the names the guard bans — so scanning them would make documenting the
    # fix impossible.
    #
    # BUT THE STRIPPER IS THE FAIL-OPEN RISK IN ANY SUCH GUARD, and this one
    # guards a defect that is already invisible. A bare `/\*.*?\*/m` span-strip
    # pairs a stray `/*` — inside a string, a url(), or a nested-looking opener —
    # with a genuine `*/` far below it and eats everything between: the scan still
    # runs, still passes, and is reading nothing. That exact failure cost this repo
    # real coverage once, swallowing 93% of a file (see `without_block_comments` in
    # test/views/layer_scale_adoption_test.rb, which is where this shape is from).
    #
    # So span-strip ONLY when the file's openers and closers BALANCE. Otherwise
    # drop whole-line comments, where a stray opener costs one line instead of the
    # rest of the file. Both directions are asserted below, on fixtures.
    def without_css_comments(text)
      if text.scan(%r{/\*}).size == text.scan(%r{\*/}).size
        text.gsub(%r{/\*.*?\*/}m, " ")
      else
        text.each_line.reject { |line| line.match?(%r{\A\s*(?:/\*|\*)}) }.join
      end
    end

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
