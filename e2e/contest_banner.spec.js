const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, recordShown } = require("./helpers");
const path = require("path");

const BANNER_WIDE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin banner editor on the contest EDIT screen (PR #29). "Edit banner" opens
// the shared crop-photo modal in dropzone + dispatch mode; "Crop & Save" shows a
// loading card, saves immediately (update_banner), then toasts + refreshes the
// preview. The modal locks (no click-outside) once cropping starts.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Contest banner editor (edit screen)", () => {
  test("admin frames, saves, and gets loading + toast feedback", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026/edit");

    await page.getByRole("button", { name: "Edit banner" }).click();
    await page.locator('input[type="file"][accept="image/*"]').setInputFiles(BANNER_WIDE);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // Cropping mode locks the modal — a backdrop click must NOT close it.
    await page.mouse.click(5, 5);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // Crop & Save -> loading card -> Turbo upload response -> success toast -> refreshed preview.
    const bannerSave = page.waitForResponse((response) =>
      ["PATCH", "POST"].includes(response.request().method()) && response.url().includes("/banner")
    );
    // The saving card is held 450ms; record it from the page, since a polling
    // assertion can look either side of it (e2e/helpers.js recordShown).
    const savingShown = await recordShown(page, "Saving banner");
    await page.getByRole("button", { name: /Crop.*Save/ }).click();
    const bannerResponse = await bannerSave;
    expect(bannerResponse.ok()).toBeTruthy();
    await expect(page.getByText("Banner updated")).toBeVisible({ timeout: 15_000 });
    expect(await savingShown(), "the saving card showed while the banner saved").toBe(true);
    await expect(page.locator("#contest-banner-preview img")).toBeVisible();
  });

  test("the actions dropdown reaches the edit screen's banner control", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    await page.getByRole("button", { name: "Contest actions" }).click();
    await Promise.all([
      page.waitForURL(/\/edit$/),
      page.getByRole("link", { name: "Edit Contest" }).click(),
    ]);
    await expect(page.getByRole("button", { name: "Edit banner" })).toBeVisible();
  });
});
