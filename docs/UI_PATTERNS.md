# UI Patterns & Branding

> Payment note: Stripe-specific token-picker sections are legacy/dormant unless
> `PAYMENT_PROVIDER=stripe` is explicitly set. The default unset provider is
> `none`; current funding surfaces should prefer PayPal/Venmo, CDP, or direct
> USDC entry when those flags are enabled.

## Branding & Theme

- **Theme**: Dynamic — engine-generated CSS custom properties from 7 role colors (see `studio-engine/docs/NAVBAR_SETUP.md` plus this file's semantic-token notes)
- **Theme config**: `theme_primary = "#2E7D32"` (green), `theme_success = "#2E7D32"` (the same green), `theme_accent = "#8E82FE"` (violet) in `studio.rb`. A `ThemeSetting` row saved from `/admin/theme` overrides any of them per environment.
- **Admin theme page**: `/admin/theme` — color editor + styleguide (from engine)
- **Primary**: `#2E7D32` Green — brand text, CTAs, buttons, nav hovers, money displays, balances, checkmarks, hold button idle state
  - **Why this green (2026-09-16).** It replaced `#4BAF50`, which gave `.btn-primary`'s white label 2.78:1, below WCAG AA's 4.5:1. White measures 5.13:1 on `#2E7D32` and 8.46:1 on the engine's hover fill `#205823`. `test/views/primary_button_contrast_test.rb` fails on any primary that drops those below 4.5:1.
  - **Green TEXT reads the primary ink, not the fill.** As text on the dark theme (the default), `#2E7D32` measures 3.41:1 on the page and 2.18:1 on a card. So `text-primary` resolves to `--color-primary-ink`: `#81C784` in the dark theme (8.68:1 page, 5.54:1 card) and the primary itself in the light theme (4.90:1 page, 5.13:1 card). `#81C784` fails on white (2.01:1), which is why the ink is per theme. The tokens live at the end of `app/assets/tailwind/application.css`; `config/tailwind.config.js` routes `text-primary` (and its `/alpha`, `hover:` and `group-hover:` forms) through them, while `bg-`, `border-` and `ring-primary` keep the fill. In hand-written CSS or an inline `style`, write `color: var(--color-primary-ink)`, never `var(--color-cta)` or `var(--color-primary)`.
  - **Text on a primary tint reads `--color-primary-badge-ink`.** On the `.level-badge-1` wash (primary at 15 percent) the light-theme primary is only 4.21:1, so the badge ink is the scale's 700 shade there (6.95:1) and the dark ink in the dark theme (5.04:1). Guard for both inks: `test/views/primary_text_contrast_test.rb`.
  - **Still open (measured, not fixed):** Tailwind badges written as `bg-primary/10`, `/15` or `/20` with `text-primary` (32 lines in `app/views`) get the plain ink, so in the light theme they measure 4.21:1 (4.49:1 on a `/10` tint). The light ink is also 4.10:1 on `bg-inset` (`#E4E6E8`); it clears the page, cards and `bg-surface-alt` (4.61:1). The link hovers still read the fill scale: `hover:text-primary-600` is 1.69:1 on a dark card (the Phantom help page, the admin pending-transactions TX link) and `hover:text-primary-300` is 2.07:1 on white. The navbar balance links add `dark:hover:text-primary-300`, because their 600 hover measured 2.65:1 on the dark page, where the old primary's was 4.66:1.
  - **Deliberately still `#4BAF50`**: decorative multi-hue light (confetti palettes, `.level-badge-10`'s rainbow, the landing blobs, `.glow-brand` orbs) and chart series colours on the slate reports. There the bright green is one hue among many, and nothing is written on it.
  - **Success is the same green.** `theme_success = "#2E7D32"`, so `btn-success`'s white label measures 5.13:1 (it was 2.78:1 on the engine default `#4BAF50`). Success text is `text-success-ink`, which the engine derives per theme from that colour and which clears AA on every surface and on its own tint.
- **Mint**: `#06D6A0` — win badges, contest status (open). Reserved for game mechanics (win), not general selection UI. NOT the hold button's success state any more (2026-08): confirming used to jump to mint/teal, a different hue from the button pressed, with a mint check that barely showed on it — it now brightens within the brand green and draws the check in white.
- **Accent**: `#8E82FE` Violet — scores, draft badges, `.btn-secondary`, Phantom wallet badge. NOT for CTA-intent elements (use `primary` instead). NOT for turf scores (use `primary`).
  - **Violet TEXT reads the violet ink, not the fill.** `#8E82FE` is a fill: as small text it measures **3.10:1 on the light card and 3.60:1 on the dark card**, both under AA (found reviewing PR 774, 2026-09-19, on the `/benchmarks` Turf Score column). Mr. McRitchie's call (2026-09-21) was to add a text-only variant rather than darken the brand token, so `--color-violet-ink` is `#C5C0FE` in the dark theme (the ramp's violet-300: 6.56:1 card, 10.27:1 page) and `#5B50CE` in the light theme (violet-600 darkened 10 percent: 6.03:1 card, 5.76:1 page). Neither can serve the other theme — `#5B50CE` is 1.85:1 on the dark card and `#C5C0FE` is 1.70:1 on the light one. The token lives at the end of `app/assets/tailwind/application.css` with the full derivation; `config/tailwind.config.js` exposes it as `text-violet-ink` **in `textColor` only**, so there is deliberately no `bg-violet-ink` or `border-violet-ink` to drift the fill off-brand.
  - **`text-violet` (the fill) is still correct for large display type.** WCAG large — 24px, or 18.66px bold — clears at 3:1, and the brand violet does. TWO such lines keep it — `admin/scoring` and `games/index`, both `text-2xl font-extrabold` directly on `.card` — plus the signer-roster status dot, which is a graphical object at 3:1 and already picks its shade per theme. **The exemption is about the SURFACE, not the font size.** Seven lines in `pages/turf_totals_v1` and `pages/turf_monster_v1` were briefly exempted under the card's 3.10:1, but they sit in `bg-surface-alt`, where the brand violet is **2.79:1** — under the 3:1 large-text floor. They read the ink. `test/views/violet_text_contrast_test.rb` holds that list: a new bare `text-violet` anywhere else fails, and a new one in an allow-listed file fails until the count is bumped with a reason. That guard also runs an **inline lane**: every `style="color:"` under `app/views` and `app/helpers` is resolved through the page's own `<style>` tokens and the compiled stylesheet, then measured against the surface the styled element actually sits on. So a violet written as `var(--fc-mult)` or a bare `#8E82FE` is caught wherever it is written, with no list to widen — `slates/show` painted five such labels that the class scan could not see.
  - **Still open (measured, not fixed):** two violet FILLS the ink cannot reach. `bg-violet-900/30` (the `CONTEST_BADGE_STYLES` "pending" badge) composites to a pale lavender in the light theme where the ink is **3.50:1** — up from the brand violet's 1.80:1, but short; its mint, yellow and red siblings share the shape, so the fix is the badge family. And `hover:bg-violet/30` on the wallets airdrop button is **4.46:1 light / 4.38:1 dark**, while its rest state `bg-violet/20` clears. Both are FILL defects, so an ink cannot reach either.
  - **Closed (was open here):** the other two `slates/show` formula series. `--fc-goals` was **1.96:1 on the light card** and `--fc-dk-score` **2.22:1 on the dark card**, and the same green painted the two Save Formula buttons at **3.48:1 on the dark page** — a ground the panel-shaped reading of the defect missed. Each series now carries its own `-ink`, and **only the failing theme moves**, so a series keeps its brand colour wherever it already clears: `--fc-goals-ink` is `#B8B0FF` dark / `--color-violet-ink` light (**6.03:1**), `--fc-dk-score-ink` is `#15803D` light / `--color-primary-ink` dark (**5.54:1** card, **8.68:1** page). The fills still paint the chart strokes, the `border-left` and the sliders' `accent-color`, which are graphical objects at 3:1. The guard's inline lane is now PARAMETERISED over the four series (`INLINE_SERIES`) rather than filtered to violet, and it asserts **per series** that each one is actually found painting text — reddening one member of a loop proves nothing about the others, which is how these two sat unwatched for a release.
- **Primary for selection UI**: Selection count badges, cart slot borders, matchup selection rings/tints, turf score values, links, sort toggle active state, and FAB buttons all use `primary` (green), not mint or violet.
- **Warning**: `#FF7C47` Orange — warning states, `.btn-warning`
- **Negative**: Red (Tailwind default) — losses
- **Font**: Montserrat (all weights 400-900), stack `Montserrat, system-ui, sans-serif`. Since studio-engine 0.56.3 the face is VENDORED — self-hosted woff2 through the asset pipeline, no Google Fonts — and declared `font-display: optional`. **Design for the fallback face.** `optional` has no swap period: a face not ready inside the browser's block period is abandoned for that whole navigation, so any visitor on a cold cache reads the page in `system-ui`, which is narrower than Montserrat on macOS and wider on Linux. A layout that only fits in Montserrat's metrics is broken for real users, not just for CI. `e2e/vendored_font_fallback.spec.js` holds that line for the header: it asserts the vendored woff2 really resolve same-origin here, then re-measures containment with the face forced to the fallback and to a proven-wider one.
- **Logo**: Two files exist — `/public/logo.png` (1.3MB, used in layout navbar) and `/public/logo.jpeg` (272KB, used in auth pages). Both are the green monster mascot. Should be consolidated to one file.

### Semantic Tokens (required)
- **Surfaces**: Use `bg-page`, `bg-surface`, `bg-surface-alt`, `bg-inset` — never hardcode `bg-navy-*`
- **Text**: Use `text-heading`, `text-body`, `text-secondary`, `text-muted` — never hardcode `text-white` for headings or `text-gray-*` for body text
- **Borders**: Use `border-subtle`, `border-strong` — never hardcode `border-navy-*`
- **Error / danger TEXT**: Use `text-danger-ink` — never a static red (`text-red-400`, `text-red-300`, an inline `color:#f87171`). A fill may be vivid; text must clear WCAG AA 4.5:1 on **both** cards, and no static red does. The modal card is `bg-surface`, which is pure white in light mode: measured against this app's resolved theme, `text-red-400` is 2.89:1 light and 3.86:1 dark, so it fails both. `text-danger-ink` is derived per theme by studio-engine's `ThemeResolver#contrast_ink` (5.76:1 light, 4.50:1 dark here). Guarded by `test/views/error_text_contrast_test.rb`, which resolves the colour and measures the ratio rather than matching a class name. Its scope is two lanes: every text colour in the modal/sign-in surfaces **and** the four user-facing error surfaces (`contests/_quest_newsletter`, `contests/_turf_totals_leaderboard`, `wallet_exports/show`, `proof_of_reserves/show`), plus any element anywhere under `app/views` (except `app/views/admin`) bound to an error-ish Alpine expression — so a NEW error paragraph is measured without anyone remembering to widen a list.
- **Danger text needs a theme surface under it.** `text-danger-ink` is derived to clear AA against the four theme surfaces (`bg-surface`, `bg-page`, `bg-surface-alt`, `bg-inset`), and a tint is not one of them — compositing `bg-red-500/10` over the dark card yields `#4f3750`, where the ink measures **4.25:1** and fails AA. (Composite in GAMMA-ENCODED sRGB, the way a browser does — a linear-light blend gives `#673751` and 3.78:1, which is wrong and is the figure this line carried between PR #649 and `contrast-guard-composites-wrong`. Chrome's own pixel is one 8-bit step away at `#4f3650`, 4.29:1 — also a fail.) Put an alert panel on a theme surface (`bg-inset` or `bg-surface-alt`; the ink is 7.31:1 on the dark `bg-surface-alt`) and keep the red *border* for the affordance, rather than a red wash. The guard composites every enclosing background before measuring, so a red-tinted panel is caught rather than scored against the bare card.
- **Violet TEXT**: Use `text-violet-ink` for anything under 24px (or under 18.66px bold) — table cells, badge labels, mono values, body copy. `text-violet` stays the FILL and is only for large display type. Unlike `text-danger-ink`, this ink IS derived against the violet tints as well as the four theme surfaces, because this app writes `bg-violet/10 text-violet-ink` and `bg-violet/20 text-violet-ink` badges at 10px and 12px; it clears **5.49:1 (card) and 5.24:1 (page) on `bg-violet/10`, and 4.94:1 and 4.75:1 on `bg-violet/20`** — four grounds, two tints, not one tint's pair. Guard: `test/views/violet_text_contrast_test.rb`, which resolves the compiled rule (converting Tailwind v4's `oklab()` opacity variants back to sRGB) and computes the ratio rather than matching a hex.
- **A utility name is NOT a custom property name.** `bg-` / `text-` / `border-` are utility PREFIXES; the variable underneath drops them. `bg-surface` reads `var(--color-surface)`, `bg-page` reads `var(--color-page)`, `border-subtle` reads `var(--color-border)`, and `text-primary` reads the primary INK (`--color-primary-ink-rgb`, rerouted at `config/tailwind.config.js:71`). Writing the utility name as a variable — `var(--color-bg-surface)`, `var(--bg-page)`, `var(--color-border-subtle)`, `var(--color-subtle)`, `var(--color-text-primary)` — names nothing, and an undefined custom property makes the **whole declaration invalid at computed-value time**: `background: var(--color-bg-surface)` paints NOTHING and `border: 2px dashed var(--color-subtle)` drops the entire shorthand. Nothing errors; the page just renders a layer short. All five of those spellings shipped and were measured on 2026-09-22 (18 reads across 13 sites: admin forms, `seeds_lab`, the contest hero avatar ring, the admin navbar preview and the referral progress slots). `test/views/custom_property_declaration_test.rb` now asserts that every `var(--name)` under `app/views`, `app/helpers` and `app/assets/tailwind` is written somewhere — the compiled stylesheet, `Studio::ThemeResolver`, this repo, or studio-engine — so a name that resolves to nothing fails the suite. It reads TEXT rather than elements, so a `var()` inside an ERB-assigned Ruby local counts; `violet_text_contrast_test.rb`'s inline lane cannot see those, and it SKIPS an unresolvable name rather than failing it, which is how these five survived.
- **CSS var naming**: `--color-cta` / `--color-cta-hover` for singular CTA color. Full `--color-primary-{50..900}` palette with RGB variants for Tailwind `primary-*` utilities.
- **Tailwind config**: `primary` palette is dynamic from shared studio config (CSS vars). `warning` palette defined locally in `config/tailwind.config.js`. Safelist includes `bg`, `text`, `border`, `ring` utilities for brand colors.

### Tailwind Compilation Constraints
Tailwind emits only classes it can see during the build. Keep dynamic class names on a short leash:

- Prefer literal class strings in ERB and JS templates.
- If a class is assembled dynamically, add it to `config/tailwind.config.js` `safelist`.
- Theme role colors are already safelisted for `bg`, `text`, `border`, and `ring` utilities across the configured shades/opacities.
- `level-badge-*` classes are safelisted because ERB emits them dynamically.
- One-off static dimensions can stay inline when extracting a class would create noise or when a previously valid utility was purged.

### Public S3 and OG Assets

The constraint is that an og:image URL must be **permanent**: an unfurler caches
the URL it was handed and re-fetches it days later, so anything carrying an
expiring signature is a preview that works today and is broken by the weekend.
There are two sanctioned ways to satisfy that, and which one applies depends on
whether the image is an OG asset in its own right or a rendition of an image
that already lives somewhere private.

**1. Images uploaded AS og:images — public service.** `SiteSetting`'s
`default_og_image` and `LandingPage`'s `og_image` use the `amazon_public` /
`amazon_public_dev` services and are served as permanent S3 object URLs.
`OgImageAttachable` owns the per-environment service choice. Do NOT put these on
the private `amazon` services, whose `.url` is a signature that expires.

**2. Renditions of an image that lives on the PRIVATE service — proxy route.**
A contest banner (`Contest#contest_image`) is a normal private attachment that
also has to unfurl, and moving every existing banner into a public bucket to get
that is the wrong trade. Instead `OgHelper#contest_og_image_url` hands out
`rails_storage_proxy_url(... .variant(:og_card))` — the representation **proxy**
route, which is permanent (the signed blob id carries no expiry), lives on our
own domain, and streams from the same private bucket. Use the proxy route, never
`rails_storage_redirect_url`, which hands back the expiring service URL this
whole section exists to avoid.

Guard the variant on `variable?`, not merely `attached?` — `.variant` raises
`ActiveStorage::InvariableError` eagerly for a content type outside
`ActiveStorage.variable_content_types`, which would 500 the public page rather
than fall through to the default card.

### Status Badges
`ApplicationHelper::CONTEST_BADGE_STYLES`, keyed by contest status — the pill on
contest cards and headers: mint=open, yellow=locked (DERIVED time-gate, not a
status — `Contest#locked?`), gray=settled, violet=pending, red=cancelled
(`Contest#cancelled?`, the `onchain_cancelled` boolean — also not a status).

### Live Board State Badge
A DIFFERENT badge from the one above: `ContestsHelper::LIVE_STATES`, the label +
dot beside the contest name on `/contests/:slug/live`, and the same string in the
tab `<title>`. Five states — Cancelled (red), Live (red + `animate-pulse`),
Concluded (orange), Final (gray), Not started (gray).

Fixed precedence: **cancelled → final → concluded → live → upcoming**. The order
is load-bearing, not cosmetic. `Contest#live?` is `locked? && !settled?` and
mentions neither cancellation nor conclusion, so both of those states satisfy
`live?` and would be swallowed by the `live` branch if asked later; and `settled?`
forces both `locked?` and `concluded?` true by definition, so `final` must be
asked before `concluded`. Two separate bugs have been filed against this helper
for exactly that class of miss — the full five-predicate state space, including
the combinations that are unreachable and why, is documented in the comment above
`LIVE_STATES` in `app/helpers/contests_helper.rb`. Read it before adding a state.

**Motion is reserved for `live`.** The pulsing dot means one thing — this contest
is in progress — so every terminal, finished, and not-yet state takes a solid dot.
Pinned end to end in `test/controllers/contest_live_state_test.rb`, which asserts
on rendered page output (label, `data-state`, dot class, `<title>`) rather than on
the helper's return value.

The badge is server-rendered at page load and does NOT self-correct:
`Contest::LiveBroadcast` replaces the games strip and focus panel, not the header,
so a contest whose state changes under a viewer keeps the label it was drawn with
until a reload.

## Button System

CSS component classes in `app/assets/tailwind/application.css`:
- `.btn` (base), `.btn-primary` (green/white), `.btn-secondary` (violet/white), `.btn-outline` (border/transparent), `.btn-warning` (orange/white), `.btn-danger` (red), `.btn-google` (white/hardcoded gray-700 — uses `color: #374151` for dark mode compat)
- Size modifiers: `.btn-sm`, `.btn-lg`
- Disabled state built into `.btn` base
- Combine: `class="btn btn-primary btn-lg w-full"`

## Component Classes
`.card`, `.card-hover`, `.input-field`, `.empty-state`, `.json-debug`, `.label-upper`, `.badge`, `.matchup-selected`

## Matchup Grid

`_turf_totals_board.html.erb` — two sort modes toggled via Alpine (`sortMode`/`sortDir`):

- **Game view** (default): Paired cards with "vs" divider (`color-mix` background), sorted by lowest turf score. Uses `_matchup_game_pair.html.erb` partial (locals: `left`, `right`, `locked`); the enclosing grid carries the `tm-pair-grid` hook so the sidebar-push companion rule can drop it to one column (see § Sidebar Primitive). Both-selected: outer `outline` + `box-shadow` glow in primary, "vs" div gets primary tint.
- **Turf Score view**: Flat grid (`tm-team-grid grid-cols-2 md:grid-cols-4` — the `tm-team-grid` hook is what lets the sidebar-push companion rule drop it back to two columns; see § Sidebar Primitive) of individual cards sorted by turf score. Uses `_matchup_card.html.erb` partial (local: `matchup`). Double-click "Turf Score" toggles asc/desc (arrow indicator). Two server-rendered orderings toggled via `x-show` (no JS re-sorting).
- Both views share the same Alpine `selections` state — selections persist across view switches.
- **Filter input**: Text input in the sort toolbar filters matchup cards by team name (both teams). Uses `matchesFilter()` Alpine method with `x-show` on wrapper divs. Clear X button appears when text is entered.

### Matchup Card Layout
Flag emoji (3xl) → Team name (bold, lg/xl) → Turf Score number (primary, 2xl/3xl, no prefix, integers without decimal) → "Points / Goal" label (singular "Point" when turf score is 1) → Game info line (tiny, both teams' emojis + short names, e.g. "🇪🇸 ESP vs CPV 🇨🇻"). Cards use `rounded-2xl`. Standalone cards have `w-full` to fill grid cells. Auto-shrink JS for long team names.

### `.matchup-selected` class
Uses `outline` (not border) for selection highlight — avoids layout shift. Dynamic primary color via `rgb(var(--color-primary-rgb))`. Includes `box-shadow` glow. Double-selected game pairs use inline `outline` + `box-shadow` on the wrapper div.

## Cart
- **Cart slot cards** (`_turf_totals_cart_slots.html.erb`): Emoji + Team Name + "vs OPP" on first line, "Goals" + turf score on second line.
- `pickOrder` array in Alpine state controls display order (insertion order)
- "Clear All" button clears selections locally + abandons entry server-side
- Blur overlay fires once per page load (`blurUsed` flag)

## Long-Press Button

**Owned by studio-engine since 0.56** (`studio/_hold_button` + `studio/_fizz_layer`,
`Studio::FizzHelper`, and the ACTION family in `engine-motion.css`). This app used to
carry its own copy of all four; `adopt-engine-hold-button` deleted them. Render it:

```erb
<%= render "studio/hold_button", hold_id: "desktop", duration: 2000, ... %>
```

- **Where it renders here**: the contest board's desktop + mobile cart (two DOM
  elements, differentiated by `hold_id`) and the entry-token modals
  (`modals/auth/_tokens`, `_paypal_tokens`).
- **Params, states, fizz levels, zones, the `--hold-*` theming inputs**: documented
  in the engine's CHANGELOG (0.56) and staged live on `/admin/style` → Tricks →
  "Hold to confirm". Do not re-document them here — a second copy of a spec drifts
  the same way a second copy of the CSS did.
- **The floor is real**: `Gemfile` pins `~> 0.56` and
  `test/lib/engine_pin_contract_test.rb` asserts it. Below 0.56 the partial does not
  exist and the board's confirm button raises on render rather than degrading.
- **Do not re-declare its classes locally.** Since **0.56.1** the engine ships
  `.hold-btn`, `.hold-stack`, `.fizz-bit` and `.nudge-debug` inside
  `@layer components`, and anything this app writes as `@utility` compiles into
  `@layer utilities` — a LATER layer in Tailwind v4's `theme, base, components,
  utilities` order, so the local copy WINS regardless of specificity. A local
  re-declaration is therefore not inert: it silently SHADOWS the engine primitive,
  and this button drifts from the `/admin/style` specimens with nothing in the
  engine having changed. (Before 0.56.1 the engine sheet was unlayered and the
  override lost instead. The hazard inverted; it did not go away — which is why
  the rule is "do not re-declare", not "re-declaring is harmless either way".)
  `test/lib/tailwind_css_dedupe_test.rb` guards the state names (`process`,
  `success`, `error`, `loading`, `nudge`, `nudge-soft`, `hold-icon`, `hold-text`,
  `fizz`, `hold-fizz`, `fizz-bit`); `.hold-btn`, `.hold-stack` and `.nudge-debug`
  are on you.

### What this app still owns
- **The palette.** `TeamColorsHelper#team_card_palette` yields `fizz_light` /
  `fizz_dark` / `fizz_alt` per team (the alt is the flourish where a team curates
  one — the Ravens' red, the Buccaneers' orange — else its dark). The board carries
  them into `matchupData` as `colorLight` / `colorDark` / `colorAlt`, and its
  `fizzPalette` getter maps the six picked teams onto the engine's eighteen
  `--fizz-c-*` slots, three per pick in pick order, bound with
  `fizz_bind: "fizzPalette"`. Each pick owns one zone, so the fizz re-dresses itself
  as picks change. Pinned by `test/integration/hold_button_fizz_palette_test.rb`
  (server half) and `e2e/board_fizz_palette.spec.js` (the colours actually painting).
- **The callbacks.** `guard`, `validate` / `validate_at`, `early_action`,
  `on_hold_start` and `on_success` are this app's expressions, evaluated against the
  board's Alpine scope.

### Hold Validation
Optional mid-hold validation via `validate`/`validate_at` params. `validate` is a JS expression returning `Promise<boolean>`, called at `validate_at` ms (default 1000). If false, hold aborts. Both buttons use `validate: "d.runHoldValidations()"` which checks geo-blocking (fresh `GET /geo/check`) then login status.

### Nudge Animation
JS-driven, big nudge at 3s then soft nudge every 10s. Resets on hold, soft-only after release. Engine-owned since 0.56.

## Pick Slot Animations
- `pick-pulse` (gentle glow, picks 3-4)
- `pick-pulse-shimmer` (glow + sweep, picks 2 and 5)
- `pick-pulse-urgent` (fast intense glow + scale + sweep, pick 5 after removal)
- `pickUrgent` flag set when going from 5→4 selections, cleared when reaching 5 again or clearing all

## Redirect Modal

Two mechanisms fire in sequence on the hold path, and **geo is not one of the
blocker arms**. Reading it the other way round is exactly what the old version of
this section got wrong.

### 1. The geo pre-check runs first, and returns

`runHoldValidations()` (`contests/_turf_totals_board`) is the hold's `validate`
callback. It fetches `GET /geo/check` before anything else; when `geo.blocked` is
true it sets the hold error, opens the redirect modal, and returns `false` — the
blocker switch below is never reached. That call is the **only** caller of
`showRedirectModal` in the app.

`showRedirectModal(title, message, icon, url, seconds, cta)` does not navigate on
its own. It opens the auth wizard at its `redirect` step (`modals/_auth`), which
renders `studio/modals/blocks/card_header` + `studio/modals/blocks/cta_redirect`.
The engine block owns the 5s drain end-to-end and reads `props.url` at fire time
(pass a null url to suppress the auto-navigation and keep the drain visual). The
one call passes "Location Restricted" → `/`.

### 2. The blocker switch navigates nowhere

`showEligibilityBlockerModal(blocker)` (same partial) switches on
`blocker.reason`. It has **seven arms plus a default, and ZERO of them are redirect
modals** — no arm navigates: the seven named arms each open a modal and stay on
the page, and the default only resets the hold button:

- `not_logged_in` → `showLoginModal()` — the auth modal, not a redirect to `/signin`
- `first_name_required` → `showFirstNameModal()` in its required mode (no skip affordance)
- `age_required` → `showAgeVerifyModal()`
- `wallet_setup_required` → `showWalletSetupModal()`
- `no_funding` → `showFundsNeeded()` — Get USDC (`modals/_buy_usdc`), or Buy an Entry Token (`modals/_buy_entry_token`) for the USDC kill-switch audience (a web2 session with `ENABLE_WEB2_USDC_ENTRY` off). When that audience's two entry-token rails are both dark, `showBuyEntryToken` falls through to `showGetUsdc` rather than open an empty card — so with no rail to show, every audience lands on Get USDC.
- `insufficient_balance` → `showInsufficientBalanceModal(blocker)` — the web3 deposit/currency picker (`modals/_wallet_deposit`, modal id `wallet-deposit`)
- `web3_step_up_required` → `showWeb3StepUpModal(blocker)` — the self-custody step-up card (`solana_studio/modals/web3_step_up`, modal id `web3-step-up`; the partial is engine-owned, rendered by the app layout). Added by `self-custody-entry-unguarded`: a web2 session acting on a self-custody account, which has no managed keypair to sign the entry with. It opens the card and calls `resetHoldButtons()` — it does not navigate.
- `default` → `resetHoldButtons()`

There is no `geo_blocked` arm, and `blocker.reason` never carries that value
anywhere in the app. (`geo_blocked?` does exist, but it is a server-side ERB
helper read by `_wallet_deposit`, `shared/_buy_usdc_geo_note`,
`shared/_buy_usdc_button` and `wallets/show` — a different mechanism on a
different layer.)

**The two paths leave the hold button in OPPOSITE states**, so do not read the
red state as "blocked" in general. `setHoldError()` — the only code that adds
`.error` ("Entry Blocked") — has exactly one caller, the geo pre-check, so the
red state belongs to geo alone. The switch path CLEARS it instead: six of the
seven arms and the default call `resetHoldButtons()`, and the `no_funding` arm
does not touch the button at all (`showFundsNeeded` only opens a card).
(`resetHoldButtons` is not the only clearer, whatever its own comment says —
`setHoldSuccess` and `setHoldLoading` drop `.error` too.)

### What this section used to claim, and why both halves were wrong

It said insufficient funds redirected to "Top Up Wallet" at `/wallet`.

**On the route.** `/wallet` **is** a route — `resource :wallet, only: [:show]` in
`config/routes.rb`, served by `WalletsController#show`, and the navbar balance
links to it (see § Navbar). The narrower true statement is that it was never the
funds-wall destination: no arm of `showEligibilityBlockerModal` navigates
anywhere, and the only navigation on the hold path is the geo pre-check's CTA
to `/`.

**On the modal.** Top Up Wallet (`modals/_wallet_topup`) has no entrance at head.
`showWalletTopup` has one definition and zero calls — no `@click`, no dispatch,
nothing in `app/assets/builds/`, and no dynamic `this[...]` dispatch in the board
or the layout. The Add Funds hub's Back link swaps there only when
`props.returnModal === 'wallet-topup'`, and the sole writer of that prop is
`_wallet_topup` itself, which makes it a return path from itself rather than a
way in.

**The ADMIN door did not close — it moved.**
Both of the old ones are gone: `/admin/modals` was retired on 2026-09-09, and the
`AdminController#modal_preview` seam behind `/admin/modals/preview/<id>` — which
passed `params[:modal_id]` through raw to `$store.modals.open()`, over a layout
that never registered this partial — went the same day. But turf's own section of
the living style guide CARDS this modal (`app/views/style/host/_modals.html.erb`,
added 2026-09-09), and that card is not a specimen: it carries `openable: true`
and fires `$store.modals.open('wallet-topup', {})` against the APP's host, on an
admin page whose layout registers `wallet-topup` ungated. So an admin can open
the real card deliberately, and any assertion resting on "nothing anywhere opens
this id" is now false. What remains true is the narrower and more useful claim:
there is no PLAYER-facing entrance at head.

It regains a player-facing entrance the moment either condition changes:
something calls `showWalletTopup`, or some other opener passes that prop.

## Navbar

Extracted to `layouts/_navbar.html.erb` partial. Sticky, scroll-responsive. The non-preview header is `nav-shell vt-pinned-header sticky top-0 z-[var(--z-nav)] bg-page transition-shadow duration-300` — `--z-nav` deliberately sits below the shared modal host backdrop at `--z-modal`, so every modal covers persistent navigation chrome. Both come from the shared layer scale (see **Layer scale** below); the header also carries a z-index, which makes it a stacking context, so the environment bars render as a SIBLING above it rather than inside it.

### The collapse is scroll-LINKED, not a threshold plus a clock

The header carries `x-data="navCollapse()"` (factory in `shared/_alpine_factories.html.erb`). It publishes **one number, `--nav-p`** — collapse progress, `0` expanded to `1` collapsed — on the `<header>` itself, once per animation frame, from `window.scrollY`. `application.css` derives every collapsing dimension from it with `calc()`: row padding, logo size, title size, "Totals" size, balance size, username size. `--nav-p` is registered with `@property` as a `<number>`, which is what makes the `calc()`s legal, gives an untouched page a real `0`, and lets `/admin/navbar` transition it directly.

**Nothing on the collapse path carries a time-based transition.** `transition-shadow` on the header is the exception and may stay: `box-shadow` paints, it never reflows, so it cannot move content.

**What this replaced, and why.** The old build flipped an Alpine `scrolled` boolean at `scrollY > 60` (hysteresis back at `5`) and fed that step into `transition-all duration-300` on five layout properties at once — padding, logo `width`/`height`, and three font sizes. The finger set the step; an ease curve owned everything after it. Measured 2026-08-27 at 390×844:

| | before | after |
|---|---|---|
| Header height, expanded → collapsed | 178px → 139px | unchanged (178px → 139px) |
| Content displacement after the finger STOPS | **34px over 232ms** | **0px** |
| Peak uncommanded content velocity | ~3px/frame (~180px/s) | 0 |
| Reverse (wrong-direction) lurch at the threshold | +1px | none |
| Peak content speed during the collapse | 2× the finger, stepping straight back to 1× | ~1.5×, easing out of and back into 1× |

**Why content speeds up at all.** Collapsing a sticky, *in-flow* header pulls the page up, so during the collapse content moves by the scroll **and** by the shrink — always faster than the finger. That is inherent; reclaiming the vertical space is the point. The design problem is the shape of the burst. `--nav-ramp` is **3× the band's collapse total** (mobile `120px`, desktop `144px`) and `navCollapse()` eases it with a smoothstep, whose slope is zero at both ends — so content speed leaves 1×, peaks near 1.5× mid-ramp, and returns to 1× with no velocity step at either end.

**Three details in `navCollapse()` that are load-bearing:**
- **passive + rAF** — the listener never blocks the compositor and coalesces a burst of scroll events (iOS momentum fires well above 60Hz) into one write per frame. The write lands on the header, **not `:root`**, so each frame's style recalc stays inside the navbar subtree.
- **the short-page guard** — collapsing shortens the document by `--nav-ramp`. On a page with barely more than that to scroll, the collapse deletes the very scroll room that triggered it, the browser clamps `scrollY` to 0, and the navbar flaps forever. `roomExpanded` adds back the shrink already applied so the measurement cannot chase itself; under `--nav-ramp + 24` the collapse is disabled outright.
- **reduced motion** — scroll-linked motion has no clock left to slow down, but resizing type under a moving finger is itself the motion some readers are asking us to drop. Under `prefers-reduced-motion: reduce`, `--nav-p` snaps `0`/`1` on the old `60`/`5` hysteresis instead of interpolating.

`is-scrolled` (+ `shadow-lg border-b border-subtle`) is still class-toggled on the same hysteresis — it is the shadow only, and hysteresis keeps it from strobing at the boundary.

### Partial locals
- `show_logged_in` — override `logged_in?` (default: real session). Used by admin preview to force logged-in/out views.
- `preview` — drops `x-data`/`navCollapse()` and sticky positioning. It KEEPS `nav-shell` (the `--nav-p` `calc()`s have to resolve); `/admin/navbar` drives `--nav-p` from its own Scrolled toggle instead.

### Responsive breakpoints
`@layer utilities` in `app/assets/tailwind/application.css` (migrated out of an inline `<style>` block 2026-05-24), three tiers. Mobile title stacks "Turf"/"Totals" vertically via `flex-direction: column` with `-4px` bottom margin on "Turf" to tighten spacing. "Totals" renders larger than "Turf" on mobile.

Each band overrides the `--nav-*` custom properties on `.nav-shell`, so a band is *the two endpoints of its collapse*, not two separate rule sets. Endpoints are unchanged from the pre-2026-08-27 build; only the path between them is.

| Range | `--nav-ramp` | `.user-nav-col` | `.nav-logo` | `.nav-title` | `.nav-title span:last-child` |
|---|---|---|---|---|---|
| **< 400px** | 120px | 14rem | 3rem → 2.5rem | 1.1rem → 0.9rem | 1.3rem → 1rem |
| **400–767px** | 120px | 15rem | 3rem → 2.5rem | 1.25rem → 1rem | 1.5rem → 1.15rem |
| **768px+** | 144px | clamp(16rem, 24vw, 20rem) | 3rem → 2rem | 1.875rem → 1.25rem | — (tracks `.nav-title`) |

Row padding is `1.5rem → 0.5rem` in every band (`--nav-pad`, was `py-6`/`py-2`); balance is `1.25rem → 1.125rem` (`.nav-balance`, was `text-xl`/`text-lg`) and username `1.125rem → 1rem` (`.nav-username`, was `text-lg`/`text-base`). Both left Alpine's per-scroll reactive path when they moved onto `--nav-p`.

### Left side
Logo (`.nav-logo`) + "Turf Totals" brand title (`.nav-title` with two `<span>`s), desktop nav links (`hidden md:flex`: Contests, NFL Totals, Rules, Reserves, geo badge — `_navbar.html.erb:63-69`).

### Mobile sub-navbar
`flex md:hidden` compact row below main nav with `bg-surface-alt border-t border-subtle`. Contains: Contests, NFL Totals, Rules, Reserves, geo badge (`_navbar.html.erb:130-135`). Gear sidebar trigger + theme toggle morph pushed right via `ml-auto`.

### Environment banner
Owned by **studio-engine** (>= 0.30), not by this app: the markup lives in the gem at `app/views/studio/banners/_environment.html.erb`. Turf renders it from `app/views/layouts/_navbar.html.erb:45`, **inside** the sticky `<header>` (opened at `_navbar.html.erb:34`, closed at `:141`) — so it stays pinned with the navbar instead of scrolling away. Turf passes two locals and nothing else:

```erb
<%= render "studio/banners/environment",
           preview: is_preview,
           devnet: Solana::Config.devnet? %>
```

The partial decides for itself whether to appear, what to say, and whether the local inbox is linkable:

- **When it shows** — `!preview && Studio.show_environment_banner?` (gem `_environment.html.erb:29`). That is true in every environment except real production; a QA app runs Rails in production mode, so `QA_ENV` re-opens it there (gem `lib/studio/environment_banner.rb:30-34`). It is **not** conditional on `Solana::Config.devnet?`. `preview: true` — the admin navbar-review page — suppresses it so a preview copy can't duplicate live chrome.
- **What `devnet:` actually drives** — never visibility. It renders a `DEVNET` chip beside the buttons when `devnet && !qa`, and instead appends `Devnet` to the message when `devnet && qa` (gem `_environment.html.erb:21-22`).
- **Message** — `Studio.environment_banner_message`. Off QA it is **derived**, not a literal: `"#{rails_env.to_s.capitalize} Environment"`, which yields `"Development Environment"` in development (gem `environment_banner.rb:42`). On QA it is the fixed pair `"QA Environment · Non-production"`. Extra segments join with ` · ` (gem `environment_banner.rb:38-46`).
- **Colors** — `tone: :environment` in the shared `studio/banners/_app_banner`: a `linear-gradient(90deg, #9d174d 0%, #f72585 100%)` strip with `#ffffff` text and a `0 2px 8px rgba(0,0,0,0.25)` shadow (gem `_app_banner.html.erb:8-12`). Pink/magenta, applied as inline styles — not a Tailwind color utility.
- **Alignment** — the background is full-bleed (`w-full`), but the content is capped at `max-w-7xl mx-auto` and laid out `flex items-center justify-between`: message left (truncating), actions right. Nothing is horizontally centered — `items-center` aligns the row vertically (gem `_app_banner.html.erb:28-33`).
- **Actions**, in render order — the `DEVNET` chip (only when `devnet && !qa`), the `DEV MODE` toggle, then the `Email` status button (gem `_environment.html.erb:31-35`). Email links `/_studio/local_emails` only where that page actually answers; on QA it degrades to an inert status chip so the banner can never advertise a 404 (reachability is computed at gem `_email_status_button.html.erb:8-11`; the link-vs-inert-chip branch is at `:30-42`).

The DEV MODE toggle drives `$store.devMode` (see Dev Mode section).

### Geo badge
Rendered from the ENGINE's `components/_geo_badge` (studio-engine >= 0.57 — this app's fork was deleted in adopt-engine-geo-primitives) — shared by desktop nav and mobile sub-navbar. **Public: renders for every visitor, signed in or not** — detection is IP-based (`Studio::GeoDetection#detect_geo_state` runs on every request), and lookups are cached in `Rails.cache` for 24h keyed by IP (the engine configures Geocoder on boot) so the anonymous ipinfo tier's shared rate limit doesn't blank the state into a red `??`. Shows flag + state code when resolved; red `??` when undetectable (fail-closed); red when blocked or a geo override is active. Stable selector: `.geo-badge`. State flags ship as gem assets (`state-flags/<code>.svg`), so the `src` is an asset path rather than a `public/` one; the image uses inline styles for reliable sizing (`height: 12px; width: 16px; object-fit: cover`). Badge shape is `rounded-lg`.

### Wallet signal
Beside the geo badge in **both** navbar rows (desktop nav and mobile sub-navbar), and for the same reason the geo badge is there: the navbar is the one piece of chrome every page gets, and both are facts about the reader that the page under them cannot be trusted to repeat. `shared/_wallet_signal`, `variant: :chip`. Full section below: **Wallet Signal (app-wide)**.

### Right side — logged in: two-row block + avatar
- **Row 1 (Div 1)**: balance, gear + theme toggle morph (left of username, `hidden md:flex`), username. On mobile, gear + morph shown in sub-navbar instead. `padding-right: 6px` via inline style.
- **Row 2 (Div 2)**: 5-section seeds progress bar via `render "components/seeds_bar", compact: true` (turf-vault v0.9.0+ refactor — replaced the old `.seeds-bar`/`.seeds-fill`/`.seeds-text` classes). The partial uses the `.seeds-bar-continuous` class + CSS-registered `--bar-progress` custom property so all 5 segment widths interpolate from a single transition (one ease curve, not 5 chained). Per-section shimmer overlays positioned in bar coordinates (`left: -(i-1)*100%, width: 500%`) keep the wave continuous across segments. Wallet address (left) + Level X (right) overlaid via two-layer clip-path text technique (muted underneath, white on top revealed by `clip-path: inset(0 (100-displaySeeds)% 0 0)`). Level-up: `bar → 100% → bump level (.nav-level-pop) → drain → refill`. Listens for `navbar-replay-level` and `navbar-seeds-update` window events.
- **Avatar**: `_avatar.html.erb` partial (size "nav" = `w-8 h-8`), outside the two-row block. Links to `/account`.
- Balance shows whole dollars only (no cents) — JS hydrate (`refreshSession`/`refreshBalance`) uses `Math.floor`, ERB uses `.to_i`. The pill is **USDC + USDT combined** (`display_balance`); per-currency readouts live on `/account`'s `data-wallet-tile` tiles. The link hides while the cache is cold ("loading"); when the combined balance is $0 with free-entry tokens present the slot swaps the amount for a "✨ Free Entry" label (see § Entry Tokens (Web2 flow)).
- Username and balance link to `/account` and `/wallet` respectively. Both use `transition-all duration-300` for smooth scroll-responsive font-size changes.
- **Username overflow fade**: `.username-cap` class sets responsive `max-width` (5rem tiny, 6rem small, 7rem desktop). When text overflows, Alpine applies a CSS `mask-image` gradient to fade the trailing edge. Overflow is recalculated when the navbar review page's username input changes.
- User nav column has `pl-0 pr-4 md:px-4` — no left padding on mobile.

### Right side — logged out
- Theme toggle morph (`hidden md:flex`) + a **"Sign in"** button, right-aligned. Theme toggle morph appears in mobile sub-navbar instead.
- The button is `class="btn btn-primary"` — the theme's primary color, not a hardcoded green.
- It is a **modal trigger, not a navigation**: `@click.prevent` opens the in-page auth modal via `$store.modals.open('auth', { step: 'credentials', mode: 'signup', … })`. The `signin_path` href is only the no-JS fallback. Login and signup are one create-or-login flow, so the single CTA reads "Sign in" while opening at `mode: 'signup'` (`_navbar.html.erb:118-124`).

## Wallet Signal (app-wide)

Every page says which wallet is live, and a switch anywhere refreshes the state that depends on it. `shared/_wallet_signal` renders it; `app/javascript/wallet_signal.js` decides it.

**Three layers, and none of them is duplicated in this app.**

| Layer | Owner | What it knows |
|---|---|---|
| Sessions — stamp, drift, holds, `session:mismatch` | **studio-engine** (>= 0.76.0), `window.StudioSession` | Nothing about wallets. Web2 by rule, and a vocabulary test in that gem keeps it that way. Its contract is the gem's `docs/SESSION_DRIFT.md`. |
| The wallet as an **identity source** | **solana-studio** (>= 0.12.0), `solana_studio/wallet_identity.js` | Reads the connected address LIVE, re-reads on focus / visibilitychange / pageshow, and reports four statuses. |
| What it MEANS to a reader of Turf Monster | **this app**, `app/javascript/wallet_signal.js` | Which wallet the page should name, and when a switch is a warning. |

### The eight states

Derived by `deriveWalletSignal()`, a pure function, in this order. The session facts are known at render time and decide first; only a real wallet session reaches the browser-readability questions.

| State | When | Tone |
|---|---|---|
| `web2` | Signed in another way, on a page where the browser wallet signs nothing. | muted |
| `guest` | Nobody signed in. **A first-class state, not an absence.** | muted |
| `unknown` | Browser not readable yet (discovery or a silent connect pending). | muted |
| `none` | No provider in this browser at all. | muted |
| `disconnected` | A provider is present and holds no account for this site. Read-only, not broken. | warning |
| `live` | The connected wallet IS this account's wallet. | success |
| `expected` | A different wallet, and **this page declared it** (a cosign ceremony) — or declared it and has since finished with it while that wallet stayed connected. See *The declaration a ceremony leaves behind*. | info |
| `changed` | A different wallet that **nobody declared**. The warning. | danger |

### Session mode narrows the PAGE, not the vocabulary

The first cut of this component had that backwards and was sent back for it, so
the rule is written out rather than left to the code.

A session that signed in **by wallet signature** is accountable to that wallet
everywhere. A session that signed in any other way — magic link, Google — is
accountable to it **exactly where the browser wallet is what signs**. That place
is the cosign ceremony pages, and the page says so itself: the panel carries
`data-wallet-signal-ceremony`, and `wallet_signal.js` reads it off the DOM. A
fourth ceremony surface gets the behaviour by rendering the panel — no list to
widen, the same "count the blocks, not the call sites" rule `docs/AUTH.md`
already asks of this ceremony.

**Why it matters, measured.** `require_admin` is `logged_in? && admin?` with no
session-mode requirement, and `cosign.js` has no session-mode gate, so an admin
who signed in by magic link reaches all three treasury surfaces and can co-sign
there — while the `wallet-changed` card cannot see them at all (`init` returns
early unless `SessionContext#mode` is `web3`). Gating the vocabulary on `web3`
gave that admin `web2` / "Managed wallet" / muted whether Phantom sat on a
declared signer or a stranger's, on a panel headed "Co-signing wallet", with the
stranger's address printed above their own. Silence would have been safer than
that; it read as "checked, and content".

**Two label sets, one state machine.** The states are identical for both
populations; only the words change (`WALLET_SIGNAL_LABELS.wallet` vs
`.other`). The wallet-authenticated reader gets "Different wallet connected";
the other gets "Not declared for this ceremony", plus a session row labelled
**Account wallet** rather than Session wallet and a sentence saying this session
never proved that address. Both label sets are asserted complete over every
state, because a state worded only for one of them renders a blank chip for the
other.

**`unknown` and `none` never collapse.** A page that cannot yet tell must not render as "you have no wallet" — the same unread-vs-absent distinction that was argued twice on `/admin/authorities`. Pinned by a named assertion in `test/lib/wallet_signal_js_test.rb`.

**The pre-auth state is the point, not an edge case.** The navbar renders on signed-out pages, so the context has to resolve before any connection exists, without throwing and without a flash of wrong state. The chip is *quiet* (mounted, `x-show` false) when there is nothing to say — signed out or managed, with no wallet in view — and `data-wallet-signal-state` still carries the answer either way. Quiet is not absent.

**The panel locks on the quiet-listed STATE, and that is a second lock rather than the first.** `guest`'s label is "Not signed in", a sentence that must never reach an authenticated admin. The derivation keeps `guest` and `web2` off a ceremony page altogether, so the panel cannot reach that state — but if the ceremony flag ever fails to read, the panel degrades to *hidden* rather than to a confident grey dot over two different addresses.

**It gated on the `quiet` FIELD for a day, and that could not deliver the claim.** `quiet` is the chip's question — *is there anything worth painting* — so it also requires **no connected address**; a connected address is the only way two different addresses can be on screen at once. The lock was therefore armed for exactly the case that had nothing to degrade from: measured with the flag unread and a stranger's wallet connected, `quiet` was **false**, the panel was **visible**, and it rendered Connected:*stranger* above Account wallet:*their own* under a muted grey dot — the rendering the first review bounced. The panel now reads `quietState` (the same list, without the address clause) and the chip keeps `quiet`. It costs nothing on a page that reads its flag: with `ceremony=true` the reachable states are exactly `changed`, `expected`, `live`, `disconnected`, `none` and `unknown`, and not one of them is quiet-listed — enumerated under node in `test/lib/wallet_signal_js_test.rb`.

### Which provider it watches

**The wallet the SESSION named, else the injected one.** `hostProvider()` asks
`walletProvider.get(<the session's brand>)` and binds what comes back;
`solana_stores`' `_preferredProvider` resolves the same named half, so the signal
and the wallet watcher hold the identical object and cannot describe two
different wallets.

**It used to bind the injected wallet every time, and that told a real
population they had none.** The branch tested `entry.detect()` on what `get()`
returns — but `detect` is a method on the *registry*, not on any provider, so the
typeof test was always false and every call fell through to
`(window.phantom && window.phantom.solana) || window.solana`. A Solflare- or
Backpack-brand admin registers through Wallet Standard and injects nothing at
`window.solana`: measured on `/admin/pending_transactions`, gem status `none`,
panel state `none`, **"No wallet in this browser"** over a wallet the registry
was holding an adapter for the whole time. Found as REVIEW NOTE 6 by Carl on
`ceremony-page-lacks-wallet-signal`; fixed by `bind-wallet-signal-through-registry`.

**`detect()` is deliberately left out, so only the NAMED half is taken.** It
answers a different question — *pick something for a call site that cannot ask
the user* — and both of its fallbacks are wrong for a page-level reading:

| `detect()` falls back to | What binding it would do |
|---|---|
| `SolanaStudio.redirectProvider.forWallet('phantom')`, on a phone | No `publicKey` and no `on` at all, so the gem settles `disconnected` — tone **warning**. Every mobile page on a web3 session would trade a muted "No wallet in this browser", the honest answer where no extension can exist, for a standing amber alarm that never clears. |
| `KeypairProvider`, in the e2e and bot lanes | Deaf — see below. |

**A deaf provider is never bound.** A provider whose `on()` registers nothing
cannot report a switch, so binding one produces the single failure this component
exists to prevent: **a page that reads calm while the wallet moves underneath
it.** `KeypairProvider.on` is `function() {}`, and no reflection can tell that
from a real channel. So the deaf ones are named in `SIGNAL_DEAF_PROVIDERS`, and
the list is *enforced* rather than trusted — `test/lib/wallet_signal_js_test.rb`
drives `on()` on every provider `get()` can return against a fixture whose every
downstream channel is a spy, and demands that a provider registering with none of
them appear on the list. It fails **closed**: a provider forwarding to a channel
the fixture does not know reads as deaf, and the remedy is to list it or to teach
the fixture.

Measured with the deaf provider bound, on a real page: the injected wallet moved
to a stranger and the panel stayed `live`. With the name on the list it reads
`changed`. Both are pinned.

**The name is not the only defence today, and it is written down because the
other one is invisible from the JS.** `get('keypair')` is unreachable from this
call site: the brand comes from `Solana::CurrentWallet` or
`User#web3_wallet_provider`, both of which store only what
`Solana::WalletProvider.normalize` accepts, and that registry holds `phantom`,
`solflare` and `backpack`. Adding `keypair` to it — for a bot lane, say — is a
one-line Ruby change that would silently make this page deaf, which is why the
guard lives beside the consequence. A keypair sign-in therefore arrives with a
**blank** brand and reads the injected wallet exactly as it always did; the e2e
keypair lanes are byte-for-byte unchanged by the binding (35 specs, green either
side).

### Two variants, one state

Both read `$store.walletSignal`, so the navbar and a ceremony panel can never disagree about which wallet the browser holds.

| Variant | Where | Shape |
|---|---|---|
| `:chip` (default) | Navbar, beside the geo badge, in both rows | Dot + short address, or the state's own words when there is no address |
| `:panel` | The three cosign ceremony surfaces | Heading, dot + label, connected address, session wallet row, and a sentence per state that needs one |

### The ceremony distinction, and the hold this app does NOT take

`/admin/pending_transactions`, `/admin/vault_state` and `/admin/authorities` all suppress the non-dismissible `wallet-changed` card (PR 720), because a treasury cosign walks the operator through the vault's signers on purpose and a card over a half-collected transaction strands it. Two of the three carry their own cosign script; **`/admin/authorities` reaches the same suppression through the global `cosignTransaction`, and nothing on that page says so.** A signal built for the two obvious ones leaves the console that rewrites the vault's signer set bare.

The suppression is **address-scoped**: `$store.wallet.expectedSwitchAddresses` lists the exact wallets the flow declared, and `_notifySwitch` exempts only those. The signal reads the same list, so the page and the card never disagree about **which switch was asked for**.

**They do not run on the same clock, and reading that promise as more than it says cost a false alarm on a treasury page.** The card is raised by a switch EVENT and then latches until the operator resolves it; the panel is a LIVE reading that re-derives whenever any fact under it moves — including facts that move with no wallet event at all. The property that actually holds, for the web3 session that is the only population the card can reach at all, is `panel == changed` ⇔ `card is up` — measured across BOTH modules from one event sequence in `test/lib/wallet_signal_card_agreement_test.rb`, which also names the one sequence it does not cover (a declaration made while the card is already up, which the non-dismissible card makes unreachable).

**`StudioSession.expectChange("wallet")` is deliberately never called.** The engine's holds are per SOURCE, not per ADDRESS (solana-studio's README says so in as many words), so a hold taken for a ceremony would mark a switch to *any* wallet expected for as long as it was held — including one nobody declared, silently. The consequence of not holding is that the engine still reports a declared ceremony switch as a mismatch. That is a NOISY failure rather than a silent one, which is the safe direction, and turf's own address-scoped reading is the one the reader sees.

Guarded in `test/lib/cosign_signatures_js_test.rb` (the `expectChange` refusal, and a SCAN — not a hardcoded file list — for every flow that declares a suppression), and exercised on a real page in `e2e/wallet_signal_ceremony.spec.js`.

### The declaration a ceremony leaves behind

**After every SUCCESSFUL ceremony the panel used to turn red and say something false, and this is the fix.** `cosign.js` clears the declared list in its `finally`, which runs the moment `collect()` returns — while Phantom is still parked on the signer it just used. The suppression MUST end there (one that outlives its flow disarms the guard for the whole page, silently and for every wallet), so the clear is correct. What was wrong was this panel: reading the list live, it re-derived `expected`/info into `changed`/**danger** with no wallet event behind it, and told the operator *"No ceremony on this page asked for this wallet"* seconds after one had. The hand-off card, correctly, stayed down — so the two disagreed. Shipped to production 2026-09-17, found in review by Jasper and Carl, fixed by `/tasks/ceremony-end-flashes-false-alarm`.

`deriveWalletSignal()` now takes one more fact — `rememberedDeclaration`, an address — and `rememberDeclaration(previous, facts)` advances it as a pure rule:

| Now | The memory | Why |
|---|---|---|
| No wallet in view | forgotten | A lock or disconnect re-enters through `_handleAccountChanged`, which raises the card on the way in. |
| A live list names the connected wallet | remembered | The ordinary mid-ceremony case. |
| A live list names someone ELSE | forgotten | A second ceremony is the authority while it runs, and its signer is the one to switch to. |
| No list, wallet unmoved | **kept** | Nothing happened. `expected` stands and the panel says the ceremony has *finished* with this wallet. |
| No list, wallet moved | forgotten | The suppression ended with the flow, so leaving and returning is a switch the card raises. |

**`expected` rather than a ninth state.** Its words are already past tense ("Declared for this ceremony"), the fact they assert is still true, and a state the card has no counterpart for is a state the two can drift on. Only the SENTENCE changes: `declarationEnded` swaps the mid-ceremony line for *"The ceremony that asked for this wallet has finished with it…"*, which is the clause the old rendering denied.

**The memory is scoped to the path that declared it.** It survives a Turbo visit to the SAME path, because that is the visit the operator makes — the success card closes with a link to `window.location.pathname`, this module survives it, and `solana_stores`' `watching` guard means its `init` does not re-run and cannot re-raise the card. A memory cleared on `turbo:load` would hand the false alarm straight back the moment the receipt is dismissed. It dies on the way anywhere else, where "this page asked for this wallet" would be a claim about a page the reader has left.

### No refresh on a switch, and the reason is measured

This component used to call `refreshSession()` on every change of the connected
address, under a paragraph claiming a switch left the balance pill, the
`data-wallet-tile` tiles, the seeds bar and the token badge showing another
wallet's values. **That paragraph was wrong**, and a wrong reason is worse than
no call because the next author reasons from it.

`AccountsController#session_refresh` takes **no parameters** and reads the
browser nowhere: it hydrates from `current_user&.solana_connected?` through
`fetch_navbar_hydrate(current_user)`, so every number it returns is keyed to the
server's idea of the account. A browser wallet switch cannot stale one of them.
The call repainted identical values while spending several blocking Solana RPC
reads each time — about three per three-signer ceremony, on the page least able
to afford a stall.

The call and the paragraph are both gone, and `test/lib/wallet_signal_js_test.rb`
asserts `refreshes == 0` so it cannot come back under a fresh wrong reason. What
a switch *does* change is which wallet will sign, and that is what the signal
renders. If some wallet-derived value is ever made to follow the browser,
refresh it then — and name the value.

### Wiring

| Piece | Where |
|---|---|
| `solana_studio/wallet_identity.js` | `layouts/application.html.erb`, sprockets tag beside the other solana-studio assets. A blocking classic script in `<head>` always precedes a deferred importmap module, which is why the registration below can assume it. |
| `wallet_signal` | `config/importmap.rb` + `app/javascript/application.js`, **after** `solana_stores` (it reads `$store.wallet`) and after `solana_utils` (it calls `window.refreshSession`). |
| Server binding | `ApplicationController#studio_session_identities` returns `{ wallet: current_user&.solana_address }` for a live-signature session and `{}` otherwise. The key must be `wallet` — the engine matches an identity source by NAME. |
| Session stamp | The engine's `studio/_session_stamp`, already rendered by `layouts/studio/head`. Its `identities` carries the binding; the fingerprint includes it, so re-binding reaches other tabs. |

**`config.draw_session_routes` is deliberately left off.** The engine's `GET /session/state` would inherit this app's `ApplicationController` filters, and this app already has `/account/session_state` (identity) and `/account/session_refresh` (on-chain values) covering both halves. Without the route the stamp still renders and drift is still detected; the engine simply cannot repair a page in place, and `_reauth` reloads the page on success anyway.

### Colour rules this component obeys

- **Tone is a dot, not coloured prose.** Body text has to clear WCAG AA on both themes and a vivid fill cannot, so the fill goes in a dot (no contrast duty) and the label stays on theme ink. Same label-plus-dot pattern as the Live Board State Badge.
- **The one danger exception sits on a theme surface.** `text-danger-ink` is derived against the four theme surfaces; composited over a red wash it measures 4.25:1 and fails. So the `changed` state is `text-danger-ink` over `bg-surface-alt` with a red **border** for the affordance — never `bg-red-500/10`. Asserted in `test/views/wallet_signal_component_test.rb` and measured by `test/views/error_text_contrast_test.rb`.
- **Every tone class is a literal string** in the partial's `:class` map. Tailwind scans source TEXT; a class assembled at render time compiles to nothing.

### Tests

| File | Tier | Covers |
|---|---|---|
| `test/lib/wallet_signal_js_test.rb` | `[unit]` + `[component]` | The derivation over every population — including the **email-authenticated admin on a ceremony page**, enumerated by name the way `unknown` vs `none` is — and the indicator driven through the REAL solana-studio identity source under node, for both session modes, including an undeclared switch mid-ceremony. Also: the `rememberDeclaration` rule case by case, *completing a ceremony leaves the panel calm*, the quiet lock measured on the module rather than on an attribute, and no `session_refresh` fires. |
| `test/views/wallet_signal_component_test.rb` | `[component]` | Both variants mount; every Alpine expression survives ERB whole; danger ink on a theme surface; the panel declares the ceremony and locks on `quietState` while the chip keeps `quiet`; the finished-ceremony sentence and the alarm are gated on opposite sides of one fact; the undeclared note and the session row each speak differently to a session that proved no wallet |
| `test/lib/wallet_signal_card_agreement_test.rb` | `[component]` | **The seam.** Both app modules plus the gem source, driven from ONE event sequence, asserting `panel == changed` ⇔ `card is up` at every step — including the step where the declared list empties under an unmoved wallet |
| `test/integration/wallet_signal_surfaces_test.rb` | `[integration]` | The three ceremony pages and the navbar (signed in AND out); the assets ship; what the server binds for web3 / email / anonymous sessions |
| `e2e/wallet_signal_ceremony.spec.js` | `[e2e]` | The screen, on `/admin/pending_transactions`, through the whole switch sequence |

**Why the markup tier cannot grep for the stray quote.** One double quote in an `x-data`/`x-bind` attribute ends the attribute, truncates the expression, and kills every binding in the component — while the server-rendered markup stays byte-identical. Nokogiri, like Chrome, ENDS the attribute at the quote, so the value handed back is short and perfectly clean and the quote is not in it to find. What a truncation always leaves is a severed expression, so the guard asserts balanced brackets and string quotes and no dangling operator, on every Alpine attribute found by walking the elements rather than by naming them. Verified by mutation: inserting one quote turns two tests red.

## Theme Toggle Morph (Spinner Swap)

`components/_theme_toggle_morph.html.erb` (engine partial) — dark mode toggle and loading spinner share the same 16x16 space. Two absolutely-positioned elements with `transition-all duration-300` cross-fade via `transform: scale() rotate()` + `opacity`.

- **Default state**: Toggle visible (`scale(1) rotate(0deg) opacity(1)`), spinner hidden (`scale(0) rotate(-90deg) opacity(0)`)
- **Loading state**: Toggle hidden, spinner visible — triggered by `showNavSpinner()` global function
- **After loading**: Spinner hides, toggle returns — triggered by `hideNavSpinner()` with 2.5s minimum display time

**Global JS** (in engine `_head.html.erb`): `showNavSpinner()` records `Date.now()`, `hideNavSpinner()` calculates remaining time from the 2.5s minimum and uses `setTimeout` to delay the hide. Both target `.nav-toggle-icon` and `.nav-spinner-icon` class elements.

**Usage**: Gear sidebar "Refresh Wallet" calls `showNavSpinner(); refreshSession().finally(function() { hideNavSpinner(); })` (refreshSession is the full navbar hydrate — balance + tokens + seeds + wallet tiles). Auto-refresh on devnet uses the same pattern.

## Leaderboard (Contest Show)
Selection badges are fixed-width (`w-28`), sorted by game kickoff time, showing turf score (e.g., `x3`) before game completes and points (goals x turf score) after. Badges float right with score rightmost (`min-width: 4.5rem`). Non-integer values show decimal portion in smaller font. Payout label (`$40.00`) appears on left (after player name) only before settling. Admin payout button says "Payout $X". After settling — paid rows get primary ring, divider line after last paid position, unpaid rows dimmed. Rank column shows actual rank (from entry.rank) when settled.

## Faucet Page (`/faucet`)
Public marketing page with hero, "How It Works" cards, and USDC claim form. Mints SPL USDC tokens directly to user's Phantom wallet via `Vault#mint_spl(to: wallet)`. Three view states: wallet connected (amount picker + claim), logged in no wallet (connect CTA), logged out (login/signup CTAs). Preset amounts $10/$50/$100/$500, custom input $1-$500.

## Modal Host (studio-engine v0.4.5+)

Modal lifecycle is owned by the studio-engine modal host — `Alpine.store('modals')` — a stack-based store provided by the engine's `studio/modals/_host.html.erb` partial. Local app code consumes the store; do not reimplement.

**This app no longer forks the host** (2026-08-28, `defork-turf-modal-host`). It used to:
studio-engine is **non-isolated**, so an app view at the same path wins the lookup, and this
app shipped its own `app/views/studio/modals/_host.html.erb` — 518 lines that rendered the
same markup as the engine's while quietly falling behind its focus and stale-entry guards.
A gem bump delivered no host fix at all, and nothing on a page could tell the two apart.
That file is deleted. The engine's host renders, and a gem bump now reaches it.

**Prove which host renders by RESOLUTION, never by path.** Both files lived at the same
virtual path, so a `File.read` of a fixed path answers a different question than it appears
to — which is exactly how the duplication survived. Ask the resolver:

```ruby
ApplicationController.new.lookup_context.find("host", ["studio/modals"], true).identifier
```

Assert it does **not** start with `Rails.root.join("app/views")`. Do **not** assert it
contains `/gems/`: that encodes how the engine happens to be installed here and can never
pass in studio-engine's own consumer-CI lane, which bundles the engine as a path checkout.
`test/support/resolved_modal_host.rb` wraps this; `test/views/modal_host_adoption_test.rb`
pins it, and `test/integration/modal_host_focus_contract_test.rb` reads the RESOLVED host
so the focus contract stays asserted against whatever a page actually gets. Two things
re-open the gap silently: a re-fork re-creates the shadow, and the studio-engine pin admits
a RANGE, so a resolve inside it can carry a host that predates the fix.

The pin's version is deliberately **not** written here. PR #581 deleted the `~> 0.64` this
line used to name — but the argument never turned on WHICH release the pin names, only on
the fact that it admits a range at all. The current floor lives in the `Gemfile` and in
`test/lib/engine_pin_contract_test.rb`, which assert each other; a third copy here would
only be a third statement to go stale.

**Two consumer seams, so nothing has to fork this file again** (studio-engine 0.65.0):

| Seam | Where it lives here | What it carries |
|---|---|---|
| `window.StudioModals.CARD_WIDTHS` | `app/views/shared/_modal_card_widths.html.erb` | per-modal card width by id (`wallet-setup` → `max-w-md`) |
| `modals/_host_extras` | `app/views/modals/_host_extras.html.erb` | app-wide modal registrations (`cosign-rejected`) |

The width partial **must render ABOVE the host** in every layout that mounts it — the host
merges the map at the top of its own inline script, so a registration that arrives later is
read by nobody and every card silently falls back to `max-w-sm`. A layout that mounts the
host without it fails `modal_host_adoption_test.rb`.

The `ModalAnimations` registry (`pop` / `shake` / `slide`, and the keyframes behind them) is
engine-owned too, and consumer entries merge OVER the engine defaults the same way. This
app registers none — its fork's registry was byte-identical to the engine's defaults, which
is why adopting the host changed no animation.

**Opening / closing**:

```js
$store.modals.open('id', { props })   // push { id, props } onto stack, lock body scroll
$store.modals.close()                  // pop the top modal
$store.modals.closeAll()               // empty the stack
$store.modals.current()                // top modal { id, props } or null
$store.modals.isOpen('id')             // membership check
```

The stack is LIFO — multiple modals can be open simultaneously and render as a Z-indexed stack. Each modal's `props` persists across re-renders, perfect for multi-step flows (tokens → confirm → success).

**Dismissibility**: Modals are dismissible by default (Escape + click outside). For on-chain TX flows, set `dismissible: false` on the props so an accidental click can't orphan a signed-but-unconfirmed transaction. Close only via `$store.modals.close()`.

**Defining a new modal partial**: mount it inside `<template x-if="$store.modals.current().id === 'your-id'">`, then pick where it is REGISTERED:

- **Belongs to a page or a call site** (needs `logged_in?`, a feature flag, or helper-computed locals) — register it in the layout block in `app/views/layouts/application.html.erb`.
- **Belongs to the APP** (no locals, no per-layout gating) — put it in `app/views/modals/_host_extras.html.erb` instead. The engine host renders that partial inside the card on every path through it, so one entry covers every layout that mounts the host and cannot drift. `cosign-rejected` is the current occupant.

**There used to be TWO layout lists, and the second is why that distinction exists.** `app/views/layouts/modal_preview.html.erb` kept its own registration block for `/admin/modals/preview`, so a card added to one list and not the other rendered EMPTY in the other — a working modal with nothing in it, which reads as a styling bug and gets ignored rather than reported. It cost the age-verify card months, and six cards at once. `/tasks/retire-the-preview-harness` deleted that layout on 2026-09-09; `layouts/application` is the only mount left, and keeping it the only one is the cheapest way to keep that failure retired. If you ever add a second, `app/views/modals/_host_extras.html.erb` and the locals helpers (`WalletPickerHelper`, `Web3StepUpHelper`, `BirthdayModalHelper`, `OnboardingHelper#first_name_modal_locals`) are already the seams that stop a card forking across it.

The layout list is long; grep it for `store.modals.current` to find where it starts. (Deliberately no line numbers or counts here — this section previously pointed at a partial that had not existed for months, and precise-but-rotting coordinates are how that happens.) Note that a test scanning the LAYOUT's source for a registration cannot see a `_host_extras` one — `test/controllers/onboarding_gallery_test.rb` reads the RENDERED page for exactly that reason, so prefer a render assertion over a source scan when you add one.

**Reviewing a modal**: turf cards its own modals in its section of the living style guide, `/admin/style#host-modals` (`app/views/style/host/_modals.html.erb`), against the real partials on the real layout. **Critical: single root element** — sibling `<style>` / `<script>` / structural tags are silently dropped during parsing (see § Alpine + ERB Constraints below).

**Recovery**: The host auto-clears the stack on browser back navigation (bfcache `pageshow`) and Turbo navigation (`turbo:before-cache`). No app-side recovery code needed.

**Slow-op smoothing**: `window.StudioModals.holdAtLeast(minMs)` returns a thenable enforcing a minimum spinner duration — pair with the processing card so the spinner doesn't flash past the user on fast operations.

> The old `Alpine.store('solanaModal')` is now a thin compatibility proxy over `$store.modals`. New code should call `$store.modals` directly. `fireSuccessConfetti()` still lives in `solana_utils.js` (the old "in wallet_connect" claim was always wrong).

**One `onchain-tx` card per flow, and `show()` is what keeps it that way.** Every
write the proxy makes — `success()`, `error()`, and all fifteen field setters —
resolves through `current()`, so it reaches only the card on TOP. But `show()` is
how the proxy spells a STEP TRANSITION, not a new dialog: one contest entry calls
it three times (Preparing Transaction, Sign Transaction, Confirming Onchain),
contest create six, `lock_contest.js` six. `$store.modals.open()` PUSHES, so each
of those flows used to leave a tower of `onchain-tx` cards of which only the last
was ever advanced. The buried ones kept `state: 'processing'` and
`dismissible: false` for the life of the page, invisible — the host renders only
`current()` — until something landed on top and was dismissed. That is how
closing the level-up celebration came to reveal "Approve your free entry in your
wallet..." for a transaction that had settled seconds earlier
(`level-up-reveals-stale-modal`). `show()` now reuses the live `onchain-tx` entry
and pushes only when there is none, so `success()` is always pointed at the only
card there is. It patches the entry's props in place rather than going through
`swap()` / `advance()` on purpose: both defer the new props by one animation
frame, and a `success()` arriving inside that window would be overwritten by
processing props landing late. Guarded by `e2e/level_up_stacked_modal.spec.js`,
which asserts the stack itself — the DOM cannot show you a buried card.

## Auth Modal — 8-step state machine

`/modals/_auth.html.erb` is a single Alpine component that branches on an 8-step state machine. State lives on `$store.modals.current().props.step`, mutated by the board's `selectionBoard` component.

**Step sequence + transitions**:

1. **credentials** — initial state. Phantom + Google + magic-link email form. Local validation. Submits via `$dispatch('auth-*-submit')` / `$dispatch('auth-*-click')`.
2. **tokens-picker** — Stripe pack grid (via `_tokens.html.erb`). Click opens Stripe Checkout in a new tab. Sets step → `tokens-waiting`.
3. **tokens-waiting** — Spinner + "Finish checkout in the new tab" message. No countdown; user returns manually.
4. **tokens-confirming** — Processing card (spinner + "Confirming…"). Waits for the polling loop on `/tokens/status` to mark the purchase `minted`.
5. **tokens-minted** — Success card: "Entry Token Minted" + balance display + in-modal Hold-to-Confirm button. The hold fires `'hold-confirm-entry'`; the board's listener detects auth-modal context and stays in the modal → step `tokens-submitted`.
6. **tokens-submitted** — `entry_confirmed` card (seeds bar + explorer link + leaderboard CTA). Auto-redirects to the contest or fallback.
7. **tokens-error** — Poll timed out or entry submission failed. Error card with "Refresh" button.
8. **redirect** — geo-blocked only. `showRedirectModal` is this step's one opener and the board's `runHoldValidations` geo pre-check is its one caller, so the CTA is always "Location Restricted" → `/`. Not-logged-in and funds blockers open their own modals and never reach this step (see § Redirect Modal). The 5s drain belongs to `studio/modals/blocks/cta_redirect`; the board's `setInterval` + `props.countdown` loop is retired.

**Stripe integration**: Pack cards trigger `POST /tokens/stripe_checkout` → opens checkout in a new tab → buyer returns to `/tokens/processing?session_id=…` → page polls `GET /tokens/status` every 500ms until `ready: true`. Backend: webhook → `TokenPurchaseJob` → mints incrementally via `Vault#mint_entry_token`. Job is idempotent — tracks `already_minted` count, resumes from the next index on retry. See § Entry Tokens (Web2) below.

**In-modal hold-to-confirm**: The button in the `tokens-minted` step dispatches `'hold-confirm-entry'`. The board's listener routes confirmation through `ContestsController#enter` with the token path (consumes one token via `Vault#enter_contest_with_token` — no USDC charge). On success the modal stays open and swaps to `tokens-submitted`.

## Real-time Chat (ActionCable)

Contest chat ships in `_chat_panel.html.erb` with **Turbo Streams over ActionCable**. The panel establishes a per-contest subscription via `<%= turbo_stream_from contest, :messages %>`. Posts and deletions broadcast directly from the `Message` model.

**Broadcast wiring**:

```ruby
# app/models/message.rb (sketch)
after_create_commit do
  broadcast_prepend_to([contest, :messages],
    target: "contest_#{contest_id}_messages",
    partial: "messages/message",
    locals:  { message: self })
rescue => e
  ErrorLog.capture!(e)   # best-effort — never fail a committed HTTP request
end

after_update_commit :broadcast_removal, if: :saved_change_to_hidden_at?
```

**Pinned composer, newest-first stream**: Form wrapper uses `flex flex-shrink-0` to stay pinned. Messages render in a flex column with newest at top. New messages prepend and animate via `@keyframes chat-message-in` (slide + fade, 0.34s cubic-bezier(0.22, 1, 0.36, 1)). A `MutationObserver` watches for new `#message_*` nodes and applies the animation class.

**Permission gate**: Read is public. Post requires `logged_in? && contest.chat_enabled? && contest.chat_participant?(current_user)`. Server-side helpers control composer display (input vs "log in" vs "enter contest to chat"). `MessagesController#create` re-checks `chat_participant?` before persisting. Delete is admin-only.

**Admin hide buttons**: The `.chat-admin-only` CSS class is `display: none` by default; revealed only when the root `.chat-admin` class is present (added server-side via `<%= 'chat-admin' if current_user&.admin? %>`). Hide buttons fire `hideChatMessage(btn)` which `DELETE`s the message via `data-message-url`, triggering broadcast removal.

**"Live" indicator**: Radar-ping animation (`@keyframes chat-live-ping`) — a repeating scale+fade ring (1 → 2.6, opacity 0.6 → 0, 1.8s) layered behind a solid green dot.

**Quest 2 composer nudge**: While the "Send Your First Message" mission is showing (`contests/_quest_chat`), the composer answers the quest card's southwest arrow with two cues, both driven by the one `quest-chat-active` window event `questCard#_maybePingChat` dispatches — and which `focusChat()` re-dispatches on ANY click of the quest card. `contestChat#questChatActive()` pops the panel, sets `questGlow` (binds `.chat-input-glow` — a border + box-shadow pulse on the `<textarea>` itself, since a form control carries no `::before`/`::after` for the `.studio-border-glow` primitive), and starts the placeholder typewriter. The deck comes from `ContestsHelper#chat_prompt_samples`, rendered per-viewer into `data-chat-prompts` and gated on `@quest_step` (only `contests#show` sets it; `contests#live` renders no quest card, so it builds no deck). It is SEMI-STATIC: two fixed openers (`Hey everyone 👋`, `Good luck, everyone ⚔️`) then one personal line naming the viewer's longest-priced pick (`"<name> light it up <team emoji>"`, highest `turf_score` — the curve pins rank 1 at x1.0, so the biggest multiplier is the biggest swing). Two separate things keep the rested line readable, and it is worth not confusing them. The INVARIANT is CSS: `.chat-composer::placeholder` sets `white-space: nowrap; overflow: hidden; text-overflow: ellipsis`, so an over-long placeholder CLIPS to one line instead of wrapping into a 22px box built for a 20px line and being sliced through its glyphs (measured: `scrollHeight` 76 vs `clientHeight` 38). It is scoped to `::placeholder` deliberately — the same rule on the element would stop TYPED text wrapping, a real regression for a 500-character composer. The COPY BUDGET is separate and softer: `CHAT_PROMPT_NAME_BUDGET` (10) falls back to `short_name` then `CHAT_PROMPT_NO_TEAM` so real names render in full rather than clipped. Treat the character count as a weak proxy for width — the content box is 206px in Chrome on macOS but 183px on the Linux CI runner (classic scrollbar vs overlay), and length barely tracks width anyway ("Commanders", 10 chars, measures 172.1px; "United States", 13 chars, measures 173.5px). `e2e/quest_chat_prompts.spec.js` asserts the wrap invariant for every budget-surviving name plus one deliberately oversize probe, and checks width only for the line actually rendered.

The deck size IS the pass count (`CHAT_PROMPT_LIMIT`, 3): the composer types each line in turn and then RESTS on the last one instead of looping. **Rest is terminal and needs its own flag** — `_promptsRested`, not the `_promptTimer` handle, which `_promptStep()` nulls when it rests; guarding on the handle let a second `quest-chat-active` re-enter at phase `hold`, erase the rested line, walk the index off the end of the deck and leave a permanently empty placeholder. Typing steps over CODE POINTS, never string indexes — slicing mid-emoji paints a lone surrogate. The textarea carries a static `aria-label`, because a placeholder that rewrites itself cannot serve as an accessible name. Both cues retire when a message sends (`questDone()`, on any successful post — not only the seeds-earning one — and it latches `_questOver` so a later ping cannot re-arm the glow); the typewriter alone also stops on the first keystroke (`$watch('body')` → `stopPrompts()`, which does not touch the glow) and never starts under `prefers-reduced-motion`, where the halo still renders without its pulse.

**Scroll fade**: Message list container uses `-webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 2.5rem), transparent)` to soften the bottom edge.

## Entry Tokens

Entry tokens are on-chain `EntryTokenAccount` PDAs minted via Stripe Checkout. Buying tokens with a card lets a user with no USDC enter contests.

**Both wallet modes spend them** (2026-08-21). The BUY flow below is the managed/web2 one, and so is `ContestsController#enter` → `Vault#enter_contest_with_token`. The Phantom path reaches the same instruction from the other side: `#prepare_entry` builds `enter_contest_with_token` when the signing wallet holds an unconsumed token — the wallet itself signs the consume — and `#confirm_onchain_entry` cosigns and verifies against the token PDA the server recorded on the `PendingTransaction`. Before that wiring a Phantom wallet holding a token was still charged USDC, which is what made the board's "Hold for Free Entry" copy false for web3 (PR #386).

**The board CTA reads this rail.** `contests/_turf_totals_board` binds the hold button's idle label to `$store.session.tokensAvailable`: the wallet that can sign in the active session reads "Hold for Free Entry" when it holds a token; any other state reads "Hold to Confirm". Combo accounts use the managed address in web2 sessions and the Phantom address in web3 sessions, matching the server's funding choice. Both entry-success branches lower the client count through `mirrorTokenSpend()` when the server reports `token_consumed`; crash recovery invalidates the same token caches even when the entry was already activated. The CTA names the funding; the server chooses it.

**Full flow**:

1. User picks a pack in the auth modal's `tokens-picker` step.
2. `POST /tokens/stripe_checkout` creates a Stripe session (quantity / price / metadata with `user_id`, `wallet`, optional `contest` context).
3. New tab opens Stripe Checkout → buyer completes payment.
4. Stripe redirects to `/tokens/processing?session_id=…`.
5. Page polls `GET /tokens/status` every 500ms. Initial response: `{ ready: false, minted: 0, balance: X }`.
6. **Backend**: Stripe webhook → `TokenPurchaseJob.perform_later(...)`. Job mints one-by-one via `Vault#mint_entry_token`, persisting signatures to `StripePurchase.mint_tx_signatures` after each successful mint (incremental — crash recovery via resume point).
7. Once all quantities minted, `purchase.mark_minted!(signatures)` flips status → `"minted"`. `TransactionLog` records the purchase.
8. Poll detects `ready: true` → swaps the modal to `tokens-confirming` → user sees success card with balance + in-modal hold button.
9. Hold completes → `ContestsController#enter` routes to the token path → `Vault#enter_contest_with_token` consumes one token → entry confirms (seeds awarded). Modal swaps to `tokens-submitted` and auto-redirects.

**Operator claw-back — burning a token** (2026-09-06). `/admin/free_entries` pairs its Mint buttons with `Burn 1` and `Burn all N`, routed at `POST /admin/free_entries/:user_slug/burn` (`count` optional; absent burns everything unspent). The controls key off **unconsumed**, not `owed` — those point in opposite directions, so a row can offer both — and both are hidden on a cold cache for the same reason Mint is: never aim an irreversible action at an unverified count. There is deliberately **no** `burn_all` across all users to mirror `mint_all`; over-minting costs rent, over-burning destroys property for every account at once.

**The confirmed number is a ceiling.** Burn-all POSTs the *displayed* count, not a bare "burn everything". The row's `unconsumed` is cache-first (up to 60s stale, and the page never auto-refreshes), while the controller re-reads the chain live — so sending no count let it fall through to the live figure, and a token minted between render and click (level-up sweep, a completed `TokenPurchaseJob`, another admin's "Mint All Owed") was destroyed by an operator who agreed to a smaller number. With the count sent, `count.clamp(0, burnable.length)` makes the confirmed figure a maximum: burn everything you saw, never more, and fewer if some were spent meanwhile. Both burn buttons are `btn-danger` — `--color-cta` and `--color-success` resolve to the same green, so `btn-outline` here was indistinguishable from the benign "Act as" and, on hover, from "Mint".

**It inherits the page's wallet blindness.** `User#solana_address` is `web3 || web2`, so for a combo account only the Phantom wallet's tokens are counted and burnable — a web2-owned token is neither shown nor clawed back. Mint already had this and the burn exposure is no wider, but a claw-back workflow that silently misses half a combo user's tokens is worth knowing before you promise someone their balance is cleared.

The on-chain half is `turf-vault`'s new `burn_entry_token` (1-of-3 vault signer; the holder does **not** sign, because a claw-back is aimed exactly at a holder who will not surrender the token). Two design points are load-bearing and easy to get wrong:

- **It tombstones, it does not close.** `owed` is `(seeds / SEEDS_PER_LEVEL) - tokens.length`, read off the chain here *and* in `Tokens::LevelUpGrant#missing_levels`. Closing the PDA would drop `tokens.length`, so a burned token would re-read as owed and be re-minted by the page's own `Mint all` or the next level-up sweep — the burn would undo itself. The account survives (rent is not refunded); that is the price of a burn that sticks.
- **The tombstone rides in the spare high bit of `source`** (`ENTRY_TOKEN_BURNED_FLAG = 0x80`), not in a new field. `EntryTokenAccount` is 124 bytes and fully packed; growing the struct would break `Account<EntryTokenAccount>` deserialization for every token minted before the upgrade, taking `enter_contest_with_token` down with it for those holders. A burn sets `consumed = true` (which is what actually blocks the spend, reusing the constraint that instruction already carried) **and** the flag (which is what tells a claw-back apart from a genuine redemption). `Vault#decode_entry_token` splits the byte once — `source` is masked, `burned` is a new key — so no caller sees the raw value.

**Job idempotency**: `TokenPurchaseJob` short-circuits if `status == "minted"` (already done). On retry it calculates `already_minted` from the persisted signature count and loops from there — exactly-once per token even with mid-job crashes.

**Navbar badge**: free-entry tokens are surfaced by the ✨ badge tucked into the profile avatar's upper-left corner in `_user_nav` (`[data-free-entry-badge]`, count in `data-token-count`, toggled by `updateNavTokens`). It is absolutely positioned, so it costs the row no width whether or not the user holds a token. When the combined USDC+USDT balance is $0 AND the user has tokens, the balance slot (`[data-balance-slot]`) swaps its `$X` amount for the "✨ Free Entry" label (`[data-free-entry-label]`, `.is-active`) rather than hiding the balance — one rule, `applyBalanceSlotRule()` in `solana_utils.js`, shared by the server render, `refreshBalance`, and `updateNavTokens`, so the two halves cannot drift. Hovering or focusing the badge peeks that same label over the amount (`.fe-peek`, driven by `freeEntryHover` in the `_user_nav` Alpine scope); a level-up glows the badge (`.free-entry-glow`, armed by `window.armFreeEntryGlow`).

**Badge paint**: the disc wears `.legendary-badge` — the house legendary treatment (a gradient far wider than the element, panned under it, white rim, warm bloom), built like the engine's `.level-badge-10` but in the app's own primary + warning rather than a fixed 8-stop rainbow. It is PAINT ONLY: the caller brings width, radius and font-size, and `--lb-a` / `--lb-b` / `--lb-contact` are knobs. `--lb-contact` is the dark contact shadow the disc casts onto the avatar it overlaps, set by `.free-entry-badge.legendary-badge` — a compound (0,2,0) that out-ranks the treatment's own transparent default wherever it sits. It began as a bare `.free-entry-badge` rule ABOVE the treatment, which ties `.legendary-badge` on specificity and loses on source order, so the shadow resolved to nothing while the stylesheet still read correct. POSITION is what fixed it; the compound is what keeps it fixed through a reorder. Both halves are pinned by `test/views/entry_token_badge_placement_test.rb`.

**Badge click**: opens the settings sidebar (`$store.sidebars.gearOpen`) — the same target the avatar and username toggle. It does NOT pop a menu of its own. The count it once showed in a short-lived popover now lives in the sidebar the click opens: `components/_gear_sidebar` renders a `[data-free-entry-chip]` pill in the same `.legendary-badge` treatment, reading "✨ N Free Entr{y,ies}". That chip mounts TWICE — the sidebar body renders into both the desktop and the mobile panel — so it stays live through the `entry-tokens-updated` window event (the `entryTokenBadge` factory) rather than a `querySelector` sync, which would update one panel and strand the other. It hides at zero, with `display:none` pre-set server-side so there is no pre-Alpine flash.

The markup halves of those three ARE assertable from the response bytes, and `test/views/entry_token_badge_placement_test.rb` asserts them — the chip in both mounts, its server-set `display:none`, the knob below the treatment. What no string can see is the paint and the timing, so `e2e/entry_badge_sidebar.spec.js` guards those in a browser: it asserts the shadow by neutralising `--lb-contact` and watching the PIXELS move (freezing the gradient pan with `emulateMedia` first — belt-and-braces now that `playwright.config` sets `reducedMotion` through `contextOptions`, and kept because this spec's whole result rests on the disc being still), the panel still open a beat after the click, and the chip following the count across both mounts.

## State Fanout Pattern

`app/javascript/state_fanout.js` is the standardized bridge from a server-confirmed state change to client UI catch-up. Controllers and inline Alpine handlers should call:

```js
window.StateFanout.apply(stateType, payload, opts)
```

A handler owns three things for its state type:

1. Durable client cache updates, usually `localStorage`, when the next page render needs the value.
2. Window events for long-lived Alpine components that should animate without a page reload.
3. Structured console logging with a `source` label so Sentry breadcrumbs and replay tools can connect the server action to the UI update.

Registered handlers:

| State type | Payload | Effect |
|---|---|---|
| `seeds` | `{ seeds_earned, seeds_total, seeds_level? }` | Updates `seedsNavbar`, records `seedsLevelUp` when the user crosses a level, and dispatches `navbar-seeds-update`. |
| `cdp_ramp` | `{ direction, status, partner_user_ref, tx_hash?, sent_signature? }` | Refreshes the navbar balance for moved funds and dispatches `cdp-ramp-update`. |

When adding a state type, write one handler with `register(stateType, handler)` and keep all call sites on `window.StateFanout.apply(...)`. Pass constants such as `seedsPerLevel` through `opts`; do not hardcode model constants in client code.

## $store.session — wallet-mode pattern

Session state (guest / web2 / web3) is the canonical source of truth for what the user can do. **Always branch on `$store.session.mode === 'web3'`** — never on legacy `cfg.onchain_session`, never on `phantom_linked` alone.

**Server-side**: `ApplicationController#wallet_context` builds a `SessionContext` (PORO at `app/models/session_context.rb`) from `current_user` + `@onchain_session` flag (true when the user authenticated via a live Phantom signature *this session* — separate from account-level `phantom_linked?`). Serialized to a JSON block on every page:

```erb
<script type="application/json" id="session-context">
  <%= session_context.to_h.to_json.html_safe %>
</script>
```

**Client-side**: Alpine registers the store on `alpine:init` by parsing `#session-context`. Re-seeded on every Turbo load:

```js
Alpine.store('session', JSON.parse(document.getElementById('session-context').textContent))
```

Store shape (camelCase): `{ loggedIn, mode, phantomLinked, userId, address }`.

**Modes**:

- **`:guest`** — not logged in. Use `$store.session.loggedIn === false` to gate (login button visibility, etc.).
- **`:web2`** — logged in via email/Google OR Phantom-linked account that re-auth'd via email this session. CANNOT sign on-chain TXs. Stripe / faucet OK; Solana TX buttons disabled.
- **`:web3`** — logged in AND authenticated via a fresh Phantom signature. CAN sign on-chain TXs (contest creation, treasury cosigns, on-chain entry).

UI branching example:

```html
<button x-show="$store.session.mode === 'web3'" @click="signTx()">Sign on-chain</button>
<a     x-show="!$store.session.loggedIn"        href="/signin">Log in</a>
<div   x-show="$store.session.mode === 'web2'">Connect Phantom to sign</div>
```

## Landing Pages (funnel + referral attribution)

Landing pages are `LandingPage` records (name, headline, subheadline, badge, cta_label, background_style, contest_id, slug, active). Rendered at `/lp/:slug` by `LandingPagesController#show`. Page sections:

1. Hero — brand logo + two-tone "Turf Totals" title (split-color rendering).
2. Badge — optional `lp-badge` span (violet/20 background).
3. Contest snapshot card — entry fee / guaranteed prizes / entries count / lock time / CTA → `/contests/:id`.
4. "How it Works" — 4 numbered steps from `funnel_how_it_works(@contest)` helper, format-specific (Turf Totals vs World Cup Survivor copy).
5. Footer — context-aware ("See how it works" vs "Help Center").

**Background variants**: `background_partial` returns one of three animated partials (gradient / blobs / circles) based on `background_style` enum. Each is pure CSS — no JS.

**Referral capture (`?ref=` + cookies)**: `ApplicationController#capture_reference` runs before every action and writes `?reference=` into `cookies[:reference]` (30-day, first-touch wins). On signup, `RegistrationsController#create` mirrors the cookie to `user.reference`. `LandingPagesController#show` ALSO sets the cookie to the landing page's slug if empty (landing page as referrer). `LandingPage#signup_count` returns `User.where(reference: slug).count` for analytics.

**`/account/set_inviter`**: After signup, JS `POST /account/set_inviter?inviter_slug=…` (inviter's slug from landing context). `AccountsController#set_inviter` atomically sets `invited_by_id` (idempotent — 200 if already set). Builds the referral chain for leaderboard attribution.

## Alpine + ERB Constraints (critical — silent failures)

These are gotchas that produce **silent no-ops or phantom DOM** rather than errors. Every UI-touching change must respect them. Keep this neutral doc as the app-level source of truth; mirror cross-app lessons into McRitchie Studio's agent docs when they apply beyond Turf Monster.

1. **`<template x-if>` must have ONE root element.** Multiple siblings silently mount as a no-op; sibling `<style>` / `<script>` are dropped during parsing. Wrap content in a single outer `<div>`; move styles outside the template.
2. **Never combine `@click.outside` with hold buttons.** Button-release fires AFTER `@click.outside`, so a hold that opens a modal via `@click.outside` will have the release click close the freshly-opened modal. Use `@click`, or delay the open via `setTimeout(500ms)`.
3. **`<%# %>` ERB comments terminate at the FIRST `%>` anywhere in the body.** Comment bodies must contain ZERO `%` characters (including CSS `calc(... 100% ...)` snippets quoted inside). Use HTML `<!-- ... -->` for multi-line notes, or split into multiple `<%# %>` blocks.
4. **Never mix `<!--` (HTML) with `%>` (ERB) comment closes.** Mismatched open/close triggers HTML parser recovery → phantom DOM elements with mangled attributes (`x-show="null"`) on unrelated siblings. Match the syntax.
5. **HTML5 forbids `--` inside `<!-- ... -->`** — including CSS custom property refs (`--color-primary`) in dev notes. Parser recovery reparents downstream content into wrong containers. Use single hyphens or `−`, or move var refs to a `<style>` block.
6. **`block_given?` inside a partial inherits the layout's `<%= yield %>`** — returns true even with no block passed. Calling `yield` then returns the entire enclosing view's HTML. In shared partials, check explicit locals BEFORE `block_given?`: `if locals[:block] || block_given?`.
7. **Alpine's GENERATED DOM must not reach Turbo's page cache.** Turbo snapshots the live DOM, `x-for` rows and `x-if` clones included, but Alpine's record of them (`_x_lookup`, `_x_currentIfEl`) is a JS property on the template element and does not survive a snapshot. On a restoration visit Alpine re-initialises, sees no record of the rows already in the restored HTML, and renders a SECOND set beside them — the cached set holding no scope, so it renders blank. Symptom: 6 of 6 picks, follow a link, press Back, and "Your Picks" shows twelve rows (six real, six empty). `shared/_alpine_turbo_cache_reset.html.erb` in the app layout strips generated nodes on `turbo:before-cache`; it is layout-wide because the same navigation also doubled the seeds bar's `x-for i in 5` to ten. The sweep calls `Alpine.destroyTree(node)` before detaching each node — guarded on Alpine being defined, since the script runs at body parse and Alpine is deferred. Detaching alone appears to work because Alpine's MutationObserver cleans up afterwards, but that is an internal, not a contract, and this runs on every page. Consequence to design around: a restored page renders `x-for` / `x-if` content from whatever state its `x-data` reads AT INIT — so client state survives Back only if something puts it in the snapshot (see item 8). Cover: `e2e/pick_slots_turbo_restore.spec.js`, `test/views/alpine_turbo_cache_reset_test.rb` and `test/integration/alpine_turbo_cache_reset_wired_test.rb` (the latter proves the layout still RENDERS the partial — the view test alone stays green if that render line is dropped). A browser tier is mandatory here and `page.goto()` will not do: it is a full browser load, never touches the snapshot cache, and passes against the broken build. Use a real in-page link plus `page.goBack()`.
8. **A server-rendered config blob that a component re-reads on init will REVERT client state on Back.** The generalisable half of item 7, and it bit the contest cart. `#board-config` is rendered server-side and `selectionBoard()` re-reads it on every init, so a Turbo restoration visit replayed the cart as of the last SERVER RENDER and dropped every pick made since — the sidebar came back empty. The diagnostic tell is sharp: only state changed since the last server render is lost, so inserting a `page.reload()` before navigating makes it survive (which is exactly why an early version of `pick_slots_turbo_restore.spec.js` carried one). Fixed by `persistCartToConfig()`, bound to `@turbo:before-cache.window` on the board root, which writes the live cart into the blob so the snapshot carries it. Do NOT reach for `turbo-cache-control: no-cache` instead: guests never reach the server at all (`toggleSelection()` returns early on `!loggedIn`), so a refetched page has no cart to restore and loses their picks outright — and Back stops being instant on a heavy page. Cover: `e2e/cart_survives_turbo_restore.spec.js` (signed-in, pick identity, and guest) plus `test/integration/cart_persists_to_board_config_test.rb`, which pins the binding and the method together because they sit ~1200 lines apart in one partial.
9. **`Alpine.evaluate` is synchronous** — returns `undefined` for async expressions. `evaluateLater`'s `extras` shape is version-dependent. For custom async logic, compile your own `AsyncFunction`: `new Function('return (async () => { ... })')().then(...)`.
10. **A boolean attribute bound to a DOTTED expression is SET when the value is `undefined`, and REMOVED when it is `null`.** The two are not interchangeable, and nothing in the ERB shows the difference. `x-bind` rewrites an `undefined` result to `""` whenever the expression contains a dot (`c === void 0 && typeof n === "string" && n.match(/\./) && (c = "")` — alpine.js 3.16.1, vendored in studio-engine). `""` then misses `bindAttribute`'s `[null, undefined, false]` removal test, and for a boolean attribute Alpine assigns the attribute NAME as its value — so `:disabled="props.submitting"` renders `disabled="disabled"` for a prop nobody set. The control paints dead with no console error. It bit `/admin/modals`: the auth **Credentials** card omitted `submitting` from its `MODAL_VARIANTS` props while both live callers (`components/_user_nav.html.erb`, `layouts/_navbar.html.erb`) pass `submitting: null`, so all three credential CTAs plus the email field were untappable in the gallery while production was fine. **CORRECTED (turf-adopts-wallet-credential-slot).** This entry used to conclude “production was always correct, only the preview's props were short,” and therefore that the defence was call-site discipline *instead of* hardening the binding. That conclusion was measured false, and the correction matters because it inverted the priority. Two live paths reach an undefined `props.submitting`, and only one of them is a call site: (1) `app/javascript/solana_utils.js` reopens this modal at the credentials step after a 401 and passed `{ step: 'credentials' }` and nothing else, so every credential control rendered disabled for a user whose session had just expired — the one moment the modal exists to serve; and (2) the `props` getter in `modals/_auth.html.erb` returns an **empty object** whenever `current()` is transiently null during an open or close transition, and **no opener exists on that path at all**. The gallery's short props were a third instance of the same defect, not the only one. So both defences apply, and neither substitutes for the other: **openers pass every key the live call sites pass** (that is what keeps a review surface reviewing the app that ships, and it is the only thing that surfaces prop drift — the gallery was that surface until 2026-09-09, and turf's own style-guide cards in `app/views/style/host/_modals.html.erb` are it now), **and the binding is hardened** with `!!` (that is the only thing that reaches the empty-object transient). The four credential controls now bind `!!props.submitting`; the gem's own copy of the wallet button (`solana_studio/auth/_wallet_credential`) coerces the same way, so hardening converges the two rather than forking them. Cover: `test/views/auth_submitting_coercion_test.rb`, which pins the coercion, the seeded 401 reopen, and the agreement of the two live call sites — that last assertion arrived from `test/controllers/auth_credentials_gallery_test.rb`, retired on 2026-09-09 with the `/admin/modals/preview` seam its other three tests drove.

### Inline JS that stays inline
Some Alpine factories intentionally stay inline in `.erb` partials because Alpine evaluates `x-data` before importmap modules have finished executing. Keep these inline unless the surrounding component is refactored to a registered `Alpine.data(...)` factory loaded before Alpine starts:

- `proofOfReserves()` in `app/views/proof_of_reserves/show.html.erb`
- `contestChat()` and related chat helpers in `app/views/contests/_chat_panel.html.erb`
- callback-bearing hold button expressions that depend on ERB interpolation

Do move pure helper logic into modules when it does not participate in early `x-data` resolution. `StateFanout` is safe as a module because it is invoked from later event callbacks, not during Alpine's first component scan.

## Solana Modal (legacy alias)
`shared/_solana_modal.html.erb` — Now a thin compatibility proxy over `$store.modals` (see § Modal Host above). The store name `Alpine.store('solanaModal')` is preserved for older callsites; new code should call `$store.modals` directly. Three logical states still apply (processing / success / error). `fireSuccessConfetti()` from `solana_utils.js` fires 4 confetti bursts (center, left cannon, right cannon, delayed shower) on the success state via `$watch`.

## Sidebar Primitive and Gear Menu
- **Sidebar primitive** (`components/_sidebar_panel.html.erb`): fixed right panel using `--nav-h`, shared slide transitions, default width `w-80 max-w-full`, optional width override, and optional header actions / close / click-outside / Escape behavior.
- **Shared push class** (`.tm-sidebar-pushed` in `app/assets/tailwind/application.css`): same breakpoint cascade the contest picks sidebar used before extraction — 20rem at `768px`, then 15rem / 10rem / 5rem / overlay at wider breakpoints.
- **The push is invisible to Tailwind's breakpoints, so it needs companion rules.** `md:`/`lg:` are VIEWPORT queries; they cannot see the 320px this class just took away, so a component sized on a breakpoint is sized on a width the pushed column does not have. Two companion rules in the same stylesheet correct that, and both follow the same convention — **plain, unlayered CSS scoped under `.tm-sidebar-pushed`**, never a Tailwind variant. Unlayered author CSS outranks anything inside `@layer utilities` regardless of specificity or source order, so `md:grid-cols-4` and `lg:text-sm` cannot win it back; and the `.tm-sidebar-pushed` scope means the rule applies only while the sidebar is actually open.
  - `768px-1119.98px` — the pushed column wears the phone's grid (`.tm-team-grid` → 2 columns, `.tm-pair-grid` → 1). Below 1120px a four-up card in the pushed column is narrower than the same card on a 390px phone.
  - `1120px-1343.98px` — the pushed column holds the SMALL opponent labels (`.tm-opponent-cell` / `.tm-opponent-week` / `.tm-opponent-row` and its spans). `contests/_multi_week_team_card` steps those up at `lg`, which lands exactly where the pushed card is narrowest; 1344px is where the push steps 20rem → 15rem and the card gets its width back.
  - The two bands abut with no gap by construction. Adding a component that steps up at a breakpoint inside either band means adding a hook and a hold, not widening a band. Both are pinned by `test/views/sidebar_pushed_grid_test.rb` and `test/views/sidebar_pushed_label_hold_test.rb`, which read the small variant out of the partial rather than hard-coding it.
- **Contest picks sidebar** (`contests/_turf_totals_board.html.erb`): renders the desktop "Your Picks" panel through the primitive, keeps cart-specific slots/footer behavior, and still omits a close button so picks stay visible until cleared.
- **Gear sidebar** (`components/_gear_sidebar.html.erb` + `components/_gear_sidebar_trigger.html.erb`): the gear icon, username, and profile image toggle one page-level menu using the same `md` breakpoint boundary as the contest sidebar (`hidden md:flex` desktop panel, full-width `flex md:hidden` mobile drawer). Links: My Profile, My Contests, next quest when present, How to Play, Proof of Reserves, Refresh Wallet, admin shortlist for admins (Dashboard, Contests, Users, Landing Pages), and Log out. The sidebar uses the same emoji-swap animation as the old dropdown and `.tm-gear-sidebar-layer` (`var(--z-drawer)`) so it overlaps both the desktop contest picks sidebar (`z-40`) and the mobile bottom entry slip (`var(--z-docked)`) when the menu is open. The drawer sits BELOW `--z-modal`: a modal opened from the gear menu covers it.
- **Soccer dropdown** (`components/_soccer_dropdown.html.erb`): Soccer ball emoji trigger, links to Teams and Games pages.

## Dev Mode
- **Toggle**: DEV MODE button in the environment banner (top of page). It renders whenever the banner renders — development **and** QA, not devnet only (gem `studio/banners/_environment.html.erb:34`). Styling is the engine `studio/banners/_button` outline variant: transparent background, `1px solid rgba(255,255,255,0.9)` border, white text, inverting to a white fill with `#be185d` text on hover/focus (gem `_button.html.erb:27-34` for the outline defaults; the `1px solid` border string is assembled at `:39`, and `#be185d` is the `hover_text_color` default at `:12`). The button carries **no** active/inactive styling — dev mode reads off the `.dev-mode` body class and the `dm-*` classes below, never off the button's own appearance (gem `_dev_mode_button.html.erb:1-4`).
- **Store**: Global `Alpine.store('devMode')` persisted to `localStorage`, initialized on `alpine:init`
- **Body class**: `<body>` gets `.dev-mode` class when active — use `.dev-mode .your-class` for CSS-only debug visuals

### Debug Color Classes (`dm-*`)
Reusable CSS classes in `app/assets/tailwind/application.css` that show colored backgrounds only when dev mode is active. Each uses 75% opacity so overlapping components blend visually. Just add the class to any element — no Alpine bindings needed.

| Class | Color | RGB |
|-------|-------|-----|
| `.dm-blue` | Cornflowerblue | `rgba(100, 149, 237, 0.75)` |
| `.dm-green` | Lightgreen | `rgba(144, 238, 144, 0.75)` |
| `.dm-orange` | Sandybrown | `rgba(244, 164, 96, 0.75)` |
| `.dm-salmon` | Lightsalmon | `rgba(250, 128, 114, 0.75)` |
| `.dm-purple` | Purple | `rgba(128, 0, 128, 0.75)` |
| `.dm-coral` | Lightcoral | `rgba(240, 128, 128, 0.75)` |
| `.dm-yellow` | Khaki | `rgba(240, 230, 140, 0.75)` |
| `.dm-teal` | Paleturquoise | `rgba(175, 238, 238, 0.75)` |

**Current assignments** (navbar only):
- `_navbar.html.erb`: "Turf"=`dm-salmon`, "Totals"=`dm-yellow`, desktop nav=`dm-teal`, user-nav-col=`dm-purple`, mobile sub-nav=`dm-coral`, balance=`dm-blue`
- `_user_nav.html.erb`: gear+morph=`dm-teal`, username=`dm-coral`, seeds bar container=`dm-orange`, avatar link=`dm-green`
- `_navbar_seeds_bar.html.erb`: seeds bar wrapper=`dm-orange`

- **Current uses**:
  - Debug color classes (`dm-*`): layout boundary visualization on navbar/user nav components (see table above)
  - Hidden UI reveals: leaderboard entry debug details, seeds bar "Replay" link, XP slate "Replay" link (all via `x-show="$store.devMode"`)
  - CSS hook: `.dev-mode .nudge-debug { display: block; }` in `app/assets/tailwind/application.css`
- **Adding new debug tools**: Use `x-show="$store.devMode" x-cloak` for Alpine-toggled elements. For layout debugging, add a `dm-*` class to the element — no other changes needed.

## Seeds XP Bar (`_slate_progress_xp.html.erb`)
- Progress bar showing seeds toward next level with animated fill, shimmer, and glow
- Bar fill uses 6px border-radius (not fully rounded)
- Level badge pops on level-up (3.2x scale bounce) with firework burst animation
- Firework: 72 particles explode radially from badge center using branding colors (green, violet, mint, orange, red)
- Level-up data stored in `localStorage('seedsLevelUp')` as JSON, consumed on next page load
- Sequence: fill bar to 100% → level pop + firework → reset bar → fill to new progress
- Dev mode "Replay" link simulates level-up for testing
- Contest show page saves seeds data to `seedsNavbar` localStorage for navbar bar
- Entry confirmation dispatches `navbar-seeds-update` custom event with seeds detail

## Login Page SSO
When SSO session available, blur overlay covers the entire card (`absolute inset-0 z-10, rounded-2xl`). The SSO "Continue as" button sits above the blur (`relative z-20`). Click-to-reveal fades out the blur (500ms transition) and focuses the email field. Uses `.backdrop-overlay` CSS class (defined in `app/assets/tailwind/application.css`).

## Contest Show Layout
- Seeds progress bar and invite card rendered side-by-side on desktop (`flex gap-4 flex-wrap items-stretch` with `flex-1 basis-[300px]`), stacked on mobile.
- "+ Add Another Entry" button appears in the admin actions row (next to Lock Contest, Jump, Rank Matchups) rather than as a standalone section.

## Admin Preview Tools

### Navbar Review (`/admin/navbar`)
Admin page for visually comparing the navbar at all key breakpoints without resizing the browser. Route: `get "admin/navbar"` → `admin#navbar`. Linked from the admin dashboard / link hub.

**Architecture**: Renders the `layouts/navbar` partial (with `preview: true`) inside `.navbar-preview` wrapper divs. Container-scoped CSS classes simulate responsive breakpoints at any viewport width — this is necessary because Tailwind/CSS media queries respond to the viewport, not the container.

**Breakpoint simulation classes** (on the `.navbar-preview` wrapper):
| Class | Range | Overrides |
|---|---|---|
| `.is-mobile .bp-tiny` | 320–399px | Hide `md:flex`, show `md:hidden`, stack title, 1.1rem font |
| `.is-mobile .bp-small` | 400–767px | Same visibility, stack title, 1.25rem font |
| `.is-desktop` | 768–1200px | Default responsive behavior |

**Interactive controls per breakpoint**:
- Width slider with range min/max matching the breakpoint range
- Device marker (vertical line at the device width: iPhone 15 390px, iPhone 16 Pro Max 430px, iPad Pro 13" 1032px)
- Reset button to snap to device width
- **Scrolled toggle**: sets `--nav-p: 0|1` inline on the `.navbar-preview` wrapper (plus `is-scrolled-preview` for the shadow, which a preview header cannot get from `.is-scrolled` — it has no `x-data`, so no `scrolled`). Because `--nav-p` is a registered `<number>`, the wrapper simply **transitions it** (`transition: width 0.15s ease, --nav-p 0.3s ease`) — one interpolating property in place of the five per-element `font-size`/`width`/`padding` transitions and the twelve `!important` rules that used to restate every collapsed value. The preview now exercises the shipped `calc()`s instead of a parallel copy of them.

**Username override**: Text input at the top of the page temporarily overrides the displayed username in all previews (not persisted). Uses `data-username-display` attribute on the username link for targeting. On change, recalculates the overflow fade mask (`overflows` flag) so the gradient fade activates/deactivates at the correct `.username-cap` max-width per breakpoint.

**Sections**: Logged-In View + Pre-Login View, each with all three breakpoints. Deduplicated via loop over `[{ title:, show_logged_in: }]`.

**Key pattern**: When simulating responsive behavior in a preview container, use container-scoped CSS class selectors rather than media queries — a container cannot fire one. Prefer overriding the component's **custom properties** (`.navbar-preview.bp-tiny .nav-shell { --nav-title-size: … }`) over restating its computed values: the override is unlayered so it beats `@layer utilities` without `!important`, and a state toggle becomes a transition on one registered property instead of one per element. Only reach for `!important` where you are fighting a Tailwind responsive *utility* on the element itself (`display`, `width`).

## CSS Refactoring Standards

### Inline style consolidation
- **2+ occurrences** → extract to a named CSS class in a `<style>` block (e.g., `font-size: 10px` × 4 → `.seeds-text`)
- **Component-scoped names**: Use descriptive prefixes tied to the component (e.g., `seeds-bar`, `seeds-fill`, `seeds-text` for the seeds progress bar)
- **One-off layout values** can stay inline (e.g., `max-width: 6rem`, `padding-right: 6px`) — don't create a class for a single use

### Dynamic vs static styles
- **Static properties**: Use CSS classes or Tailwind utilities
- **Alpine-controlled state**: Use `:style` bindings, but split from static properties. Don't mix static padding and conditional devMode background in one `:style` — use `style="..."` for static + `:style="..."` for dynamic
- **Scroll-responsive sizes**: derive them from a scroll-linked custom property, never from `x-bind:class` + `transition-all`. See the navbar's `--nav-p`: a threshold plus a clock lets motion outlive the gesture that asked for it (measured 34px of content travel over 232ms *after* the finger stopped), and it puts a size swap on Alpine's per-scroll reactive path for a 2px change.

### Transitions
- **Never put a LAYOUT property on a clock when a gesture is driving it.** `padding`, `width`/`height` and `font-size` all reflow; on a sticky header they reflow the whole document under the reader. A time-based transition keeps doing that after the finger has stopped. Drive it from scroll position instead (`--nav-p`) and the motion ends exactly when the gesture does.
- **Clocks are still right for paint-only properties** — `box-shadow`, `color`, `opacity`, `transform`. The navbar keeps `transition-shadow duration-300` and `transition-colors duration-300` for exactly that reason.
- **`transition` vs `transition-all`**: Tailwind's `transition` only covers color/opacity/shadow/transform — does NOT include `font-size` or `width`. That exclusion is a feature: if you find yourself reaching for `transition-all` to animate a size, the size probably wants a scroll- or state-linked custom property, not a clock.
- **Preview transitions**: transition the custom property on the preview wrapper (`.navbar-preview { transition: --nav-p 0.3s ease; }`), not each element's `width`/`font-size`. Registered `@property` values interpolate, so one declaration covers every dimension derived from it.

### Admin preview CSS pattern
When building a component preview that needs to simulate responsive behavior:
1. Render the real partial with a `preview` flag that disables dynamic behavior (scroll handlers, sticky positioning)
2. Wrap in a container with breakpoint-simulation classes (e.g., `.is-mobile`, `.bp-tiny`)
3. Override the component's **custom properties** on the container-scoped selectors; fall back to `!important` only for Tailwind responsive utilities applied directly to the element (`display`, `width`)
4. For state toggles (scrolled, hover), set the state's custom property and transition it — never swap between two separate DOM renders (kills transitions), and never restate the component's computed values (they drift)
5. Use higher-specificity selectors for state + breakpoint combinations (e.g., `.navbar-preview.bp-tiny .nav-shell` beats `.nav-shell`)

## Theme variable flow (Tailwind ↔ engine)

Theme colors flow one direction: studio-engine config → CSS custom properties → Tailwind utilities AND hand-rolled CSS.

```
config/initializers/studio.rb   # e.g. theme_primary = "#2E7D32"
        │
        ▼
ThemeSetting (engine)            # 7 role colors persisted per-app
        │
        ▼
<style> in <head>                # --color-primary-rgb: 46 125 50; (RGB triplet), cached 1h at studio/theme/<app>
        │                         # --color-cta, --color-cta-hover, --color-page, …
        ├──> Tailwind config     # primary palette = rgb(var(--color-primary-rgb) / <alpha>)
        │                         #  → bg-primary, border-primary, ring-primary; text-primary reads --color-primary-ink-rgb
        └──> Hand-rolled CSS    # rgb(var(--color-primary-rgb)) directly in .matchup-selected, .pick-pulse, etc.
                                  #  (and in the ENGINE's own layer — .hold-btn themes off the same token from studio-engine)
```

Practical implications:
- New role colors require both an engine palette change AND a safelist entry in `config/tailwind.config.js` (the safelist guards `bg`/`text`/`border`/`ring` utilities so they survive purging).
- Always reference brand colors via the CSS var, never via hex literals — switching themes (or running the `/admin/theme` editor) only updates the var, not hardcoded hex.
- For alpha variants in hand-rolled CSS, use the slash form: `rgb(var(--color-primary-rgb) / 0.2)`. Never the legacy comma form `rgba(var(--x-rgb), A)`: the triples are space-separated, so a browser drops that declaration and paints nothing. `test/views/legacy_rgba_var_guard_test.rb` refuses it in the compiled stylesheet and in app source.

## Layer scale

Every layer that can cover other chrome reads a named `--z-*` tier instead of a bare number. **studio-engine owns the scale outright** — the tiers are defined once, in the gem's `app/assets/tailwind/studio_engine/engine.css` (`-- Layer scale`), and reach this app through the engine build `application.css` imports on line 3. There is no local copy. Read the ORDER, not the number:

`--z-docked` (mobile entry slip) → `--z-nav` (pinned navbar) → `--z-drawer` (gear sidebar) → `--z-modal` (modal backdrop + card, THE app blocker) → `--z-lightbox` → `--z-alert` (live scoring overlay, confetti) → `--z-toast-blur` → `--z-toast` → `--z-banner` (QA / DEV MODE bars, reachable mid-modal) → `--z-tooltip`.

Below 100 the tiers coincide with Tailwind's own `z-10`..`z-50`, so existing sub-100 classes are already on the scale. `test/views/layer_scale_adoption_test.rb` asserts the ordering **against the resolved gem**, refuses any bare blocking number (>= 100) written into `app/views/**/*.erb`, `app/assets/tailwind/**/*.css`, or `app/javascript/**/*.js`, and reads the COMPILED `app/assets/builds/tailwind.css` to prove every tier a browser resolves is the engine's — defined exactly once, at the engine's value.

**Never redefine a tier locally.** This app carried an `ADOPTION SHIM` — a `:root` in `application.css` mirroring the tiers while the pin predated the gem that ships them — and it was deleted in `delete-turf-layer-shim`. It had to go rather than linger: `application.css` imports the engine build FIRST, so a local `:root` further down won on equal specificity and this app silently ran a frozen private copy of the shared scale. Nothing failed; the next engine layer change simply would not have arrived. `test/lib/engine_pin_contract_test.rb` now refuses a re-introduced definition of any engine-shipped tier, in **any** source CSS file this app ships. To change a level, change it in studio-engine.

## Toast layer — the override seam this app no longer uses

`--studio-toast-z` and `--studio-toast-blur-z` are studio-engine's published per-component override seam for the toast stack. **This app sets neither**, and that is the correct state: the engine's own `layouts/studio/_flash.html.erb` defaults them to the shared tiers — `var(--studio-toast-z, var(--z-toast, 400))` and `var(--studio-toast-blur-z, var(--z-toast-blur, 399))` — so toasts already render above both the sticky navbar and any open modal with nothing declared here.

Turf Monster used to set both names on `:root`, from inside the layer-scale adoption shim, back when the engine's own default was a bare `60` (above most content, BELOW a modal — a toast fired from an open modal was invisible). Both the shim and the local overrides went in `delete-turf-layer-shim`. Verified in a real browser after the deletion: `#toast-container` computes `z-index: 400` and `.toast-page-blur` computes `399`, resolved from the engine.

Reach for the seam only for a genuinely turf-specific toast level, and set it once — `test/lib/tailwind_css_dedupe_test.rb` refuses a second declaration, because the later one wins in silence. To move the toast layer for every Studio app, change `--z-toast` in studio-engine instead.

Historical note: the override once lived in an inline style block in `_navbar.html.erb` and needed `!important` to beat the engine's old inline `style="z-index:60"`. The engine stopped rendering that inline style long ago.

## Test scaffolding feature flag (`ENABLE_TEST_SCAFFOLDING`)

When set, the env flag enables two scaffold-only UI elements visible to admins for end-to-end-with-real-money testing without real cost:

- A **`micro` contest tier** in `Contest::FORMATS` — **$1.00 entry, 9 max entries, paying $5 / $2 / $2** ($9.00 guaranteed on $9.00 gross). Surfaces as a card in the Format picker on `/contests/new`, gated by `Contest.selectable_formats` + `AppFlags.test_scaffolding?`. Lets you exercise the full Stripe + entry-token + onchain flow with pocket change.
- A **`test_trio` token pack** (`StripePurchase::PACKS`) — 3 tokens for $5. Surfaces in the auth modal's `tokens-picker` step as a third option alongside `single` ($19) and `trio` ($49). Gated by `StripePurchase.available_packs` + `AppFlags.test_scaffolding?`.

**The `micro` tier is break-even by design** (operator call, 2026-08-27): a full contest grosses exactly the $9 it guarantees, and a short fill loses money — grading pays only the ranks that exist, so 1 entry pays $5 (-$4), 2 pay $7 (-$5), and 3+ pay the full $9, making three entries the worst case at -$6. It exists to rehearse the money path, not to earn on it. `test/models/contest_test.rb` pins the $0 margin so a later "rounding" edit has to be deliberate.

**Production BOOTS with this flag on** (changed 2026-08-27). `config/initializers/test_scaffolding_guard.rb` used to `raise` on a production boot carrying the flag, which made the `micro` tier unreachable on real production — the one place the operator wanted to rehearse. It now logs at ERROR and reports to Sentry instead, so the state is loud but not fatal. That means production really is selling $1.67-per-token entry tokens while the flag is set: **treat it as a test window and unset it when you are done.**

Unset before public launch — the `$1` tier and `$5/3` pack are not customer-facing offers. Memory ref: `project_turf_test_scaffolding`.

## Seeds bar refactor (v0.9.0+)

The 5-section seeds progress bar (`components/_seeds_bar.html.erb`) was refactored from per-segment classes (`.seeds-bar` / `.seeds-fill` / `.seeds-text`) to a single `.seeds-bar-continuous` class plus a CSS-registered `--bar-progress` custom property.

**Why**: per-segment classes meant 5 separate width transitions chained together — each segment's animation curve restarted at the segment boundary, producing a visible staircase. The continuous form interpolates all 5 segment widths from a single transition driven by one variable; per-section shimmer overlays positioned in bar coordinates (`left: -(i-1)*100%, width: 500%`) keep the wave continuous across segments. The result: one ease curve over the whole bar, not 5 chained ones. CSS-only — no JS animation loop.

<!-- citation-guard: unswept (21 citations) — most name studio-engine partials BY LINE, the form the wallet documents replaced with `gem: path#symbol`; the rest are unverified -->
