source "https://rubygems.org"

ruby "3.3.11"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.0"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
# Redis adapter for Action Cable — powers contest chat real-time delivery.
gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Google OAuth
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
# Declared DIRECTLY rather than left to image_processing to supply it. Active
# Storage hardens libvips against untrusted content by calling
# Vips.block_untrusted(true), but only when `require "ruby-vips"` succeeds
# (activestorage/lib/active_storage/vips.rb). If the gem ever leaves the bundle
# that require fails, VIPS_AVAILABLE flips to false, and the hardening silently
# never runs — the app still boots and still handles images through mini_magick,
# so nothing reports the loss. image_processing 1.14 happens to pull ruby-vips
# in; 2.0 declares no such dependency, so bumping it alone would delete the gem.
# 2.2.1 is the floor that has block_untrusted.
#
# `require: false` is LOAD-BEARING, not tidiness. ruby-vips binds the libvips C
# library at REQUIRE time, so letting Bundler.require it would abort boot with
# LoadError on any machine that lacks libvips — every developer Mac. Active
# Storage does its own require inside a rescue, which is the only require this
# gem needs. Guarded by test/lib/vips_dependency_test.rb.
gem "ruby-vips", ">= 2.2.1", "< 3", require: false
gem "aws-sdk-s3", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Pretty-print Stripe payloads + on-chain responses in tagged dev logs.
  gem "amazing_print"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Pin minitest to the 5.x line. minitest 6.0 extracted `minitest/mock`
  # (Minitest::Mock + Object#stub) into a separate gem; the suite relies on
  # `.stub` extensively. Rails 8.1 only requires minitest >= 5.15, so we stay
  # on the well-understood 5.x series and keep this upgrade scoped to Rails.
  gem "minitest", "~> 5.25"

  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # I1 (Stage 3 audit): code coverage. Opt-in via COVERAGE=1 — see test_helper.rb.
  gem "simplecov", require: false
end
gem "dotenv-rails", groups: [:development, :test]
gem "tailwindcss-rails", "~> 4.5"
# Sidekiq + scheduled jobs (Reconciler cron, ATA ensure jobs, deposit jobs)
gem "sidekiq-cron", "~> 1.12"

# Sentry — production error monitoring. ErrorLog.capture! fans out to Sentry
# when SENTRY_DSN env var is set. No-op if absent.
gem "sentry-ruby"
gem "sentry-rails"

# Shared Rails engine: auth, theme, error logs, SSO, and the unified
# Studio::Link store (short tokens for magic links + referral invites).
# 0.11.0 widens the Rails bound to allow 8.1; it also ships the opt-in
# Studio::Enumeral table (0.9.0) and the Studio::Redis / Studio::Cable
# websocket primitives (0.10.0), neither of which turf adopts yet.
gem "studio-engine", "~> 0.73" # 0.73.0 is the real floor, and the pin SAYS so — and it is the SHARPEST kind of floor in this whole chain, because below it NOTHING RAISES. solana_sessions/phantom_callback is the page a wallet returns to, and 0.73.0 is where it first dispatches a pending wallet_dl journal to SolanaStudio.walletOps.resume BEFORE its legacy phantom_dl_* signIn path. This app now sends contest entries out over that redirect transport, so the return leg is not optional: below 0.73.0 the callback does not recognise the journal, silently falls through to the legacy branch, and hands a returning ENTRY to a sign-in flow that has no idea what a contest entry is. The user watches a wallet approve a transaction, comes back, and lands nowhere — no error, no console message, no failing test. DERIVED TWO WAYS, neither of them a changelog. (a) Unpacking every published gem across the boundary: 0.72.0, 0.72.1, 0.72.2 and 0.72.3 all contain ZERO occurrences of the dispatch guard, and 0.73.0 contains it. (b) In the gem repo, the EARLIEST tag containing the commit that adds it (85a2f81, 2026-09-07, "Resume a wallet round trip through walletOps") is v0.73.0. Stated as the EARLIEST containing version for the reason the floors below record at length — a LIST of versions goes stale on the next release, while "earliest" is a fact about the code. NOTE 0.74.0 IS NOT THE FLOOR even though it is what the lock now resolves; an earlier draft of this note asserted it, and the derivation above is what caught it. PRIOR FLOOR NOTE, still true: ~> 0.72 # 0.72.0 is the real floor, and the pin SAYS so. This app DELETED its own first-name onboarding card (app/views/modals/_onboarding.html.erb, 266 lines) and now RENDERS the engine's studio/modals/onboarding/first_name instead, from BOTH host registration lists (layouts/application and layouts/modal_preview). THE PARTIAL ITSELF IS NOT WHAT SETS THIS FLOOR — it exists as far back as 0.66.2 — so the loud failure mode of the 0.54 and 0.57 floors below is exactly what this floor does NOT have. Two LOCALS this app passes do set it, and both fail SILENTLY, which is the only reason this note is worth its length. DERIVED FROM THE GEM REPO, not from a changelog (the gem files everything after 0.39 under Unreleased, so it can date nothing): reading app/views/studio/modals/onboarding/_first_name.html.erb at each tag, v0.70.0 and v0.71.0 carry NEITHER capability and v0.72.0 carries both; the installed trees agree (0.70.0 has required only, 0.72.0 has all three), and `required` itself first appears in 0.70.0. ONE COMMIT ADDS BOTH — `Report the first-name outcome and allow a typed placeholder` — and the EARLIEST tag containing the commit that adds it (195300e, 2026-09-06) is v0.72.0, which is the un-rottable form of this claim: a LIST of containing tags is falsified by the next release, while the earliest containing tag is a fact about the commit. (1) placeholder_names — the OPT-IN typed placeholder, passed by onboarding_helper#first_name_modal_locals. Below 0.72.0 the local is simply not read, so the field falls back to a STATIC placeholder: the animated hint disappears and nothing raises, logs or fails a test. (2) THE SHARPEST, and the reason this floor exists at all: the done event's detail.saved key. layouts/application's onboarding-step-done listener BRANCHES on it to decide whether to clear $store.session.firstNameRequired and re-dispatch first-name-saved, which is how contests/_turf_totals_board resumes a contest entry its first-name gate interrupted. Below 0.72.0 detail.saved is undefined on EVERY path, so that branch never fires, the store flag is never cleared, and a held entry never resumes — a dead hold-to-confirm with no error anywhere in the browser. The opposite mistake is guarded too: firing the resume after a SKIP would wave an entry past the very validation that stopped it, which is why the branch is pinned by e2e rather than trusted. WHY ONE REQUIREMENT AGAIN. The previous floor was a PATCH (0.69.5), which a two-segment `~>` CANNOT state, so the pin carried a second `>= 0.69.5`. This floor is a clean MINOR, so `~> 0.72` states it exactly (`>= 0.72, < 1.0`) and the second requirement is RETIRED rather than left behind as a weaker duplicate of the first. INVISIBLE TO THE RESOLVER, like every floor in this chain: the old `~> 0.69` already admitted 0.72.0 and Gemfile.lock already resolved it, so no install changes today — it is the FLOOR that moved, which is exactly what this comment exists to record. PRIOR FLOOR NOTE, still true: 0.69.5 is the real floor, and the pin SAYS so — and it is the FIRST floor in this chain a two-segment `~>` CANNOT STATE, which is why this line now carries two requirements instead of one. Studio::FULL_NAME_MAX_LENGTH first EXISTS in 0.69.5. DERIVED TWO WAYS, not read off a changelog (the gem files everything after 0.39 under "Unreleased", so it can date nothing), and BOTH ARE STATED AS A MINIMUM RATHER THAN AS A LIST — see WHY THE DERIVATIONS SAY "EARLIEST" below, which is the correction this note is carrying: (a) grepping every installed studio-engine tree, across BOTH Ruby gem homes, for the ASSIGNMENT `FULL_NAME_MAX_LENGTH =` under lib/ and app/ finds the LOWEST version defining it to be 0.69.5, and NO version below it defines it (a COUNT of those versions is not written down, for the same reason a list of tags is not — it is a property of whatever happens to be unpacked on one laptop, and it moved from 116 to a different number the same day); (b) in the gem repo the EARLIEST tag containing the commit that adds it (f2c2d1c, 2026-09-06, "Bound the onboarding answer with its own cap, and refuse past it") is v0.69.5 — and that commit's own version.rb still reads 0.69.4, so 0.69.4 is the last release WITHOUT it. WHY THE DERIVATIONS SAY "EARLIEST" AND "LOWEST", WHICH THIS SENTENCE LEARNED THE HARD WAY. Both halves used to ENUMERATE — "finds it in exactly 0.69.5 and 0.70.0", "contained by exactly two tags, v0.69.5 and v0.70.0" — and the tag half was TRUE WHEN IT WAS COMMITTED AND FALSE FIVE MINUTES LATER, which is a sharper illustration than being wrong on arrival: e68837c3 wrote it at 00:24:22 and v0.71.0's TAG OBJECT was created at 00:29:14 — 4m52s after. The line had not even stopped being edited: 4f5c3e76 rewrote it at 00:31:55, 2m41s after it had gone false, and shipped it anyway; it was still false when PR #581 merged at 01:07:18, and v0.72.0 was tagged 01:09:11. AN ENUMERATION CAN GO FALSE BEFORE ITS AUTHOR FINISHES EDITING THE LINE IT SITS ON — nobody was slow here; the claim is simply perishable, and no amount of care at writing time makes it less so. THE CLOCK IS THE TAG OBJECT'S OWN DATE, not the TAGGED COMMIT'S, because `git tag --contains` answers about tags that EXIST: read it with `git for-each-ref --format='%(taggerdate:iso-strict)' refs/tags/v0.71.0` (00:29:14), NOT with `git log -1 --format=%cI v0.71.0^{}` (00:12:26, the release commit). Reading that second number as if it were the first is what made the first telling of this story INVERT the order, and it is an easy mistake precisely because both are "the date of v0.71.0". All times 2026-09-07 -0600. v0.72.0 followed within the hour, and the corpus half rotted behind it the moment 0.72.0 was installed here. Measured 2026-09-07: f2c2d1c is contained by FOUR tags (v0.69.5, v0.70.0, v0.71.0, v0.72.0) and the installed corpus defines the constant in THREE versions (0.69.5, 0.70.0, 0.72.0 — 0.71.0 is not installed here at all, which is the second reason an enumeration off THIS corpus was never the fact it looked like). An enumeration of containing tags is a CLOCK, not a fact: every release falsifies it, so the note whose whole job is to stop a floor from rotting rotted in under an hour. The EARLIEST cannot move that way. Only a release that DELETES the constant could move it, and that is precisely what test/lib/engine_pin_contract_test.rb's derived guard catches — while the tag citation itself is now asserted rather than trusted, by "the floor note's tag citation names the EARLIEST tag containing the commit it names" in the same file. A COUNT IS THE SAME TRAP, which is why no corpus size appears above: the figure was 128 trees / 118 distinct versions when first derived and 129 / 119 a few hours later, on the same laptop, without anyone touching this app. WHAT MADE IT A FLOOR: turf-modal-caps-forty (PR 573) made the constant a RENDER-TIME dependency on EVERY page. layouts/application renders modals/_onboarding unconditionally and the <template x-if> wrapper is CLIENT-side, so the ERB evaluates on every request and reads Studio::FULL_NAME_MAX_LENGTH for the field's maxlength. Below 0.69.5 that is a NameError on every page render — a TOTAL outage, not a degraded field, which puts it in the same class as the 0.64.0 boot failure below. WHY A SECOND REQUIREMENT. Every bump before this one moved a MINOR, so a two-segment `~>` could carry the floor and only the note moved. This floor is a PATCH: `~> 0.69` means `>= 0.69, < 1.0` and therefore ADMITS 0.69.0 through 0.69.4 — precisely the window that raises. `"~> 0.69", ">= 0.69.5"` keeps the same ceiling and states the floor at the precision the floor actually has. So unlike every bump below, this one IS visible to the resolver. NOT REACHABLE TODAY: Gemfile.lock resolves an engine ABOVE this floor and both CI and deploy install from the lock. Stated as a RELATION and not as a number, for the reason above — the version this named went stale within the day — and asserted rather than trusted: engine_pin_contract_test's first test compares the RESOLVED version against the floor on every run, so "above the floor" is a fact the suite re-derives instead of a sentence somebody has to remember to edit. The exposure is a future `bundle update`, or a lock rebuilt from this file alone. THE NUMBER IS THE SMALLER HALF OF THE FIX. A hand-bumped floor rots the same way this one did: the next consumer reference to a newer engine constant reopens the hole in silence. test/lib/engine_pin_contract_test.rb now DERIVES the same question from the source — every `Studio::` constant this app names must be DEFINED by the RESOLVED engine — so a backwards resolve is caught by what the app actually references rather than by whether anyone remembered to move this number. That guard needs no historical gem trees, which is what makes it runnable in CI. PRIOR FLOOR NOTE, still true: 0.64.0 is the real floor, and the pin SAYS so. THREE adoptions landed here after the 0.63 note was written, and together they moved the floor a whole minor. (1) THE APP NO LONGER BOOTS BELOW IT, which is the sharpest failure in this entire chain: config/initializers/studio.rb sets `config.wallet_debug_sink` (the gate on the phantom-callback debug sink), and `Studio.wallet_sign_in_statement` — backed by the `wallet_sign_in_statement_builder` accessor — is the single source of the literal users sign. BOTH mattr_accessors first exist in 0.64.0's lib/studio.rb; on 0.63.0 the `Studio.configure` block raises NoMethodError at boot, so this is not merely a test contract. (2) adopt-engine-phantom-deeplink DELETED both halves of the mobile round trip from this app — app/javascript/phantom_deeplink.js and app/views/solana_sessions/phantom_callback.html.erb — and the engine SHIPPED them as studio/solana/_phantom_deeplink (rendered from shared/_alpine_factories) and solana_sessions/phantom_callback, BOTH first appearing in 0.64.0 — which is the event that set this floor and the reason this clause stays. WHERE THEY LIVE NOW: /tasks/turf-rides-gem-modals moved the deep link to solana-studio (solana_studio/_phantom_deeplink, which is what shared/_alpine_factories renders today) and /tasks/drop-engine-web3-modals dropped the engine's copy in 0.66.2; solana_sessions/phantom_callback never moved, is still the engine's, and is still what holds this floor. Below it the render resolves nothing and the mobile return leg has no template at all. (Note for the next reader: studio/solana/_deeplink_assets ARRIVED in the same release and was deliberately NOT rendered here, because this app keeps its own BLOCKING tweetnacl tag; see layouts/application. It was never part of this floor. The engine's copy is gone since 0.66.2 and solana-studio ships the only one now, still unrendered.) (3) adopt-turf-engine-picker made this app depend on the shared picker's canDeepLink getter (`typeof startPhantomDeepLink === 'function'`), which in 0.64.0 gates BOTH Phantom's mobile install-row suppression (`self.isMobile && self.canDeepLink && i.name === 'Phantom'`) and the deep-link row (showPhantomDeepLink). 0.63.0's getter reads `if (self.isMobile && i.name === 'Phantom')` and defines no canDeepLink at all, so test/controllers/wallet_picker_single_phantom_test.rb's /self.canDeepLink/ assertion has nothing to match. Unlike (1) and (2) this third one fails LOUDLY IN TESTS rather than at boot, and — measured in a browser, because the reasoning in circulation was backwards — losing it leaves a phone with Phantom's dead-end INSTALL row, not with no Phantom path at all. DERIVED, not assumed: every partial this app renders, every Studio accessor it configures and every engine symbol it names was dated by grepping the installed 0.4.13-0.65.2 gem trees for its FIRST appearance, and 0.64.0 is the MAXIMUM of that set. Nothing above it is a floor, and that is measured rather than hoped: 0.64.0 to 0.65.2 adds no new view, no new CSS custom property and no new Studio accessor whatsoever (the same comparison run across 0.63.0 to 0.64.0 as a control surfaces exactly the three files and two accessors named above, so the scan is reading). A two-segment ~> allows anything under 1.0, so the OLD "~> 0.63" already admitted 0.65.2 and this bump is invisible to the resolver — it is the FLOOR that moved, which is exactly what this comment exists to record. PRIOR FLOOR NOTE, still true: 0.63.0 is the real floor, and the pin SAYS so. 0.63.0 is where studio-engine first DEFINES the shared layer scale (the --z-* tiers in engine.css's :root), ships the body.modal-open lift for both the bar stack and the app banner, and defaults its toast seams to the toast tiers in layouts/studio/_flash. This app used to MIRROR all three in an application.css ADOPTION SHIM; delete-turf-layer-shim removed that mirror, because it was emitted AFTER the engine import and therefore OUTRANKED the gem it was copying. With the mirror gone there is no local copy to fall back on, so below 0.63.0 every var(--z-*) in this app resolves to nothing and the modal backdrop, navbar, drawer, docked slip and toasts all fall to z-index:auto — a SILENT and TOTAL loss of stacking order rather than a degraded one, which is the sharpest kind of floor to have. DERIVED, not assumed: 0.62.5's engine.css defines no tier, no lift and no toast fallback, and 0.63.0 defines all three. A two-segment ~> allows anything under 1.0, so the OLD "~> 0.62" already admitted 0.65.0 and this bump is invisible to the resolver — it is the FLOOR that moved, which is exactly what this comment exists to record. PRIOR FLOOR NOTE, still true: 0.62.2 is the real floor, and the pin SAYS so. 0.61.0 is where blocks/_close_x and blocks/_rail_row first EXIST, and 0.62.2 is where _rail_row stopped ESCAPING its own Alpine click handler: it built the element with content_tag, which HTML-escapes every attribute value, so on_click came out as tmCoinflowBuyOne(&#39;single&#39;) instead of tmCoinflowBuyOne('single'). That works in a browser — the HTML parser unescapes the attribute before Alpine ever calls getAttribute — which is exactly why it survived review, but it breaks everything that reads the MARKUP, and this app has live assertions on the raw handler string in onramp_hub_test, wallet_topup_test and web2_entry_token_funding_test. adopt-funding-chrome-primitives deleted 18 hand-rolled copies here and now RENDERS both primitives (10 rail rows across _onramp_hub, _buy_entry_token and _wallet_topup; 8 close-x), so below 0.61 those render calls resolve nothing and below 0.62.2 the handler comes back escaped. A two-segment ~> allows anything under 1.0, so the OLD "~> 0.57" already admitted 0.62.3 and this bump is invisible to the resolver — it is the FLOOR that moved, which is exactly what this comment exists to record. PRIOR FLOOR NOTE, still true: 0.57 is the real floor, and the pin SAYS so. 0.57 ships the geo primitive this app now RENDERS instead of carrying: Studio::GeoDetection (detection, the geo_* helpers, require_geo_allowed), Studio::GeoSetting + the studio_geo_settings table, the /admin/geo manager and the public /geo/check probe (config.draw_geo_routes), components/_geo_badge, and the 52 US state flags as gem assets. The local model, helper, controller, view, badge partial, geocoder initializer, routes and public/state-flags were all DELETED in adopt-engine-geo-primitives, so on 0.56 this app has no geo at all — not a degraded gate, a boot error at `include Studio::GeoDetection`. A two-segment ~> allows anything under 1.0, so the OLD "~> 0.56" already admitted 0.57 and this bump is invisible to the resolver — it is the FLOOR that moved, which is exactly what this comment exists to record. PRIOR FLOOR NOTE, still true: 0.56 is the real floor, and the pin SAYS so. 0.56 ships the hold-to-confirm button as an engine primitive (studio/_hold_button + studio/_fizz_layer + Studio::FizzHelper + the ACTION family in engine-motion.css), which this app now RENDERS instead of carrying its own copy — the local partial, helper and @utility blocks were deleted in adopt-engine-hold-button, so on 0.55 the contest board has no hold button at all rather than a degraded one. A two-segment ~> allows anything under 1.0, so the OLD "~> 0.54" already admitted 0.56 and this bump is invisible to the resolver — it is the FLOOR that moved, which is exactly what this comment exists to record. # 0.54 is the real floor, and the pin SAYS so. 0.54 ships studio/fields/_date_of_birth, the engine's one date-of-birth field, and app/views/modals/_age_verify RENDERS it — below 0.54 that render call resolves nothing and the age gate loses its inputs, so this is a hard floor rather than a preference. It also converts /profile/edit's birthday row from the retired calendar popover to the same three selects, which is why the pin moved rather than the app forking a third copy. PRIOR FLOOR NOTE, still true: 0.52 was the real floor before it. 0.52 is what this app now needs rather than merely tolerates: the shared /profile page (Studio.draw_profile_routes, on by default), Studio::ProfileSections (this app declares its own to hold the newsletter row back — see config/initializers/studio.rb for why), and Studio::Newsletter. A two-segment ~> allows anything under 1.0, so the OLD "~> 0.43" already admitted 0.52 and the bump would have been invisible in the pin — which is exactly the misreading this comment exists to prevent. PRIOR FLOOR NOTE, still true: 0.43 is the real floor, and the pin now SAYS so. 0.43 is what makes a HOST-OWNED layered banner possible at all: this app registers its own background for magic_link, and 0.42 gated background_url on whether the ENGINE owned the flat artwork, so no configuration here could opt in. The previous pin read "~> 0.31" while the lockfile resolved 0.39 — a two-segment ~> allows anything under 1.0, so the pin string was documenting history rather than the floor, and it got misread as "this app runs 0.31". The features below still set their own floors: 0.36 gives Studio::LocalReviewsController a reviewer of its own (Studio.local_review_email, else the seeded admin), which is what makes the task board's EMAIL-FREE waiting-approval CTA mint a link instead of bouncing to /signin — note it needs an admin IN THE STACK DB, so a freshly created desk must be seeded; and 0.42 adds Studio::EmailSetting behind the operator-editable layered email banner on /admin/emails, a page this app mounts FROM the engine, so the three studio_email_settings migrations are required rather than optional. test/lib/engine_pin_contract_test.rb asserts the resolved version, the engine tables, and those columns, so a bundle update that walks backwards fails there instead of at runtime. HISTORY (pre-0.42 adoption notes, kept because each is still a live constraint):0.31 is the real floor: this app now uses Studio::LinkConsumption, Studio::LinkResolution and Studio::Link#burn/#dead_status, all of which arrived in 0.31 — the declared floor understated it. 0.30.0 makes the dev/QA environment banner a shared standard, built by lifting THIS app's behavior into the engine: the QA message composition, the DEVNET chip, and the link-vs-inert-chip email button (now keyed on whether /_studio/local_emails actually RESOLVES, the stricter test). _navbar renders studio/banners/environment with preview:/devnet: and nothing else — the partial self-gates, so 0.30 is the FLOOR, and the host forks shared/_dev_mode_button + shared/_email_status_button are deleted (shared/_app_banner stays: _impersonation_banner still uses it); 0.27 renames the /admin/style modal sections — "Web3" → "Web3 Contest" and "Eligibility & entry" → "Contest entry & eligibility" (relocated directly under Web3 Contest) — and adds their walked flows (Connect Wallet → Processing on-chain tx → On-chain success; Entry tokens → Payment processing → Entry Tokens Minted → Contest enter processing → Contest entered) plus the shared minimum-visible-duration load convention (studio/modals/_load_convention); the On-chain specimen labels drop the "tx · " prefix; 0.26 self-pins the navbar under the smooth-load convention (engine-navbar-self-pins, 0.26.0) and fixes the /admin/style Turbo-nav modal store (0.26.1); 0.25 rebuilds the Profile Leveling primitive (the change-username / quest modal flow now renders via _leveling_activity, and the removed -plain modal ids — change-username-plain, quest-activity-plain — are gone) plus an /admin/style glow fix; 0.24 ships the smooth-load convention TM opts into (Studio.smooth_load + Studio.nav_spinner_min_ms accessors, the view-transition/no-preview metas via layouts/studio/head, and the vt-pinned-header CSS layer) — the initializer sets both accessors, so 0.21-0.23 raise NoMethodError at boot; 0.20 homes the shared modal-block superset TM now renders instead of forking: the entry-confirmed celebration + seeds bar + digit reel + free-entry-earned blocks and the wallet brand sprite, all gated behind config.features %i[web3 leveling] (TM enables both); 0.19 ships the dev-only /_studio/local_review mint endpoint (the local half of the board WAITING APPROVAL button — turf stacks host most local demos); 0.18 ships the /admin/style Design System page + engine-motion.css (opt-in motion/effect layer, generated via lib/tasks/tailwindcss_engine_motion.rake); 0.15 made btn-secondary/btn-neutral token-driven (--btn-* custom props) so TM expresses its violet secondary via :root tokens instead of forking

# Solana primitives (Client, Keypair, Borsh, Transaction, AuthVerifier) AND,
# since 0.5.3, the web3 view surface this app RENDERS rather than carries.
#
# 0.5.3 is the real floor, and the pin SAYS so — a three-segment ~> is used
# deliberately here. THIS FLOOR IS NOT INVISIBLE TO THE RESOLVER, unlike every
# studio-engine bump below: the old "~> 0.5" already ADMITTED 0.5.3, but
# Gemfile.lock resolved 0.5.1, and a floor that only the Gemfile believes in is
# not a floor at all. Measured in this app on 2026-09-01, before the lock moved:
# with "~> 0.5" satisfied by 0.5.1, all four partials below resolved MISSING
# through a real ActionView LookupContext while the engine's copies still
# resolved FOUND — so every render site would have come up EMPTY with no error
# raised anywhere. That silent-empty-modal failure is the whole reason the pin
# is three segments and the lock is part of this change.
#
# WHAT 0.5.3 FIRST SHIPS (derived by unpacking the published .gem, not read off
# a changelog): solana_studio/modals/_wallet_connect, solana_studio/modals/
# _web3_step_up, solana_studio/_phantom_deeplink and solana_studio/
# _deeplink_assets. 0.5.2 ships THREE files under app/ (network_guard.js,
# auth/_wallet_credential, modals/_network_mismatch) and 0.5.0-0.5.1 ship two;
# 0.5.3 ships seven. This app renders the first three of the four (see below for
# why _deeplink_assets is deliberately NOT rendered), so below 0.5.3 the
# Connect-Wallet picker, the web3 step-up card and the whole mobile Phantom
# sign-in leg all resolve to nothing.
#
# solana-studio is a Rails::Engine, so its app/views joins the lookup path
# automatically — there is nothing to wire up, which is also why the failure is
# silent rather than loud.
#
# THE _deeplink_assets EXCEPTION, unchanged by this move: it APPENDS its
# tweetnacl tag asynchronously, and this app's callback reads window.nacl at
# PARSE time with no retry. This app therefore keeps its own BLOCKING SRI-pinned
# tag and does not render the gem loader. phantom_deeplink_adoption_test bans
# BOTH the old engine path and the gem path for it — the engine's copy went away
# in 0.66.2, so that half is now a re-add guard rather than a live alternative. Adopt it only together with a
# callback that waits.
#
# THIS DOES NOT LOWER THE studio-engine FLOOR, and the reasoning is easy to get
# backwards: the gem's _phantom_deeplink reads `Studio.wallet_sign_in_statement`
# — a studio-engine accessor — exactly once and unparameterized, and studio-
# engine's solana_sessions/phantom_callback rebuilds the signed message from
# that same helper. They are a MATCHED SIGNING PAIR, so the gem partial depends
# on studio-engine >= 0.64 at RENDER time. See the studio-engine pin above.
#
# 0.4.7 adds Solana::Transaction.cosign_wire + Client#simulate_transaction for the
# Phantom-first signing-order flow (published to RubyGems).
#
# THE ORDER OF THIS LINE AND THE studio-engine LINE ABOVE IS LOAD-BEARING.
# Rails engines PREPEND their app/views in railtie load order, which follows
# Bundler.require — so the engine on the LATER Gemfile line resolves FIRST.
# solana-studio leads studio-engine here for that reason and no other, and
# swapping the two lines silently reverses it: measured on 2026-09-01, the
# swap exchanged their positions and nothing raised. Do not reorder these two
# for tidiness. test/lib/view_path_order_contract_test.rb asserts the
# resulting order, so a reorder fails there instead of changing which gem a
# partial renders from.
gem "solana-studio", "~> 0.9" # 0.9.0 is the real floor, and the pin SAYS so. This app now LOADS the redirect transport (solana_studio/wallet_transport, redirect_provider, wallet_journal, wallet_ops — see layouts/application) and registers the contest_entry intent against it, which is what gives a phone any way to sign at all. TWO SEPARATE ARRIVALS, and the floor is the LATER one. (1) The transport itself first exists in 0.8.0 — below that `SolanaStudio.walletOps` is undefined and walletOps.run throws on the first hold-to-confirm, a LOUD failure. (2) The floor that actually moved the pin is 0.9.0, and it fails SILENTLY, which is the only reason this note is worth its length: solana_studio/modals/_wallet_connect gained mobileHandoffs + openInWallet there, the getters that paint a Solflare or Backpack row on a phone. Below 0.9.0 the picker never asks the registry this app now loads, so those two wallets fall back to their DESKTOP EXTENSION download rows — the exact dead end /tasks/fix-wallet-picker-deeplink-claim removed — and nothing raises, logs, or fails a test. DERIVED, not read off a changelog: unpacking the published gems, 0.8.0 ships the four transport files with ZERO mobileHandoffs in the picker, and 0.9.0 ships both. INVISIBLE TO THE RESOLVER in the usual way — the old "~> 0.6" already admitted 0.9.0 and the lockfile resolved 0.7.0 — so this bump is the FLOOR moving, and `bundle update solana-studio` is what makes the lock agree.

# IP geolocation for state-level geo-blocking
gem "geocoder"

# Random username generation for new wallet-only users (via Studio::UsernameGenerator)
gem "faker"

# Background jobs
gem "sidekiq"

# Payment processing
gem "stripe"

# EdDSA (Ed25519) signing for JWTs — required by Cdp::Auth for Coinbase CDP
# Onramp/Offramp REST auth. jwt 3.x extracted EdDSA support into this gem;
# vanilla jwt raises JWT::EncodeError ("Unsupported signing method") without it.
# Pinned: third-party gem (anakinj) sitting on the CDP secret-key signing path.
# See docs/CDP_RAMP_INTEGRATION.md §1.
gem "jwt-eddsa", "~> 0.9"

# Request throttling (OPSEC-019). Rack middleware that rate-limits per IP /
# per user / per endpoint. Configured in config/initializers/rack_attack.rb.
# Disabled in test env (so tests don't hit throttles by accident).
gem "rack-attack"
