# UI Patterns & Branding

> Payment note: Stripe-specific token-picker sections are legacy/dormant unless
> `PAYMENT_PROVIDER=stripe` is explicitly set. The default unset provider is
> `none`; current funding surfaces should prefer PayPal/Venmo, CDP, or direct
> USDC entry when those flags are enabled.

## Branding & Theme

- **Theme**: Dynamic — engine-generated CSS custom properties from 7 role colors (see `studio-engine/docs/NAVBAR_SETUP.md` plus this file's semantic-token notes)
- **Theme config**: `theme_primary = "#4BAF50"` (green), `theme_accent = "#8E82FE"` (violet) in `studio.rb`
- **Admin theme page**: `/admin/theme` — color editor + styleguide (from engine)
- **Primary**: `#4BAF50` Green — brand text, CTAs, buttons, nav hovers, money displays, balances, checkmarks, hold button idle state
- **Mint**: `#06D6A0` — win badges, contest status (open). Reserved for game mechanics (win), not general selection UI. NOT the hold button's success state any more (2026-08): confirming used to jump to mint/teal, a different hue from the button pressed, with a mint check that barely showed on it — it now brightens within the brand green and draws the check in white.
- **Accent**: `#8E82FE` Violet — scores, draft badges, `.btn-secondary`, Phantom wallet badge. NOT for CTA-intent elements (use `primary` instead). NOT for turf scores (use `primary`).
- **Primary for selection UI**: Selection count badges, cart slot borders, matchup selection rings/tints, turf score values, links, sort toggle active state, and FAB buttons all use `primary` (green), not mint or violet.
- **Warning**: `#FF7C47` Orange — warning states, `.btn-warning`
- **Negative**: Red (Tailwind default) — losses
- **Font**: Montserrat (all weights 400-900)
- **Logo**: Two files exist — `/public/logo.png` (1.3MB, used in layout navbar) and `/public/logo.jpeg` (272KB, used in auth pages). Both are the green monster mascot. Should be consolidated to one file.

### Semantic Tokens (required)
- **Surfaces**: Use `bg-page`, `bg-surface`, `bg-surface-alt`, `bg-inset` — never hardcode `bg-navy-*`
- **Text**: Use `text-heading`, `text-body`, `text-secondary`, `text-muted` — never hardcode `text-white` for headings or `text-gray-*` for body text
- **Borders**: Use `border-subtle`, `border-strong` — never hardcode `border-navy-*`
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
Open Graph images must use the `amazon_public` / `amazon_dev_public` Active Storage services. The private `amazon` services return signed URLs; social unfurlers cache image URLs long enough for signed links to expire. Public OG services return permanent S3 object URLs, and `OgImageAttachable` owns the per-environment service choice.

### Status Badges
mint=open, yellow=locked (DERIVED time-gate, not a status — `Contest#locked?`), gray=settled, violet=pending

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

- **Game view** (default): Paired cards with "vs" divider (`color-mix` background), sorted by lowest turf score. Uses `_matchup_game_pair.html.erb` partial (locals: `left`, `right`, `locked`). Both-selected: outer `outline` + `box-shadow` glow in primary, "vs" div gets primary tint.
- **Turf Score view**: Flat grid (`grid-cols-2 md:grid-cols-4`) of individual cards sorted by turf score. Uses `_matchup_card.html.erb` partial (local: `matchup`). Double-click "Turf Score" toggles asc/desc (arrow indicator). Two server-rendered orderings toggled via `x-show` (no JS re-sorting).
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
When hold-to-confirm hits a blocker (geo-blocked, not logged in, insufficient funds), a centered modal appears with icon, title, message, progress bar countdown (5s), and CTA button. Hold button flips to red `.error` state ("Entry Blocked").
- Geo-blocked → "Location Restricted" → `/`
- Not logged in → "Log In Required" → `/signin`
- Insufficient funds → "Insufficient Funds" / "Top Up Wallet" → `/wallet`
- `showRedirectModal(title, message, icon, url, seconds, cta)` method on Alpine component

## Navbar

Extracted to `layouts/_navbar.html.erb` partial. Sticky, scroll-responsive. The non-preview header is `vt-pinned-header sticky top-0 z-[130] bg-page transition-shadow duration-300` (`_navbar.html.erb:27`) — `z-[130]` deliberately sits above the modal host backdrop, see the Toast manager section. Alpine `scrolled` state uses hysteresis: past 60px to compact, back below 5px to expand (`_navbar.html.erb:26`) — prevents jittery toggling. On scroll: header adds `is-scrolled` class + `shadow-lg border-b border-subtle`, logo shrinks `w-12→w-8` (mobile: `w-10`), title `text-3xl→text-xl`, padding `py-6→py-2`. All transitions 300ms via `transition-all duration-300`.

### Partial locals
- `show_logged_in` — override `logged_in?` (default: real session). Used by admin preview to force logged-in/out views.
- `preview` — disables scroll handler and sticky positioning. Uses static Tailwind classes instead of Alpine `x-bind:class` bindings.

### Responsive breakpoints
Custom `<style>` block in `<header>` with three tiers. Mobile title stacks "Turf"/"Totals" vertically via `flex-direction: column` with `-4px` bottom margin on "Turf" to tighten spacing. "Totals" renders larger than "Turf" on mobile.

| Range | `.user-nav-col` | `.nav-title` | `.nav-title span:last-child` | Notes |
|---|---|---|---|---|
| **< 400px** | 14rem | 1.1rem | 1.3rem | Gap 0.25rem on logo link |
| **400–767px** | 15rem | 1.25rem | 1.5rem | Gap 0.5rem on logo link |
| **768px+** | 20rem | Alpine `text-3xl`/`text-xl` | — | Side-by-side title, no stacking |

Scrolled state on mobile (via `.is-scrolled` ancestor):
| Range | `.nav-title` | `span:last-child` | `.nav-logo` |
|---|---|---|---|
| **< 400px** | 0.9rem | 1rem | 2.5rem (w-10) |
| **400–767px** | 1rem | 1.15rem | 2.5rem (w-10) |

### Left side
Logo (`.nav-logo`) + "Turf Totals" brand title (`.nav-title` with two `<span>`s), desktop nav links (`hidden md:flex`: Contests, NFL Totals, Rules, Reserves, geo badge — `_navbar.html.erb:55-60`).

### Mobile sub-navbar
`flex md:hidden` compact row below main nav with `bg-surface-alt border-t border-subtle`. Contains: Contests, NFL Totals, Rules, Reserves, geo badge (`_navbar.html.erb:108-112`). Gear sidebar trigger + theme toggle morph pushed right via `ml-auto`.

### Environment banner
Owned by **studio-engine** (>= 0.30), not by this app: the markup lives in the gem at `app/views/studio/banners/_environment.html.erb`. Turf renders it from `app/views/layouts/_navbar.html.erb:37`, **inside** the sticky `<header>` (opened at `_navbar.html.erb:26`, closed at `:118`) — so it stays pinned with the navbar instead of scrolling away. Turf passes two locals and nothing else:

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
Extracted to `_geo_badge.html.erb` partial — shared by desktop nav and mobile sub-navbar. **Public: renders for every visitor, signed in or not** — detection is IP-based (`detect_geo_state` runs on every request), and lookups are cached in `Rails.cache` for 24h keyed by IP (`config/initializers/geocoder.rb`) so the anonymous ipinfo tier's shared rate limit doesn't blank the state into a red `??`. Shows flag + state code when resolved; red `??` when undetectable (fail-closed); red when blocked or a geo override is active. Stable selector: `.geo-badge`. State flag image uses inline styles for reliable sizing (`height: 12px; width: 16px; object-fit: cover`). Badge shape is `rounded-lg`.

### Right side — logged in: two-row block + avatar
- **Row 1 (Div 1)**: balance, gear + theme toggle morph (left of username, `hidden md:flex`), username. On mobile, gear + morph shown in sub-navbar instead. `padding-right: 6px` via inline style.
- **Row 2 (Div 2)**: 5-section seeds progress bar via `render "components/seeds_bar", compact: true` (turf-vault v0.9.0+ refactor — replaced the old `.seeds-bar`/`.seeds-fill`/`.seeds-text` classes). The partial uses the `.seeds-bar-continuous` class + CSS-registered `--bar-progress` custom property so all 5 segment widths interpolate from a single transition (one ease curve, not 5 chained). Per-section shimmer overlays positioned in bar coordinates (`left: -(i-1)*100%, width: 500%`) keep the wave continuous across segments. Wallet address (left) + Level X (right) overlaid via two-layer clip-path text technique (muted underneath, white on top revealed by `clip-path: inset(0 (100-displaySeeds)% 0 0)`). Level-up: `bar → 100% → bump level (.nav-level-pop) → drain → refill`. Listens for `navbar-replay-level` and `navbar-seeds-update` window events.
- **Avatar**: `_avatar.html.erb` partial (size "nav" = `w-8 h-8`), outside the two-row block. Links to `/account`.
- Balance shows whole dollars only (no cents) — JS hydrate (`refreshSession`/`refreshBalance`) uses `Math.floor`, ERB uses `.to_i`. The pill is **USDC + USDT combined** (`display_balance`); per-currency readouts live on `/account`'s `data-wallet-tile` tiles. The link hides while the cache is cold ("loading") and when the combined balance is $0 with free-entry tokens present (the 🎟️ badge covers that state).
- Username and balance link to `/account` and `/wallet` respectively. Both use `transition-all duration-300` for smooth scroll-responsive font-size changes.
- **Username overflow fade**: `.username-cap` class sets responsive `max-width` (5rem tiny, 6rem small, 7rem desktop). When text overflows, Alpine applies a CSS `mask-image` gradient to fade the trailing edge. Overflow is recalculated when the navbar review page's username input changes.
- User nav column has `pl-0 pr-4 md:px-4` — no left padding on mobile.

### Right side — logged out
- Theme toggle morph (`hidden md:flex`) + a **"Sign in"** button, right-aligned. Theme toggle morph appears in mobile sub-navbar instead.
- The button is `class="btn btn-primary"` — the theme's primary color, not a hardcoded green.
- It is a **modal trigger, not a navigation**: `@click.prevent` opens the in-page auth modal via `$store.modals.open('auth', { step: 'credentials', mode: 'signup', … })`. The `signin_path` href is only the no-JS fallback. Login and signup are one create-or-login flow, so the single CTA reads "Sign in" while opening at `mode: 'signup'` (`_navbar.html.erb:96-101`).

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

Modal lifecycle is owned by the studio-engine modal host — `Alpine.store('modals')` — a stack-based store registered in the shared `_modal_host.html.erb` partial. Local app code consumes it; do not reimplement.

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

**Defining a new modal partial**: Mount inside `<template x-if="$store.modals.current()?.id === 'your-id'">` in `shared/_modal_host.html.erb`. **Critical: single root element** — sibling `<style>` / `<script>` / structural tags are silently dropped during parsing (see § Alpine + ERB Constraints below).

**Recovery**: The host auto-clears the stack on browser back navigation (bfcache `pageshow`) and Turbo navigation (`turbo:before-cache`). No app-side recovery code needed.

**Slow-op smoothing**: `window.StudioModals.holdAtLeast(minMs)` returns a thenable enforcing a minimum spinner duration — pair with the processing card so the spinner doesn't flash past the user on fast operations.

> The old `Alpine.store('solanaModal')` is now a thin compatibility proxy over `$store.modals`. New code should call `$store.modals` directly. `fireSuccessConfetti()` still lives in `solana_utils.js` (the old "in wallet_connect" claim was always wrong).

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
8. **redirect** — Geo-blocked / not logged in / insufficient funds. Countdown + CTA to the blocker's target page (e.g. `/wallet`). Driven by the board's `setInterval`.

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

**Scroll fade**: Message list container uses `-webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 2.5rem), transparent)` to soften the bottom edge.

## Entry Tokens (Web2 flow)

Entry tokens are on-chain `EntryTokenAccount` PDAs minted via Stripe Checkout. The Web2 path lets users with no USDC enter contests by buying tokens with a card.

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

**Job idempotency**: `TokenPurchaseJob` short-circuits if `status == "minted"` (already done). On retry it calculates `already_minted` from the persisted signature count and loops from there — exactly-once per token even with mid-job crashes.

**Navbar badge**: free-entry tokens are surfaced by the 🎟️ badge in `_user_nav` (`[data-free-entry-badge]`, count in `data-token-count`, toggled by `updateNavTokens`). When the combined USDC+USDT balance is $0 AND the user has tokens, the `$X` balance link HIDES entirely (`_navbar.html.erb` `hide_balance` rule, re-applied live by `refreshSession`/`refreshBalance`) — the badge alone signals the next-step affordance; there is no token-count-in-place-of-dollars display anymore.

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

Landing pages are `LandingPage` records (name, headline, subheadline, badge, cta_label, background_style, contest_id, slug, active). Rendered at `/landing/:slug` by `LandingPagesController#show`. Page sections:

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
7. **`Alpine.evaluate` is synchronous** — returns `undefined` for async expressions. `evaluateLater`'s `extras` shape is version-dependent. For custom async logic, compile your own `AsyncFunction`: `new Function('return (async () => { ... })')().then(...)`.

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
- **Shared push class** (`.tm-sidebar-pushed` in `application.tailwind.css`): same breakpoint cascade the contest picks sidebar used before extraction — 20rem at `768px`, then 15rem / 10rem / 5rem / overlay at wider breakpoints.
- **Contest picks sidebar** (`contests/_turf_totals_board.html.erb`): renders the desktop "Your Picks" panel through the primitive, keeps cart-specific slots/footer behavior, and still omits a close button so picks stay visible until cleared.
- **Gear sidebar** (`components/_gear_sidebar.html.erb` + `components/_gear_sidebar_trigger.html.erb`): the gear icon, username, and profile image toggle one page-level menu using the same `md` breakpoint boundary as the contest sidebar (`hidden md:flex` desktop panel, full-width `flex md:hidden` mobile drawer). Links: My Profile, My Contests, next quest when present, How to Play, Proof of Reserves, Refresh Wallet, admin shortlist for admins (Dashboard, Contests, Users, Landing Pages), and Log out. The sidebar uses the same emoji-swap animation as the old dropdown and `.tm-gear-sidebar-layer` (`z-index:10000`) so it overlaps both the desktop contest picks sidebar (`z-40`) and the mobile bottom entry slip (`z-index:9999`) when the menu is open.
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
- **Scrolled toggle**: Adds/removes `is-scrolled-preview` class on the wrapper with CSS transitions (0.3s). All scroll effects (padding, logo size, title size, balance size, header shadow) are CSS-only overrides — no DOM swapping. This ensures smooth animated transitions.

**Username override**: Text input at the top of the page temporarily overrides the displayed username in all previews (not persisted). Uses `data-username-display` attribute on the username link for targeting. On change, recalculates the overflow fade mask (`overflows` flag) so the gradient fade activates/deactivates at the correct `.username-cap` max-width per breakpoint.

**Sections**: Logged-In View + Pre-Login View, each with all three breakpoints. Deduplicated via loop over `[{ title:, show_logged_in: }]`.

**Key pattern**: When simulating responsive behavior in a preview container, use container-scoped CSS class selectors with `!important` rather than media queries. Add `transition` properties to the preview elements so state changes (like scrolled toggle) animate smoothly.

## CSS Refactoring Standards

### Inline style consolidation
- **2+ occurrences** → extract to a named CSS class in a `<style>` block (e.g., `font-size: 10px` × 4 → `.seeds-text`)
- **Component-scoped names**: Use descriptive prefixes tied to the component (e.g., `seeds-bar`, `seeds-fill`, `seeds-text` for the seeds progress bar)
- **One-off layout values** can stay inline (e.g., `max-width: 6rem`, `padding-right: 6px`) — don't create a class for a single use

### Dynamic vs static styles
- **Static properties**: Use CSS classes or Tailwind utilities
- **Alpine-controlled state**: Use `:style` bindings, but split from static properties. Don't mix static padding and conditional devMode background in one `:style` — use `style="..."` for static + `:style="..."` for dynamic
- **Scroll-responsive sizes**: Use Alpine `x-bind:class` with Tailwind size classes (e.g., `scrolled ? 'text-lg' : 'text-xl'`). Pair with `transition-all duration-300` to animate the change.

### Transitions
- **Matching durations**: All scroll-responsive elements use `0.3s` / `duration-300` — keep consistent across logo, title, padding, balance, username
- **`transition` vs `transition-all`**: Tailwind's `transition` only covers color/opacity/shadow/transform — does NOT include `font-size` or `width`. Use `transition-all duration-300` when Alpine toggles size classes, or explicit `transition: font-size 0.3s` in CSS.
- **Preview transitions**: Define transitions in the admin preview CSS (`.navbar-preview .nav-logo { transition: width 0.3s, height 0.3s; }`) since preview mode skips the Tailwind transition classes

### Admin preview CSS pattern
When building a component preview that needs to simulate responsive behavior:
1. Render the real partial with a `preview` flag that disables dynamic behavior (scroll handlers, sticky positioning)
2. Wrap in a container with breakpoint-simulation classes (e.g., `.is-mobile`, `.bp-tiny`)
3. Override Tailwind responsive utilities with `!important` on the container-scoped selectors
4. For state toggles (scrolled, hover), use CSS class toggling with transitions — never swap between two separate DOM renders (kills transitions)
5. Use higher-specificity selectors for state + breakpoint combinations (e.g., `.bp-tiny.is-scrolled-preview .nav-title` beats `.is-scrolled-preview .nav-title`)

## Theme variable flow (Tailwind ↔ engine)

Theme colors flow one direction: studio-engine config → CSS custom properties → Tailwind utilities AND hand-rolled CSS.

```
config/initializers/studio.rb   # e.g. theme_primary = "#4BAF50"
        │
        ▼
ThemeSetting (engine)            # 7 role colors persisted per-app
        │
        ▼
<style> in <head>                # --color-primary-rgb: 75 175 80; (RGB triplet)
        │                         # --color-cta, --color-cta-hover, --color-page, …
        ├──> Tailwind config     # primary palette = rgb(var(--color-primary-rgb) / <alpha>)
        │                         #  → utility classes: bg-primary, text-primary, border-primary, ring-primary
        └──> Hand-rolled CSS    # rgb(var(--color-primary-rgb)) directly in .matchup-selected, .seeds-bar, etc.
        │                         #  (and in the ENGINE's own layer — .hold-btn themes off the same token from studio-engine)
```

Practical implications:
- New role colors require both an engine palette change AND a safelist entry in `config/tailwind.config.js` (the safelist guards `bg`/`text`/`border`/`ring` utilities so they survive purging).
- Always reference brand colors via the CSS var, never via hex literals — switching themes (or running the `/admin/theme` editor) only updates the var, not hardcoded hex.
- For alpha variants in hand-rolled CSS, use the four-arg form: `rgb(var(--color-primary-rgb) / 0.2)`.

## Toast manager z-index override

The studio-engine `_flash.html.erb` partial ships toasts at `z-index: 60` (above most content but below sticky-fixed-tops). Turf Monster overrides this with the engine's CSS custom properties — `--studio-toast-z: 200` and `--studio-toast-blur-z: 199`, set on `:root` in `app/assets/tailwind/application.css:95-98` and read by studio-engine 0.4.10+ — so toasts render **above** both the sticky navbar AND any open modal. Without this, the sticky navbar (`z-[130]`, `_navbar.html.erb:27`) and the modal host backdrop (`z-[120]`) eclipse the toast. If you change the modal z-index, update the toast override too — the rule is "toast always wins".

The override used to live in an inline `<style>` block in `_navbar.html.erb` and needed `!important` to beat the engine's old inline `style="z-index:60"`. The engine no longer renders that inline style, so the variable-based override now wins by normal cascade. Only the explanatory comment remains in the navbar, at `_navbar.html.erb:15-20`.

## Test scaffolding feature flag (`ENABLE_TEST_SCAFFOLDING`)

When set, the env flag enables two scaffold-only UI elements visible to admins for end-to-end-with-real-money testing without real cost:

- A **`$1 tiny` contest tier** in `Contest::FORMATS` — same payout shape as `tiny`, $1 entry fee. Lets you exercise the full Stripe + entry-token + onchain flow with pocket change.
- A **`test_trio` token pack** (`StripePurchase::PACKS`) — 3 tokens for $5. Surfaces in the auth modal's `tokens-picker` step as a third option alongside `single` ($19) and `trio` ($49). Gated by `StripePurchase.available_packs` + `AppFlags.test_scaffolding?`.

Unset before public launch — the `$1` tier and `$5/3` pack are not customer-facing offers. Memory ref: `project_turf_test_scaffolding`.

## Seeds bar refactor (v0.9.0+)

The 5-section seeds progress bar (`components/_seeds_bar.html.erb`) was refactored from per-segment classes (`.seeds-bar` / `.seeds-fill` / `.seeds-text`) to a single `.seeds-bar-continuous` class plus a CSS-registered `--bar-progress` custom property.

**Why**: per-segment classes meant 5 separate width transitions chained together — each segment's animation curve restarted at the segment boundary, producing a visible staircase. The continuous form interpolates all 5 segment widths from a single transition driven by one variable; per-section shimmer overlays positioned in bar coordinates (`left: -(i-1)*100%, width: 500%`) keep the wave continuous across segments. The result: one ease curve over the whole bar, not 5 chained ones. CSS-only — no JS animation loop.
