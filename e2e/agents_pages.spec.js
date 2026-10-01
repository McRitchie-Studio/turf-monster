const { test, expect } = require("@playwright/test");

// [e2e] /agents and /agents/guide on a phone.
//
// WHAT ONLY A BROWSER CAN SHOW HERE.
//
//   * THE COPY BUTTON WRITES THE CLIPBOARD. The server tests prove the button's
//     payload is the prompt. Whether a tap puts that text on the clipboard is
//     Alpine and the Clipboard API at work, and both are inert strings to every
//     tier below this one.
//   * THE BUTTON IS REACHABLE WITHOUT SCROLLING. "At the top of the page" is a
//     layout fact at a real viewport, with the real navbar above it.
//   * NOTHING SCROLLS SIDEWAYS. The guide is full of long JSON and curl
//     examples; each has to scroll inside its own box and leave the page alone.
//     That is measured, in both themes, at 375 pixels.
//
// No reseed and no sign-in: both pages are public and read no database row a
// seed owns.
const PHONE = { width: 375, height: 740 };

test.use({ viewport: PHONE, permissions: ["clipboard-read", "clipboard-write"] });

const pageOverflow = (page) =>
  page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

async function useTheme(page, theme) {
  await page.addInitScript((value) => localStorage.setItem("theme", value), theme);
}

test("the starter prompt is copied to the clipboard from the top of /agents", async ({ page }) => {
  await page.goto("/agents");

  const shown = (await page.locator('[data-test="starter-prompt"]').innerText()).trim();
  expect(shown).toContain("/agents/guide.md");
  expect(shown).toContain("[PASTE YOUR API KEY HERE]");

  const copy = page.locator('[data-test="starter-prompt-copy"] button');
  await expect(copy).toBeVisible();
  const box = await copy.boundingBox();
  expect(box.y + box.height).toBeLessThan(PHONE.height);
  // A real tap target, not the primitive's bare text link.
  expect(box.height).toBeGreaterThanOrEqual(36);

  await copy.click();
  await expect(copy).toContainText("Copied");

  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  expect(clipboard.trim()).toBe(shown);
  // The whole prompt, line breaks included: a prompt flattened to one line is
  // still "the same words" and reads far worse to the model it is pasted into.
  expect(clipboard.split("\n\n").length).toBeGreaterThan(8);
});

for (const theme of ["light", "dark"]) {
  test(`/agents does not scroll sideways at phone width (${theme})`, async ({ page }) => {
    await useTheme(page, theme);
    await page.goto("/agents");
    await expect(page.locator('[data-test="agents-page"] h1')).toBeVisible();
    expect(await pageOverflow(page)).toBeLessThanOrEqual(0);
  });

  test(`/agents/guide keeps long examples inside their own boxes (${theme})`, async ({ page }) => {
    await useTheme(page, theme);
    await page.goto("/agents/guide");
    await expect(page.locator('[data-test="agent-guide"] h1')).toHaveText("Turf Monster agent guide");
    expect(await pageOverflow(page)).toBeLessThanOrEqual(0);

    // The proof that the page is narrow because the boxes scroll, not because
    // the examples happen to be short: at least one code block and one table
    // are wider than the box that holds them.
    const scrolling = await page.evaluate(() => {
      const wider = (el) => el.scrollWidth > el.clientWidth + 1;
      const guide = document.querySelector('[data-test="agent-guide"]');
      return {
        code: [...guide.querySelectorAll("pre")].filter(wider).length,
        tables: [...guide.querySelectorAll("div.overflow-x-auto")].filter(wider).length,
      };
    });
    expect(scrolling.code).toBeGreaterThan(0);
    expect(scrolling.tables).toBeGreaterThan(0);
  });
}

test("a section link on the guide lands on that section", async ({ page }) => {
  await page.goto("/agents/guide");
  await page.locator('nav[aria-label="Sections"] a', { hasText: "How to win" }).click();
  await expect(page).toHaveURL(/#how-to-win$/);
  await expect(page.locator("#how-to-win")).toBeInViewport();
});
