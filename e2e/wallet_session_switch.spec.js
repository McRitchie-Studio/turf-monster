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
  await expect(dialog).toContainText("It looks like you changed your wallet.");
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
  await expect(page.getByText("It looks like you changed your wallet.")).toHaveCount(0);
});

test("refocusing recovers when Phantom misses its account-change event", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);

  await page.evaluate(async () => {
    await window.phantom.solana.__switchAccount(3, { emitEvent: false });
    window.dispatchEvent(new Event("focus"));
  });

  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("It looks like you changed your wallet.");
  await expect(dialog.getByRole("button", { name: "Start New Session" })).toBeVisible();
  await expect(page).not.toHaveURL(/\/signin/);
});
