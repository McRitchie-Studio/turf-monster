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
  MINIMUM = Gem::Version.new("0.64.0")

  test "the resolved studio-engine is at or above the floor this app depends on" do
    resolved = Gem::Version.new(Studio::VERSION)
    assert_operator resolved, :>=, MINIMUM,
                    "studio-engine #{resolved} is below the #{MINIMUM} floor this app depends on " \
                    "(the email-free local-review CTA needs >= 0.36; Studio::EmailSetting needs >= 0.42; " \
                    "a host-owned layered banner needs >= 0.43; the adopted first-name onboarding " \
                    "endpoints need >= 0.46; the shared /profile page and its section registry need " \
                    ">= 0.52; the shared date-of-birth field rendered by modals/_birthday needs " \
                    ">= 0.54; the rail-row and close-x chrome primitives this app RENDERS need >= 0.61, and an UNESCAPED rail-row click handler needs >= 0.62.2; and the shared layer scale this app no longer mirrors locally needs >= 0.63; and the wallet surface needs >= 0.64 — config.wallet_debug_sink is SET in this app's initializer, so below it Studio.configure raises at boot)"
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
  SOLANA_STUDIO_MINIMUM = Gem::Version.new("0.5.3")

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

  # WHY THE LOCKFILE IS NOT GUARDED HERE, written down because the obvious guard
  # is INERT and was very nearly shipped.
  #
  # The floor is stated in three files, not two: the Gemfile pin, MINIMUM above,
  # and Gemfile.lock's DEPENDENCIES entry (`studio-engine (~> 0.64)`, which is a
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
      code.match?(/\b(?:path|git|github|branch):/)

    pin = code[/["']~>\s*([\d.]+)["']/, 1]

    assert pin, "no `gem \"studio-engine\", \"~> x.y\"` line found in the Gemfile"
    assert comment, "the studio-engine pin carries no floor note at all — the chain of derivations " \
                    "explaining WHY each floor exists is the point of this pin, not decoration"

    documented = comment[/\A\s*([\d.]+) is the real floor/, 1]

    assert documented,
           "the floor note does not open with `<version> is the real floor, and the pin SAYS so.` " \
           "— that opening is the convention every note in this chain follows, and it is what " \
           "makes the current floor readable without diffing. Note begins: " \
           "#{comment.strip[0, 120].inspect}"
    assert_equal Gem::Version.new(pin).segments.first(2),
                 Gem::Version.new(documented).segments.first(2),
                 "the Gemfile pins ~> #{pin} but its floor note derives #{documented}. The pin moved " \
                 "and the paragraph explaining WHY did not — write the new note (naming the engine " \
                 "capability that first appears in #{pin} and what breaks below it) and demote the " \
                 "old one to `PRIOR FLOOR NOTE, still true:`."
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
