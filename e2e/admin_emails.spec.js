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

    // Assert the table against what the SERVER says it registered, not against a
    // hardcoded total. The count is engine-owned and moves whenever the shared
    // catalogue does: studio-engine 0.42 added `newsletter_subscribed` to the
    // standard set, which took this app from 8 to 9 and failed a literal `8`
    // here — the third place that number had to be updated by hand. The page
    // prints "N email(s) registered" from Studio::EmailCatalog, so read that and
    // require a row for each, which is the property this spec actually claims
    // ("lists EVERY registered email").
    const summary = await page.locator("text=/\\d+ emails? registered/").first().innerText();
    const registered = parseInt(summary.match(/(\d+) emails? registered/)[1], 10);
    expect(registered).toBeGreaterThan(0);
    const rows = page.locator("tbody tr");
    await expect(rows).toHaveCount(registered);

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

  // SCOPE NOTE — read before "strengthening" this test.
  //
  // It stops at "the form submitted and the page came back". It deliberately
  // does NOT assert that the row became app-owned, because the banner write
  // goes through Studio::S3 to a REAL bucket, and CI runs with deliberately
  // dummy AWS credentials (see ci.yml: test storage is :test/Disk, so the creds
  // never reach real S3). The avatar upload beside this one survives that
  // because it rides ActiveStorage; this one does not. Asserting the app-owned
  // outcome here fails on CI and passes locally, which is the worst shape a
  // test can have.
  //
  // That outcome IS covered, at the tier that can stub the bucket:
  // test/integration/email_banner_test.rb, "an uploaded banner overrides this
  // app's committed asset".
  //
  // What only a browser can prove, and what this therefore keeps: the page
  // mounts its OWN modal host (emailModals) because not every consuming app
  // renders a shared one — if that store fails to register, the Upload button
  // is inert and NO server-side test notices.
  test("upload opens the shared crop modal and submits @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/emails");

    await page.getByRole("button", { name: /^(Upload|Replace)$/ }).first().click();
    await expect(page.getByText("Crop Photo")).toBeVisible();

    await page.locator('input[type="file"][x-ref="filePicker"]').setInputFiles(IMG);
    await expect(page.locator(".cropper-container")).toBeVisible();

    await page.getByRole("button", { name: /Crop & Save/i }).click();

    // The saving card is the proof the cropped blob reached the row's hidden
    // form and submitted — it is opened by submitFormWithProgress on the same
    // page-scoped store.
    await expect(page.getByText("Saving banner")).toBeVisible();

    // Whatever the bucket says, the flow returns to the manager and the modal
    // does not stick. A card left on screen is the failure this guards.
    await expect(page).toHaveURL(/\/admin\/emails$/, { timeout: 20000 });
    await expect(page.getByText("Crop Photo")).toBeHidden();
  });
});
