const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const IMG = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// [e2e] /admin/emails — the shared engine email manager, after turf-monster
// retired its own Admin::EmailsController + ::EmailCatalog in favour of it.
//
// What only a browser can prove, and what the integration suite therefore
// cannot: the banner images actually LOAD (a registered default_asset that
// resolves to a 404 renders as a broken image while every server-side
// assertion still passes), and the upload runs through the shared crop modal
// on the page-scoped `emailModals` store — a store that fails to register
// leaves the Upload button inert with no server-side symptom at all.
//
// Tagged @smoke: this is the only admin surface for every email the app sends.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Admin emails manager", () => {
  test("lists every registered email with a banner that loads @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/emails");

    const rows = page.locator("tbody tr");
    await expect(rows).toHaveCount(8);

    // Names come from the registry, not the view.
    await expect(page.getByText("Magic-link sign-in")).toBeVisible();
    await expect(page.getByText("Contest winnings")).toBeVisible();
    await expect(page.getByText("Newsletter welcome")).toBeVisible();

    // The marketing badge distinguishes the one non-transactional email.
    await expect(page.locator("tbody").getByText("Marketing")).toHaveCount(1);

    // Every banner must RESOLVE. naturalWidth === 0 on a loaded <img> is the
    // broken-image case, which no server-side test can see.
    const broken = await page.evaluate(() =>
      [...document.querySelectorAll("tbody img")].filter((i) => i.complete && i.naturalWidth === 0).length
    );
    expect(broken).toBe(0);
  });

  test("an email's own page previews the real rendered email @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/emails");
    await page.getByRole("link", { name: "Magic-link sign-in" }).click();

    await expect(page).toHaveURL(/\/admin\/emails\/magic_link$/);
    await expect(page.getByText("Transactional")).toBeVisible();

    // The preview is an iframe over /admin/emails/:key/raw — the actual email
    // document, banner and all.
    const frame = page.frameLocator("iframe");
    await expect(frame.locator("img").first()).toBeVisible();
  });

  test("upload goes through the shared crop modal @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/emails");

    // The page mounts its OWN modal host (emailModals) because not every app
    // renders a shared one. If that store fails to register, this click is a
    // no-op and the modal never appears.
    await page.getByRole("button", { name: /^(Upload|Replace)$/ }).first().click();
    await expect(page.getByText("Crop Photo")).toBeVisible();

    await page.locator('input[type="file"][x-ref="filePicker"]').setInputFiles(IMG);
    await expect(page.locator(".cropper-container")).toBeVisible();

    await page.getByRole("button", { name: /Crop & Save/i }).click();

    // Saving lands the row on this app's own image, with a way back.
    await expect(page.getByRole("button", { name: "Revert" }).first()).toBeVisible({ timeout: 20000 });
  });
});
