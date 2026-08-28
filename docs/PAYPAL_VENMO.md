# PayPal / Venmo Onramp — go-live runbook

PayPal-rails replacement for the (blocked) Stripe account: Venmo + PayPal
buttons backed by Orders v2. Built sandbox-first and fully flag-gated —
`PAYMENT_PROVIDER` unset means no fiat checkout. Stripe is a dormant legacy
fallback and must be explicitly selected with `PAYMENT_PROVIDER=stripe`.

## Architecture (backend)

| Piece | File |
|---|---|
| Provider flag | `app/services/payments.rb` (`Payments.provider`, default `"none"`) |
| REST client (OAuth2 + Orders v2 + webhook verify) | `app/services/paypal/client.rb` — every call audited via `OutboundRequest` (service `paypal`) |
| Audit model | `app/models/paypal_purchase.rb` (`pending → captured → minted`; `refunded`/`failed`) |
| Order create / capture endpoints | `TokensController#paypal_order` / `#paypal_capture` (POST, JSON) |
| Status polling | `GET /tokens/status?order_id=…` (same payload as the Stripe `session_id` path) |
| Webhooks | `Webhooks::PaypalController` at `POST /webhooks/paypal` |
| Mint | `TokenPurchaseJob` (`purchase_type: "paypal"`, source_ref `paypal:<purchase_id>:<i>`) |
| Exactly-once gate | `PaypalPurchase#begin_fulfillment!` (atomic `pending → captured` CAS) via `Paypal::Fulfillment` |
| Boot guards | `config/initializers/paypal.rb` (OPSEC-032 parity) |

Fulfillment fires on `PAYMENT.CAPTURE.COMPLETED`. `CHECKOUT.ORDER.APPROVED` is
the client-died fallback (server-side capture when our purchase is still
pending). `PAYMENT.CAPTURE.DENIED` → failed. `PAYMENT.CAPTURE.REFUNDED` →
refunded + account frozen. `CUSTOMER.DISPUTE.CREATED` → payment-risk flag +
frozen (Stripe OPSEC-036 / B4 parity).

Operational notes:

- **Webhook redeliveries don't double-mint-race**: `Paypal::Fulfillment` only
  re-enqueues a captured-but-unminted row once it's been stranded longer than
  `STRANDED_AFTER` (5 min) — a redelivery landing while the winner's job is
  still minting is a no-op, so the happy path never runs two concurrent jobs
  racing the same source_refs.
- **Frozen / risk-flagged accounts**: the client endpoints 403; the
  `CHECKOUT.ORDER.APPROVED` fallback refuses to capture; and a
  `PAYMENT.CAPTURE.COMPLETED` for a frozen/flagged account records the capture
  (the money moved — forensics keep the trail) but does NOT mint —
  `[tokens] paypal.mint_blocked` flags it for manual review. After
  unfreezing, re-enqueue via console or a dashboard webhook resend (the
  stranded-row branch picks it up).
- **PENDING captures (eCheck / Venmo review holds)**: `paypal_capture` answers
  `{status: "processing"}` and the UI shows a do-not-retry hold card — the
  buyer HAS paid; the row stays `pending` until `PAYMENT.CAPTURE.COMPLETED`
  clears the hold and mints (days for eCheck). Never treat it as a failure:
  a "try again" retry creates a second order = a real double charge.
- **`status=pending` rows accumulate by design**: a row is created at
  button-click, BEFORE the buyer approves (for `Current.outbound_source`
  attribution), so every cancelled popup / abandoned checkout leaves a
  permanent pending row. Pending ≠ money owed — only `captured`/`minted`
  rows have a PayPal capture behind them.

## Architecture (frontend)

All UI is gated on `Payments.paypal_checkout?` (flag AND creds) — with the
provider on `stripe`, pages render without PayPal buttons/SDK output. One
deliberate exception: `contests/_turf_totals_board.html.erb` ships its
`paypal-order-captured` listener + the `pollTokenStatus(ref, refParam)`
generalization on every provider (inert on stripe — the event is only ever
dispatched from the flag-gated SDK partial), so an HTML diff against
pre-PayPal main will flag contest pages even with the flag off.

| Piece | File |
|---|---|
| SDK loader + `paypalButtons` Alpine factory | `app/views/tokens/_paypal_sdk.html.erb` — lazy `window.loadPaypalSdk()` injects the JS SDK on first button mount; `&buyer-country=US` appended in sandbox ONLY |
| Pack select + Venmo/PayPal buttons | `app/views/tokens/_paypal_buttons.html.erb` (`flow: "modal"` in the auth wizard, `flow: "page"` on `/tokens/buy` where it also owns the confirming/minted/errored cards) |
| Pack card select mode | `tokens/_pack_button` `select_js:`/`selected_expr:` locals (same orb-glow card, no checkout form) |
| Auth-modal picker branch | `app/views/modals/auth/_tokens.html.erb` (`tokens-picker` step) |
| Capture → wizard hand-off | `paypal-order-captured` window event → selectionBoard listener (`contests/_turf_totals_board.html.erb`) advances to `tokens-confirming` and runs `pollTokenStatus(orderId, 'order_id')` |
| CSP | `config/initializers/content_security_policy.rb` adds `*.paypal.com` / `*.venmo.com` frame-src only when `PAYMENT_PROVIDER=paypal` |

Flow: pack card selects → standalone Venmo (primary) / PayPal button →
`createOrder` POSTs `/tokens/paypal_order` (server derives the amount from the
pack id) → SDK popup / app-switch / desktop QR → `onApprove` POSTs
`/tokens/paypal_capture` → modal advances to the existing `tokens-confirming` →
`tokens-minted` steps (or the on-page status cards on `/tokens/buy`). Cancel and
error land back on the picker with an inline notice. There is NO new tab and NO
`/tokens/processing` leg — that page stays Stripe-only. The checkout overlay is
appended to `document.body` by the SDK, so the modal host (`z-[var(--z-modal)]`) never
clips it.

## Go-live gate — DO NOT skip

**Real-money gaming requires PayPal's pre-approval.** A PayPal Business
account accepting contest-entry payments without the gambling/skill-gaming
approval gets limited/frozen, with funds held 180 days. Before flipping
anything live:

1. PayPal Business account (US entity) in good standing.
2. Submit the skill-gaming/real-money application via PayPal merchant support
   and receive WRITTEN approval for turfmonster.media.
3. Only then proceed below.

## Live credentials + webhook

1. developer.paypal.com → Apps & Credentials → **Live** tab → Create App.
   Capture **Client ID** + **Secret**.
2. Same app → Webhooks → Add webhook:
   `https://turfmonster.media/webhooks/paypal`, subscribed to:
   `PAYMENT.CAPTURE.COMPLETED`, `CHECKOUT.ORDER.APPROVED`,
   `PAYMENT.CAPTURE.DENIED`, `PAYMENT.CAPTURE.REFUNDED`,
   `CUSTOMER.DISPUTE.CREATED`.
3. Capture the **Webhook ID** shown after saving — that is `PAYPAL_WEBHOOK_ID`
   (signature verification fails closed without it).

## Heroku flip

```sh
heroku config:set -a turf-monster-mainnet \
  PAYPAL_ENV=live \
  PAYPAL_CLIENT_ID=… \
  PAYPAL_CLIENT_SECRET=… \
  PAYPAL_WEBHOOK_ID=…
# the actual switch — until this, no buttons render and no NEW orders can be
# created. (Note: from the moment PAYPAL_WEBHOOK_ID is set above, the webhook
# endpoint will verify + ack deliveries — that's deliberate, so PayPal's
# endpoint health check passes before the flip.)
heroku config:set -a turf-monster-mainnet PAYMENT_PROVIDER=paypal
```

Boot guards (initializer): when `PAYMENT_PROVIDER=paypal` in production,
`PAYPAL_ENV` must be `live` and all three creds present or the app refuses to
boot.

**Rollback semantics — read before flipping back.** `PAYMENT_PROVIDER=none`
stops **new orders only**: `paypal_order` 422s and the buttons stop rendering.
`PAYMENT_PROVIDER=stripe` intentionally revives the dormant Stripe fallback
instead. `paypal_capture` and the webhook handlers deliberately stay live so
the in-flight pipeline drains — orders the buyer already approved still capture
+ mint, and refunds/disputes keep processing. If the rollback is because
**fulfillment itself is broken** (money moving through a bad path), the hard
kill is removing the creds: unset `PAYPAL_CLIENT_ID` /
`PAYPAL_CLIENT_SECRET` / `PAYPAL_WEBHOOK_ID` — capture calls then fail and
webhook verification fails closed (400), and you reconcile stranded purchases
manually afterwards.

## Post-flip smoke test

- Buy a `single` pack with a real account on **desktop** — the desktop Venmo
  flow is a QR code scanned from the Venmo app, and **sandbox cannot simulate
  QR at all**, so this is the first time that path runs. Verify: order →
  capture → `PaypalPurchase` minted → tokens visible in navbar.
- Check `/admin/outbound_requests?service=paypal` for the call trail and
  `grep "\[tokens\] paypal"` in logs.
- Webhook delivery: developer dashboard → Webhooks → Events shows 200s.

## Sandbox setup (local dev)

1. Sandbox app creds from the **Sandbox** tab → `.env`:
   `PAYPAL_ENV=sandbox`, `PAYPAL_CLIENT_ID/SECRET`, `PAYMENT_PROVIDER=paypal`.
2. JS SDK URL needs `&buyer-country=US` in sandbox ONLY (invalid in prod) or
   the Venmo button never renders.
3. Buyer logins: sandbox **Personal** account from developer.paypal.com →
   Testing Tools → Sandbox Accounts.
4. Webhooks locally: register a tunnel URL (or use the dashboard **Webhook
   simulator**) against the SANDBOX app and put that webhook id in
   `PAYPAL_WEBHOOK_ID`. Note the simulator sends generic payloads — they
   verify but won't match a real purchase row.
5. Amount-triggered sandbox errors: $12.34 insufficient funds, $21.43 account
   closed, $10.23 suspected fraud, $13.42 generic decline.
6. Sandbox CANNOT exercise: desktop QR, vaulted repeat purchases, disputes/
   settlement reporting.

## Production guards summary

- `Payments.paypal?` && creds present gate **order creation** (`paypal_order`,
  else 422). `paypal_capture` + the webhook are deliberately NOT
  provider-gated (rollback drains in-flight orders — see above); with the
  flag never flipped, capture 404s anyway (no pending rows can exist) and the
  webhook fails closed without `PAYPAL_WEBHOOK_ID`.
- Webhook signature verified via PayPal's verify-webhook-signature API with
  the RAW request body (fails closed when `PAYPAL_WEBHOOK_ID` unset).
- Sandbox events rejected in production (OPSEC-033 parity).
- Amounts validated server-side against `StripePurchase::PACKS` — capture must
  be `COMPLETED`, `USD`, exact pack amount, or no mint (`PENDING` + exact
  amount = processing hold, see operational notes).
- Frozen / payment-risk-flagged accounts can't order, capture, or be minted
  for — including via the webhook fallback (`Paypal::Fulfillment` gate).
- Rate limits: 10/min/IP on order+capture, 100/min/IP on the webhook (the
  routes are drawn `format: false` so a `.json` suffix can't sidestep the
  exact-path throttle matchers).
