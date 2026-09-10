const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, stubQuestEndpoints } = require("./helpers");

// [e2e] The newsletter card on /profile opens THIS APP'S modal flow.
//
// WHY A BROWSER, and why this spec rather than a markup assertion. The engine's
// registry decides which partial renders the newsletter row, and this app
// replaces the engine's row with its own so that clicking Subscribe opens the
// five-modal flow /account has walked people through since the quest system
// shipped — "…and 25 seeds for joining", the web3 email capture, the success
// card, and the confirm-then-goodbye pair on the way out.
//
// A server-side test can assert the button carries
// `@click="$store.modals.open('newsletter-subscribe')"`. That string is in the
// markup whether or not the shared store exists ON THIS PAGE, whether or not the
// layout's modal host mounted here, and whether or not the id matches a
// registered template. Those modals are registered in
// layouts/application.html.erb — a DIFFERENT file from the row that opens them —
// so "the button says the right thing" and "the dialog opens on /profile" are
// genuinely separate claims, and only a browser can make the second one.
// ANCHORED BUTTON NAMES THROUGHOUT. `/subscribe/i` also matches "Unsubscribe" —
// on a subscribed account the first version of this spec clicked the wrong
// button, opened the confirm-leaving modal, and reported that the subscribe modal
// "did not open on /profile". The app was fine; the regex was not.
test.beforeEach(async ({ request }) => await reseed(request));

// The seeded account's subscription state is not something this spec should
// inherit — `reseed` does not reset it, and asserting against "whichever state
// turned up" is how a spec passes for the wrong reason. Each test below puts the
// account where it needs it first, through the app's own endpoint.
async function ensureUnsubscribed(page) {
  await page.goto("/account");
  await page.evaluate(async () => {
    await fetch("/account/newsletter/unsubscribe", {
      method: "POST",
      headers: {
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        "Accept": "application/json",
      },
    });
  });
}

test("the profile newsletter card opens the app's subscribe modal", async ({ page }) => {
  await loginAdmin(page);
  await stubQuestEndpoints(page);
  await ensureUnsubscribed(page);
  await page.goto("/profile");

  const card = page.locator('[data-profile-section="newsletter"]');
  await expect(card).toBeVisible();

  // Nothing open yet, so the assertion below is a TRANSITION rather than a state
  // the page was already in.
  await expect(page.getByRole("dialog")).toHaveCount(0);

  await card.getByRole("button", { name: /^subscribe$/i }).click();

  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByText("Join the Newsletter"),
    "the app's subscribe modal did not open on /profile — the shared store, the layout's host, or the modal id"
  ).toBeVisible();

  // THE REWARD IS THE WHOLE REASON this app replaced the engine's row. The
  // engine's plain form says nothing about seeds; if this copy is missing, the
  // engine's row is what rendered.
  await expect(dialog.getByText(/25 seeds/i)).toBeVisible();
});

// SUBSCRIBING THROUGH THE MODAL, end to end from /profile. The subscribe POST is
// stubbed (stubQuestEndpoints), so this asserts the FLOW — card opens the modal,
// the modal posts, the success card appears — without touching the chain.
//
// Written without a conditional or a swallowed catch: a spec that quietly skips
// when the account is in the wrong state is a spec that passes for the wrong
// reason. reseed() in beforeEach puts the account in a known one.
test("subscribing from the profile card reaches the success modal", async ({ page }) => {
  await loginAdmin(page);
  await stubQuestEndpoints(page);
  await ensureUnsubscribed(page);
  await page.goto("/profile");

  const card = page.locator('[data-profile-section="newsletter"]');
  await card.getByRole("button", { name: /^subscribe$/i }).click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Join the Newsletter")).toBeVisible();

  await dialog.getByRole("button", { name: /^subscribe$/i }).click();

  await expect(
    dialog.getByText("Subscribed!"),
    "the modal posted but the success card never came — the flow stops half-way on /profile"
  ).toBeVisible();
});
