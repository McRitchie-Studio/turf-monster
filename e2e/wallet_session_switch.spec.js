const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

test.beforeEach(async ({ request }) => await reseed(request));

test("changing Phantom accounts starts a deliberate signed session handoff", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: true });
  await loginViaPhantom(page);

  const originalUserId = await page.locator("body").getAttribute("data-user-id");
  await page.evaluate(() => Alpine.store("modals").open("onboarding", {}));
  await expect(page.getByRole("dialog")).toContainText("What should we call you?");

  await page.evaluate(() =>
    window.phantom.solana.__switchAccount(2, { transientNull: true })
  );

  const dialog = page.getByRole("dialog");
  // The card names the handoff as a labelled from -> to pair now; the old
  // "It looks like you changed your wallet" subtitle restated the title.
  await expect(dialog).toContainText("Wallet changed");
  await expect(dialog).toContainText("Session");
  await expect(dialog).toContainText("Wallet");
  await expect(page).not.toHaveURL(/\/signin/);

  await page.keyboard.press("Escape");
  await expect(dialog).toBeVisible();
  await page.mouse.click(5, 5);
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Start New Session" })).toBeVisible();

  await dialog.getByRole("button", { name: "Start New Session" }).click();
  await expect.poll(async () => page.locator("body").getAttribute("data-user-id"))
    .not.toBe(originalUserId);
  await expect(page).not.toHaveURL(/\/signin/);
  // The HANDOFF card is gone — asserted on the modal stack rather than on "no
  // dialog at all", because the reload after a successful switch can legitimately
  // open a different card (the onboarding chain) for the wallet now signed in.
  await expect
    .poll(async () =>
      page.evaluate(() => {
        try {
          return Alpine.store("modals").isOpen("wallet-changed");
        } catch (e) {
          return false;
        }
      })
    )
    .toBe(false);
});

test("refocusing recovers when Phantom misses its account-change event", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);

  await page.evaluate(async () => {
    await window.phantom.solana.__switchAccount(3, { emitEvent: false });
    window.dispatchEvent(new Event("focus"));
  });

  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Wallet changed");
  await expect(dialog.getByRole("button", { name: "Start New Session" })).toBeVisible();
  await expect(page).not.toHaveURL(/\/signin/);
});
