const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

const VIEWPORTS = [
  { width: 1366, height: 800 },
  { width: 1024, height: 768 },
  { width: 820, height: 768 },
];

async function exposeStressControls(page) {
  await page.evaluate(() => {
    const badge = document.querySelector("[data-free-entry-badge]");
    if (badge) {
      badge.classList.remove("hidden");
      badge.dataset.tokenCount = "1";
    }

    const balance = document.querySelector("[data-balance-display]");
    if (balance) {
      balance.classList.remove("hidden");
      balance.textContent = "$1504";
    }
    // The balance slot's other face: a seeded $0-with-token user renders the
    // "✨ Free Entry" label ACTIVE instead of the amount. Stand it down so the
    // stress state is exactly one face — the widest amount — not both at once.
    const feLabel = document.querySelector("[data-free-entry-label]");
    if (feLabel) feLabel.classList.remove("is-active");
  });
}

async function navbarMetrics(page) {
  return await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const documentWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    );
    const navbar = document.querySelector("[data-navbar-root]");
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== "none" &&
        style.visibility !== "hidden" &&
        rect.width > 0 &&
        rect.height > 0;
    };

    const selectors = [
      ["balance", "[data-balance-display]"],
      ["entry", "[data-free-entry-badge]"],
      ["username", "[data-username-display]"],
      ["profile", "[data-profile-image-toggle]"],
    ];

    const controls = selectors.flatMap(([name, selector]) =>
      Array.from(document.querySelectorAll(selector))
        .filter(visible)
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            name,
            text: element.textContent.trim().replace(/\s+/g, " "),
            left: rect.left,
            right: rect.right,
            width: rect.width,
            height: rect.height,
          };
        })
    );

    const navbarRect = navbar ? navbar.getBoundingClientRect() : null;
    const offscreen = controls.filter((control) =>
      control.left < -1 || control.right > viewportWidth + 1
    );

    return {
      viewportWidth,
      documentOverflow: documentWidth - viewportWidth,
      navbar: navbarRect && {
        left: navbarRect.left,
        right: navbarRect.right,
        width: navbarRect.width,
      },
      controls,
      offscreen,
    };
  });
}

async function expectNavbarContained(page) {
  const metrics = await navbarMetrics(page);
  const message = JSON.stringify(metrics, null, 2);

  expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
  expect(metrics.offscreen, message).toEqual([]);
  expect(metrics.controls.some((control) => control.name === "balance"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "entry"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "username"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "profile"), message).toBe(true);
}

test("logged-in navbar controls stay contained with balance and entry badge", async ({ page }) => {
  await page.setViewportSize(VIEWPORTS[0]);
  await login(page, "alex@mcritchie.studio", "password");

  for (const viewport of VIEWPORTS) {
    await page.setViewportSize(viewport);
    await page.goto("/contests");
    await expect(page.locator("[data-username-display]").first()).toBeVisible();
    await exposeStressControls(page);
    await expectNavbarContained(page);
  }
});
