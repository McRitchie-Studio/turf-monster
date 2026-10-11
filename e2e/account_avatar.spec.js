const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const IMG = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Avatar upload routes its save through the same window.submitFormWithProgress
// helper as the contest banner: a "saving" loading card shows while the upload
// is in flight. AccountsController#update REDIRECTS, so the card is opened
// dismissible — the reload's closeAllDismissible() clears it and the server
// flash toasts. The regression guard is that the card both appears AND clears
// (a non-dismissible card would survive the reload and stick on screen).
//
// Tagged @smoke: core account-update flow, part of the fast "general" e2e lane
// (`npm run test:smoke` / `--grep @smoke`). See docs/LOCAL_STACK.md.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Account avatar upload", () => {
  test("shows the loading card while saving, then clears on reload @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");

    // Picking a file opens crop-photo straight to the cropper (imageUrl passed).
    await page.locator('input[type="file"][accept="image/*"]').first().setInputFiles(IMG);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // /account is a signing page (SigningCsp), so the save's redirect ends in
    // a full load rather than a Turbo render, and a fast local upload can
    // finish before the card is seen. Hold the upload long enough to see it.
    await page.route("**/account", async (route) => {
      if (route.request().method() !== "GET") await new Promise((resolve) => setTimeout(resolve, 600));
      await route.continue();
    });
    await page.getByRole("button", { name: /Crop.*Save/ }).click();

    await expect(page.getByText("Saving photo")).toBeVisible();    // loading card during upload
    await expect(page.getByText("Account updated")).toBeVisible(); // flash toast after reload
    await expect(page.getByText("Saving photo")).toBeHidden();     // card cleared (not stuck)
  });
});
