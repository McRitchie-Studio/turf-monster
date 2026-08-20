const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Wallet & Transactions", () => {
  test("wallet page loads with USDC balance", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.getByRole("heading", { name: "Wallet", exact: true })).toBeVisible();
    await expect(page.locator("body")).toContainText("USDC Balance");
    await expect(page.locator("body")).toContainText("Available to Play");
    // Balance should show a dollar amount (don't check exact value — tests share state)
    await expect(page.locator("body")).toContainText(/\$\d+\.\d{2}/);
  });

  test("wallet shows wallet address", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.locator("body")).toContainText("Wallet Address");
  });

  test("wallet shows faucet link", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/wallet");
    await expect(page.locator("body")).toContainText("Get USDC");
    await expect(page.locator('a:has-text("Faucet Page")')).toBeVisible();
  });
});

test.describe("Admin Transaction Log", () => {
  test("admin can view transaction log", async ({ page }) => {
    await loginAdmin(page);

    // Transaction log should have the pre-seeded faucet transaction
    await page.goto("/admin/transactions");
    await expect(page.getByRole("heading", { name: "Transaction Log" })).toBeVisible();
    await expect(page.locator("body")).toContainText("faucet");
  });

  test("admin transaction log detail page", async ({ page }) => {
    await loginAdmin(page);

    // Navigate to admin transactions and click first description link in the table
    await page.goto("/admin/transactions");
    await page.locator("table a").first().click();

    // Wait for navigation away from the index — the show view may need a cold
    // compile, which races the default 5s assertion timeout.
    await page.waitForURL(/\/admin\/transactions\/[^/]+$/);
    await expect(page.getByRole("heading", { name: "Transaction Detail" })).toBeVisible({ timeout: 10_000 });
    await expect(page.locator("body")).toContainText("$10.00");
  });

  test("admin can filter by type", async ({ page }) => {
    await loginAdmin(page);

    // Navigate to admin transactions and click a filter link (e.g. "faucet" in the type column)
    await page.goto("/admin/transactions");
    // Click the faucet type badge/link in the table (not the navbar link)
    await page.locator("table a:has-text('faucet')").first().click();

    // Should navigate to a filtered or detail page
    await expect(page.locator("body")).toContainText("faucet");
  });
});

// Coinflow buy-1-entry rail. The hosted-checkout redirect and Coinflow's REST
// API can't run in CI, so we stub at the Coinflow network boundary two ways:
//   1. Browser side — page.route intercepts POST /tokens/coinflow_order and the
//      hosted-checkout redirect, so no real Coinflow call leaves the box. This
//      asserts OUR client wiring: button -> order endpoint -> redirect to link.
//   2. Server side — we drive the Settled webhook directly with the shared
//      secret and assert the endpoint authenticates + acks.
// The settlement -> on-chain mint money path is covered authoritatively (with a
// real DB row) by the Rails tests: test/controllers/webhooks/
// coinflow_controller_test.rb + test/jobs/token_purchase_job_test.rb.
//
// Gated on ENABLE_COINFLOW so the default CI run (flag off) skips it; enable the
// flag on the e2e stack to exercise it.
test.describe("Coinflow entry-token buy", () => {
  test.skip(
    process.env.ENABLE_COINFLOW !== "true",
    "ENABLE_COINFLOW is off — the Coinflow rail is hidden",
  );

  test("buy-1 button posts to the order endpoint and redirects to the hosted link", async ({ page }) => {
    await loginAdmin(page);

    const fakeLink = "https://sandbox-merchant.coinflow.cash/purchase-v2/e2e-fake";
    let orderPosted = false;
    let redirectHit = false;

    // Stub the order endpoint (the Coinflow network boundary from the client's
    // view): return a deterministic hosted-checkout link, no real Coinflow call.
    await page.route("**/tokens/coinflow_order", async (route) => {
      orderPosted = true;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ link: fakeLink, reference: "coinflow_e2e_fake" }),
      });
    });
    // Catch the redirect so the browser never leaves the box.
    //
    // CONTEXT-level, not page-level, and that is the whole reason this spec failed the
    // first time it was ever allowed to run. tokens/_coinflow_script.html.erb opens the
    // hosted checkout in a POPUP —
    //   var checkoutTab = window.open('', '_blank');
    //   if (checkoutTab) { checkoutTab.location = d.link; ... }
    //   else { window.location = d.link; }   // same-tab only when the popup is blocked
    // — so the navigation happens on a DIFFERENT Page object. `page.route` sees only the
    // original page and would never fire, while the order POST above (same page) passes:
    // exactly the shape observed — orderPosted true, redirectHit false.
    //
    // Routing on the context covers both the popup and the same-tab fallback, so this
    // asserts what the app actually does rather than what it used to.
    await page.context().route("**/purchase-v2/**", async (route) => {
      redirectHit = true;
      await route.fulfill({ status: 200, contentType: "text/html", body: "<html><body>coinflow stub</body></html>" });
    });

    await page.goto("/tokens/buy");
    // The rail now renders one card PER PACK plus the dev simulate button, so a
    // bare [data-coinflow-buy] button locator matches N elements and trips
    // Playwright strict mode. Pin the single-entry card by its own click target.
    const buyButton = page.locator(
      '[data-coinflow-buy] button[onclick*="tmCoinflowBuyOne(\'single\')"]',
    );
    await expect(buyButton).toBeVisible();
    await buyButton.click();

    // The client hit the order endpoint and followed the returned link.
    await expect.poll(() => orderPosted).toBe(true);
    await expect.poll(() => redirectHit).toBe(true);
  });

  test("Settled webhook authenticates with the shared secret and acks", async ({ request }) => {
    const key = process.env.COINFLOW_WEBHOOK_VALIDATION_KEY;
    test.skip(!key, "COINFLOW_WEBHOOK_VALIDATION_KEY not set on the e2e stack");

    // Wrong secret → 401.
    const bad = await request.post("/webhooks/coinflow", {
      headers: { Authorization: "WRONG", "Content-Type": "application/json" },
      data: { eventType: "Settled", id: "e2e_pay_bad", subtotal: { cents: 1900, currency: "USD" } },
    });
    expect(bad.status()).toBe(401);

    // Correct secret → 200 ack (unmatched customer is a safe no-op).
    const ok = await request.post("/webhooks/coinflow", {
      headers: { Authorization: key, "Content-Type": "application/json" },
      data: {
        eventType: "Settled",
        id: "e2e_pay_ok",
        subtotal: { cents: 1900, currency: "USD" },
        customerId: "tm_user_0",
      },
    });
    expect(ok.status()).toBe(200);
  });
});

// Aeropay bank-payment entry-token rail (Turf's Coinflow hedge). Aeropay's REST
// API + Aerosync bank-link widget can't run in CI, so we stub at the boundary:
// browser-side stubs POST /tokens/aeropay_order (asserts button -> bank-link ->
// order-endpoint wiring), and the server side drives the transaction_completed
// webhook with a valid HMAC signature and asserts the endpoint authenticates.
// The settlement -> on-chain mint money path is covered authoritatively by the
// Rails tests (webhooks/aeropay_controller_test.rb + token_purchase_job_test.rb).
// Gated on ENABLE_AEROPAY so the default CI run (flag off) skips it.
test.describe("Aeropay entry-token buy", () => {
  test.skip(
    process.env.ENABLE_AEROPAY !== "true",
    "ENABLE_AEROPAY is off — the Aeropay rail is hidden",
  );

  test("buy-1 button links a bank then posts to the aeropay order endpoint", async ({ page }) => {
    await loginAdmin(page);

    let orderPosted = false;
    await page.route("**/tokens/aeropay_order", async (route) => {
      orderPosted = true;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ status: "pending", reference: "aeropay_e2e_fake" }),
      });
    });

    await page.goto("/tokens/buy");
    const buyButton = page.locator('[data-aeropay-buy] button').first();
    await expect(buyButton).toBeVisible();
    await buyButton.click();

    await expect.poll(() => orderPosted).toBe(true);
  });

  test("transaction_completed webhook authenticates with the HMAC signature", async ({ request }) => {
    const key = process.env.AEROPAY_WEBHOOK_SIGNING_KEY;
    test.skip(!key, "AEROPAY_WEBHOOK_SIGNING_KEY not set on the e2e stack");
    const crypto = require("crypto");

    const body = JSON.stringify({
      topic: "transaction_completed",
      data: { id: "e2e_txn_ok", amount: "19.00", currency: "USD", customerId: "tm_user_0" },
    });
    const sig = crypto.createHmac("sha256", key).update(body).digest("hex");

    // Wrong signature -> 401.
    const bad = await request.post("/webhooks/aeropay", {
      headers: { "X-Aeropay-Signature": "WRONG", "Content-Type": "application/json" },
      data: body,
    });
    expect(bad.status()).toBe(401);

    // Correct signature -> 200 ack (unmatched customer is a safe no-op).
    const ok = await request.post("/webhooks/aeropay", {
      headers: { "X-Aeropay-Signature": sig, "Content-Type": "application/json" },
      data: body,
    });
    expect(ok.status()).toBe(200);
  });
});
