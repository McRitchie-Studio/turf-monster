// Quests via /account — web3 (Phantom, no email) user.
//
// OFF the contest page there is no quest card to advance in place, so the same
// quest actions take the MODAL route instead:
//   username change  -> the studio:username-saved listener swaps in the
//                       'quest-success' celebration ("Great Username")
//   Next Quest        -> swaps to 'newsletter-subscribe'
//   newsletter join   -> swaps to 'newsletter-success' ("Subscribed!")
//
// The point of doing this as a WEB3 user: web3 accounts have no email on file,
// so the newsletter-subscribe modal must render the ADD-EMAIL field (web2 users
// skip it). This spec confirms that field (a) appears, (b) is required, and
// (c) its value reaches the subscribe request.
//
// CHAINLESS NOTE: the username + newsletter seed grants are on-chain and don't
// fire for off-chain e2e contests — stubbed (see stubQuestEndpoints). We assert
// modal flow + the add-email wiring, not on-chain seed totals.

const { test, expect } = require("@playwright/test");
const {
  loginViaPhantom,
  setupPhantomMock,
  reseed,
  createActiveEntry,
  stubQuestEndpoints,
} = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";

test.beforeEach(async ({ request }) => await reseed(request));

test("web3 user completes the username + newsletter quests from /account", async ({ page }) => {
  test.setTimeout(60_000);

  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  // can_change_username? needs an entry — without it the username modal renders
  // its locked "Enter Contest First" state instead of the rename form.
  await createActiveEntry(page, CONTEST_SLUG);
  await stubQuestEndpoints(page);
  await page.goto("/account");

  const dialog = page.getByRole("dialog");

  // --- Username quest -> quest-success celebration -------------------------
  await page.getByRole("button", { name: "Change username" }).click(); // /account trigger
  await dialog.getByPlaceholder("username").fill("acct-quest-9");
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(dialog.getByText("Great Username")).toBeVisible(); // quest-success modal

  // --- Hand off to the newsletter-subscribe modal --------------------------
  await dialog.getByRole("button", { name: "Next Quest" }).click();
  await expect(dialog.getByText("Join the Newsletter")).toBeVisible();

  // web3 (no email) -> the ADD-EMAIL field must be present.
  const emailField = dialog.getByPlaceholder("you@example.com");
  await expect(emailField).toBeVisible();

  // The add-email field is REQUIRED: subscribing with it empty surfaces the
  // inline validation error and makes NO request.
  await dialog.getByRole("button", { name: "Subscribe" }).click();
  await expect(dialog.getByText("Enter a valid email address.")).toBeVisible();

  // Fill it + subscribe — the captured email must reach the POST body (proves
  // the add-email field works end to end), then the success modal appears.
  await emailField.fill("web3-acct@example.com");
  const [req] = await Promise.all([
    page.waitForRequest(
      (r) => r.url().includes("/account/newsletter/subscribe") && r.method() === "POST"
    ),
    dialog.getByRole("button", { name: "Subscribe" }).click(),
  ]);
  expect(JSON.parse(req.postData() || "{}").email).toContain("@");
  await expect(dialog.getByText("Subscribed!")).toBeVisible(); // newsletter-success modal
});
