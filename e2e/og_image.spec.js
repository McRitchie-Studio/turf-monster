const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const OG_IMAGE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin link-preview (og:image) uploader on /admin/dashboard (the shared
// admin/shared/_og_image_uploader partial). Same crop-photo flow as the contest
// banner: "Edit image" opens the modal, the file drops in, "Crop & Save" saves
// immediately (update_link_preview_image) then toasts + refreshes the preview
// via Turbo Stream. In test the image lands on the Disk service
// (OgImageAttachable::PUBLIC_OG_SERVICE = :test) — no S3.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Admin link-preview (og:image) uploader", () => {
  test("admin crops + saves the default og:image and the preview refreshes", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/dashboard");

    await page.getByRole("button", { name: "Edit image" }).click();
    await page.locator('input[type="file"][accept="image/*"]').setInputFiles(OG_IMAGE);
    await expect(page.locator(".cropper-container")).toBeVisible();

    // Crop & Save -> loading card -> Turbo upload response -> success toast -> refreshed preview <img>.
    const imageSave = page.waitForResponse((response) =>
      ["PATCH", "POST"].includes(response.request().method()) &&
      response.url().includes("/admin/dashboard/link_preview_image")
    );
    await page.getByRole("button", { name: /Crop.*Save/ }).click();
    await expect(page.getByText("Saving image")).toBeVisible();
    const imageResponse = await imageSave;
    expect(imageResponse.ok()).toBeTruthy();
    await expect(page.getByText("Image updated")).toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#default-og-image-preview img")).toBeVisible();
  });
});

// The contest rung: a contest's own banner IS its link-preview card. The
// banner is uploaded through the same admin editor a human uses, then the
// public contest page is read the way an unfurler reads it — tags first, then
// an actual fetch of the URL those tags point at.
//
// FETCHING THE IMAGE IS THE POINT. Asserting the meta tag alone passes on a URL
// that 404s, and that is exactly the failure mode here: the card is a variant
// composed on demand at the proxy route, so the tag can be perfectly formed
// while the image behind it never renders.
test.describe("Contest link preview (og:image) uses the banner", () => {
  test("a contest's banner is served as its link-preview card", async ({ page, browser }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026/edit");

    await page.getByRole("button", { name: "Edit banner" }).click();
    await page.locator('input[type="file"][accept="image/*"]').setInputFiles(OG_IMAGE);
    await expect(page.locator(".cropper-container")).toBeVisible();

    const bannerSave = page.waitForResponse((response) =>
      ["PATCH", "POST"].includes(response.request().method()) && response.url().includes("/banner")
    );
    await page.getByRole("button", { name: /Crop.*Save/ }).click();
    await expect(page.getByText("Saving banner")).toBeVisible();
    expect((await bannerSave).ok()).toBeTruthy();
    await expect(page.getByText("Banner updated")).toBeVisible({ timeout: 15_000 });
    // The preview <img> is the proof the attachment landed; navigating before it
    // appears reads the page back before the banner exists.
    await expect(page.locator("#contest-banner-preview img")).toBeVisible();

    // READ THE PAGE AS AN UNFURLER DOES: signed out, in a fresh context. The
    // admin who uploaded the banner is not who fetches the card.
    const visitor = await browser.newContext();
    const visitorPage = await visitor.newPage();
    await visitorPage.goto("/contests/world-cup-2026");
    const ogImage = await visitorPage.locator('meta[property="og:image"]').getAttribute("content");
    const twitterImage = await visitorPage.locator('meta[name="twitter:image"]').getAttribute("content");

    // The composed card, on the permanent proxy route — not the static default
    // and not an expiring service URL.
    expect(ogImage).toContain("/representations/proxy/");
    expect(ogImage).not.toContain("/og.png");
    expect(twitterImage).toBe(ogImage);

    const card = await visitorPage.request.get(ogImage);
    expect(card.status()).toBe(200);
    expect(card.headers()["content-type"]).toContain("image/png");

    // Read the card's real dimensions out of the PNG header (IHDR width/height
    // are big-endian u32 at byte 16 and 20). Byte length is NOT the assertion to
    // make here — the fixture banner is flat colour and composes to well under a
    // kilobyte, so a size floor tests the fixture rather than the card. This
    // proves the 5:1 banner actually came back padded to the 1200x630 card, out
    // of the live proxy route, with ImageMagick doing the work.
    const bytes = await card.body();
    expect(bytes.subarray(1, 4).toString()).toBe("PNG");
    expect(bytes.readUInt32BE(16)).toBe(1200);
    expect(bytes.readUInt32BE(20)).toBe(630);

    await visitor.close();
  });
});
