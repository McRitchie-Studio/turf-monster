const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, stubQuestEndpoints } = require("./helpers");

// [e2e] The nine cards Turf now renders from studio-engine (studio-engine
// 0.114.0, turf-readopts-engine-modals) open, trap focus and close in a real
// browser, at a phone width and a desktop width, and the newsletter pair still
// completes its flow through the engine's JSON mode.
//
// WHY A BROWSER. The component test (test/integration/engine_modal_readoption_test)
// proves each id renders the engine block with this app's locals. It cannot prove
// the engine scope resolves on the page (studioNewsletterModal and
// studioModalCountdown are published by studio/alpine_scopes), that the host's
// focus trap holds over the new markup, or that the JSON mode reaches this app's
// routes through authedFetch, which the card imports from the
// "studio/host_fetchers" pin on the press. Each of those fails only at runtime.

const CARDS = [
  ["newsletter-subscribe", {}, "Join the Newsletter"],
  ["newsletter-email", {}, "One more thing"],
  ["newsletter-success", { seeds_earned: 25 }, "Subscribed!"],
  ["unsubscribe-confirm", {}, "Unsubscribe?"],
  ["unsubscribe-goodbye", {}, "See you later"],
  ["username", {}, /Username|Enter Contest First/],
  ["birthday", {}, "Your birthday"],
  ["rate-limit-general", { secondsLeft: 600 }, "Easy there"],
  ["email-change-pending", { currentEmail: "old@example.com", newEmail: "new@example.com" }, "Confirm your email change"],
];

test.beforeEach(async ({ request }) => await reseed(request));

async function openCard(page, id, props) {
  await page.waitForFunction(() => window.Alpine && Alpine.store("modals"));
  await page.evaluate(([id, props]) => Alpine.store("modals").open(id, props), [id, props]);
}

for (const width of [390, 1280]) {
  test(`at ${width}px each engine card opens, holds focus and closes on Escape`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await loginAdmin(page);
    await page.goto("/account");

    for (const [id, props, title] of CARDS) {
      await openCard(page, id, props);
      const dialog = page.getByRole("dialog");
      await expect(dialog.getByText(title).first(), `${id} did not open at ${width}px`).toBeVisible();

      // The host traps focus inside the card: tabbing past the last control
      // must wrap, never reach the page behind it.
      for (let i = 0; i < 8; i++) {
        await page.keyboard.press("Tab");
        const inside = await page.evaluate(() => {
          const d = document.querySelector("[role=dialog]");
          return !!d && d.contains(document.activeElement);
        });
        expect(inside, `${id}: focus left the card on Tab ${i + 1} at ${width}px`).toBe(true);
      }

      await page.keyboard.press("Escape");
      await expect(dialog, `${id} did not close on Escape at ${width}px`).toHaveCount(0);
    }
  });
}

test("the rate-limit card counts the 429's wait down and closes itself at zero", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/account");
  await openCard(page, "rate-limit-general", { secondsLeft: 2 });

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Easy there")).toBeVisible();
  await expect(dialog.getByText(/Try again in [12]s/)).toBeVisible();
  await expect(dialog, "the engine countdown must close the store at zero").toHaveCount(0, { timeout: 5000 });
});

test("the email-change card prints both addresses and Got it closes it", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/account");
  await openCard(page, "email-change-pending", { currentEmail: "old@example.com", newEmail: "new@example.com" });

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("old@example.com")).toBeVisible();
  await expect(dialog.getByText("new@example.com")).toBeVisible();
  await dialog.getByRole("button", { name: "Got it" }).click();
  await expect(dialog).toHaveCount(0);
});

test("joining from the account card posts JSON through authedFetch and lands on Subscribed!", async ({ page }) => {
  await loginAdmin(page);
  await stubQuestEndpoints(page);
  await page.goto("/account");
  await page.evaluate(async () => {
    await fetch("/account/newsletter/unsubscribe", {
      method: "POST",
      headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "", "Accept": "application/json" },
    });
  });
  await page.goto("/account");

  // The +25 seeds ride the engine's newsletter-state-changed event into the
  // StateFanout listener in shared/_alpine_factories.
  // Spy on StateFanout itself, by the source the listener names: other code
  // repaints the navbar on its own, so a navbar event alone proves nothing.
  await page.waitForFunction(() => window.StateFanout && window.StateFanout.apply);
  await page.evaluate(() => {
    window.__fanoutSources = [];
    const apply = window.StateFanout.apply;
    window.StateFanout.apply = function (type, payload, opts) {
      window.__fanoutSources.push(type + ":" + ((opts && opts.source) || ""));
      return apply.apply(this, arguments);
    };
  });
  const posted = page.waitForRequest((r) => r.url().endsWith("/account/newsletter/subscribe") && r.method() === "POST");
  await page.locator("[data-studio-controller~=newsletter-state]").getByRole("button", { name: /^subscribe$/i }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Join the Newsletter")).toBeVisible();
  await dialog.getByRole("button", { name: /^subscribe$/i }).click();

  const request = await posted;
  expect(request.headers()["content-type"]).toContain("application/json");
  await expect(dialog.getByText("Subscribed!"), "the engine card did not step to this app's success card").toBeVisible();
  await page.waitForFunction(() => window.__fanoutSources.includes("seeds:newsletter-modal"), null, { timeout: 5000 });
  // The slot this app hands the engine card: the first-join seeds bar.
  await expect(dialog.locator("[x-data='seedsBar()']")).toBeVisible();
});

test("leaving from the account card swaps to the goodbye beat and flips the card", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/account");
  await page.evaluate(async () => {
    await fetch("/account/newsletter/subscribe", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "", "Accept": "application/json" },
      body: JSON.stringify({ email: null }),
    });
  });
  await page.goto("/account");

  const card = page.locator("[data-studio-controller~=newsletter-state]");
  await card.getByRole("button", { name: /^unsubscribe$/i }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Unsubscribe?")).toBeVisible();
  await dialog.getByRole("button", { name: /^unsubscribe$/i }).click();

  await expect(dialog.getByText("See you later")).toBeVisible();
  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(dialog).toHaveCount(0);
  // newsletter-state-changed reached the account card's controller.
  await expect(card.getByRole("button", { name: /^subscribe$/i })).toBeVisible();
});
