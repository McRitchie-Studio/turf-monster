# Fiat rails (parked)

The fiat payment rails — Stripe, PayPal/Venmo, Coinflow and Aeropay — are
parked. Their code, tests and migrations stay in the tree for a later season,
and one flag keeps every entry point unreachable.

## The flag

| Variable | Meaning |
|---|---|
| `ENABLE_FIAT_RAILS` | `"true"` un-parks the rails. Unset (the default everywhere) keeps them parked. Read by `AppFlags.fiat_rails?`. |
| `FIAT_RAILS_OVERRIDE` | Live production only: the reason the rails are on. Without it, a live-production boot with the flag on raises `AppFlags::FiatRailsRefused` (`config/initializers/fiat_rails_guard.rb`). QA, development and test need no override. |

The per-provider switches (`PAYMENT_PROVIDER`, `STRIPE_CHECKOUT_DISABLED`,
`ENABLE_COINFLOW`, `ENABLE_AEROPAY`, the provider keys) still exist and answer
only when the master flag is on: `Payments.provider` reads `"none"`,
`AppFlags.coinflow?` and `AppFlags.aeropay?` read false, and
`onramp_rail_visible?` hides every fiat rail while parked.

The test suite (`test/test_helper.rb`) and both e2e lanes
(`playwright.config.js`, `bin/e2e-parallel`) run with the flag on, so the
parked code keeps its coverage.

## What is parked

`app/services/fiat_rails_parked.rb` is the list. While parked:

- **Routes answer 404** (`FiatRailsGate`, prepended in `ApplicationController`,
  so it runs before login, CSRF and click tracking):
  `POST /tokens/stripe_checkout`, `/tokens/paypal_order`, `/tokens/paypal_capture`,
  `/tokens/coinflow_order`, `/tokens/aeropay_order`,
  `/tokens/coinflow_simulate_settle` and `/tokens/aeropay_simulate_settle`
  (non-production only), `GET /tokens/processing`, `GET /tokens/status`,
  `POST /wallet/stripe_deposit`.
- **Webhooks answer 404**: `POST /webhooks/stripe`, `/webhooks/paypal`,
  `/webhooks/coinflow`, `/webhooks/aeropay`. A provider that still posts gets a
  404, retries on its own schedule, and gives up; nothing is recorded here.
- **Jobs skip** with a `[fiat-parked]` WARN line (`FiatRailsJobGate` in
  `ApplicationJob`): `TokenPurchaseJob`, `StripeDepositJob`,
  `PendingDepositReconcilerJob`. The reconciler's cron entry in
  `config/schedule.yml` stays registered and skips each tick.
- **Views hide**: the `/tokens/buy` fiat sections, the wallet-deposit "Pay with
  Card" form, the Coinflow, Aeropay, PayPal/Venmo and Stripe rails in the Add
  Funds hub and the Buy an Entry Token card, and the Stripe and PayPal steps
  of the auth wizard. `/tokens/buy` itself stays up: it also carries the
  Coinbase card and is where new signups land.

Not parked, because they are not fiat provider rails: the Coinbase CDP ramp
(`ENABLE_CDP_RAMP`), the manual withdrawal queue (`POST /wallet/withdraw`), the
admin dev mint, and the read-only `pending_deposits:reconcile` rake task.

`test/services/fiat_rails_parked_inventory_test.rb` discovers fiat
controllers, routes, jobs and views on disk and fails when one is missing from
the list. `test/integration/fiat_rails_parked_test.rb` proves the 404s, the
hidden views and the skipped jobs, each with a flag-on control.

## Parking safely

Switch the flag off only when nothing is in flight: no purchase row in
`pending` or `captured` in `stripe_purchases`, `paypal_purchases`,
`coinflow_purchases` or `aeropay_purchases`, and no `pending` deposit in
`transaction_logs`. A parked job acknowledges and drops its work, so a paid
purchase still waiting to mint would be stranded.

## Un-parking checklist

1. Provider keys and webhook secrets are set (see `.env.example` and
   `docs/PAYPAL_VENMO.md`), and the provider's webhook endpoint is registered
   against this app.
2. The per-provider switch for each rail is on (`PAYMENT_PROVIDER`,
   `ENABLE_COINFLOW`, `ENABLE_AEROPAY`).
3. QA runs the rail end to end with `ENABLE_FIAT_RAILS=true` and the provider's
   sandbox.
4. Production sets `ENABLE_FIAT_RAILS=true` and `FIAT_RAILS_OVERRIDE` to the
   reason, through the release lane.
5. The full test suite and the e2e financial specs pass.
