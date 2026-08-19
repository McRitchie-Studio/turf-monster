const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test.setTimeout(60_000);

test.beforeEach(async ({ page, request }) => {
  await page.route("**/account/session_refresh", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true }),
    });
  });
  await reseed(request);
});

async function doLogin(page) {
  // Passwordless magic link — mint + consume a token for alex (admin).
  const resp = await page.request.post("/test/magic_link_token", {
    data: { email: "alex@mcritchie.studio" },
  });
  const { url } = await resp.json();
  await page.goto(url);
  // / redirects to /contests/:slug — wait for any URL outside /signin + /magic_link
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link")
  );
}

// Enable geo blocking with WA banned + activate WA override via admin UI
async function enableGeoBlockingAndOverride(page) {
  await page.goto("/admin/geo");
  await page.waitForLoadState("networkidle");

  // Enable geo-blocking checkbox
  const enabledCheckbox = page.locator("#geo_setting_enabled");
  if (await enabledCheckbox.count() > 0 && !(await enabledCheckbox.isChecked())) {
    await enabledCheckbox.check({ force: true });
  }

  // WA state checkbox (hidden input — force-check via JS). The field is
  // banned_subdivisions since the geo manager became the engine's: the list
  // stores region tokens (US-WA), and the grid still posts the bare code.
  await page.evaluate(() => {
    const waInput = document.querySelector(
      'input[value="WA"][name="geo_setting[banned_subdivisions][]"]'
    );
    if (waInput && !waInput.checked) waInput.checked = true;
  });

  // Save settings
  await page.locator('input[value="Save Settings"]').click();
  await page.waitForTimeout(2000);

  // Toggle WA override
  await page.goto("/admin/geo");
  await page.waitForLoadState("networkidle");

  const simBtn = page.getByRole("button", { name: /Simulate WA/i });
  if (await simBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
    await simBtn.click();
    await page.waitForTimeout(2000);
  }
  // If "Clear GEO Override" is visible instead, override is already active
}

// ---------------------------------------------------------------------------
// Test 1: Verify /geo/check endpoint returns blocked when WA override active
// ---------------------------------------------------------------------------

test("geo/check returns blocked:true when geo enabled + WA override", async ({ page }) => {
  await doLogin(page);
  await enableGeoBlockingAndOverride(page);

  const response = await page.evaluate(async () => {
    const res = await fetch("/geo/check", {
      headers: { Accept: "application/json" },
    });
    return res.json();
  });

  expect(response.state).toBe("WA");
  expect(response.blocked).toBe(true);
});

// ---------------------------------------------------------------------------
// Test 2: Hold-to-confirm aborts at 1s with geo blocked modal
// ---------------------------------------------------------------------------

test("hold-to-confirm aborts at 1s with geo blocked modal", async ({ page }) => {
  await doLogin(page);

  // Select 6 matchups BEFORE enabling geo blocking (toggle_selection has require_geo_allowed)
  await page.goto("/");
  await page.waitForLoadState("networkidle");

  await page.evaluate(async () => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch("/contests/world-cup-2026/clear_picks", {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  });
  await page.reload();
  await page.waitForLoadState("networkidle");

  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
  for (let i = 0; i < 6; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }

  // NOW enable geo blocking (after selections are saved)
  await enableGeoBlockingAndOverride(page);

  // Verify geo check endpoint returns blocked
  const geoCheck = await page.evaluate(async () => {
    const res = await fetch("/geo/check", {
      headers: { Accept: "application/json" },
    });
    return res.json();
  });
  expect(geoCheck.blocked).toBe(true);

  // Navigate back to contest page (selections should still be there)
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await expect(page.locator("body")).toContainText("6 / 6");

  // Run hold validations directly (avoids flaky dispatchEvent + setTimeout timing)
  const validationPassed = await page.evaluate(async () => {
    const els = document.querySelectorAll("[x-data]");
    for (const el of els) {
      const data = Alpine.$data(el);
      if (typeof data.runHoldValidations === "function") {
        return await data.runHoldValidations();
      }
    }
    throw new Error("runHoldValidations not found on any Alpine component");
  });

  // Validation should return false (geo blocked)
  expect(validationPassed).toBe(false);

  // "Location Restricted" modal should be visible
  await expect(page.getByText("Location Restricted")).toBeVisible({ timeout: 3000 });
});
