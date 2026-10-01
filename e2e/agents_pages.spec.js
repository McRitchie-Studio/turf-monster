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
//   * A THUMB CAN HIT IT. Both copy buttons are measured against the 44px
//     minimum; the first shipped at 38.
//   * THE ENDPOINT TABLE CAN BE READ. Its second column once rendered about
//     27px wide at this width, one word per line. Its width is measured.
//   * NOTHING SCROLLS SIDEWAYS. The guide is full of long JSON and curl
//     examples; each has to scroll inside its own box and leave the page alone.
//     That is measured, in both themes, at 375 pixels.
//
// No reseed and no sign-in: both pages are public and read no database row a
// seed owns.
const PHONE = { width: 375, height: 740 };
const TAP_TARGET = 44;

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
  expect(box.height).toBeGreaterThanOrEqual(TAP_TARGET);
  expect(box.width).toBeGreaterThanOrEqual(TAP_TARGET);

  await copy.click();
  await expect(copy).toContainText("Copied");

  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  expect(clipboard.trim()).toBe(shown);
  // The whole prompt, line breaks included: a prompt flattened to one line is
  // still "the same words" and reads far worse to the model it is pasted into.
  expect(clipboard.split("\n\n").length).toBeGreaterThan(8);
});

test("the Claude Code command is copied whole, on one line, from a button a thumb can hit", async ({ page }) => {
  await page.goto("/agents");

  const shown = (await page.locator('[data-test="mcp-command"]').innerText()).trim();
  expect(shown).toMatch(/^claude mcp add --transport http turf-monster https:\/\/\S+\/mcp --header "Authorization: Bearer \S+"$/);

  const copy = page.locator('[data-test="mcp-command-copy"] button');
  await copy.scrollIntoViewIfNeeded();
  const box = await copy.boundingBox();
  expect(box.height).toBeGreaterThanOrEqual(TAP_TARGET);
  expect(box.width).toBeGreaterThanOrEqual(TAP_TARGET);

  await copy.click();
  await expect(copy).toContainText("Copied");
  const clipboard = await page.evaluate(() => navigator.clipboard.readText());
  // The block wraps on screen; the clipboard must not carry those wraps.
  expect(clipboard).toBe(shown);
  expect(clipboard).not.toContain("\n");

  // The command is long and unbreakable by spaces alone: it wraps inside its
  // box and does not push the page sideways.
  const block = page.locator('[data-test="mcp-command"]');
  expect(await block.evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(1);
});

test("the endpoint table's second column is wide enough to read at phone width", async ({ page }) => {
  await page.goto("/agents");
  const table = page.locator('[data-test="agents-endpoints"]');
  await table.scrollIntoViewIfNeeded();
  const tableBox = await table.boundingBox();

  const purposes = page.locator('[data-test="agents-endpoint-purpose"]');
  const count = await purposes.count();
  expect(count).toBeGreaterThanOrEqual(6);
  for (let index = 0; index < count; index += 1) {
    const cell = purposes.nth(index);
    await expect(cell).toBeVisible();
    const box = await cell.boundingBox();
    // It regressed to about 27px. Stacked, it has the table's whole width;
    // 200px is the floor that still reads as a sentence and not a column of
    // single words.
    expect(box.width).toBeGreaterThanOrEqual(200);
    expect(box.width).toBeGreaterThanOrEqual(tableBox.width * 0.9);
    // And every description fits on at most two lines.
    expect(box.height).toBeLessThanOrEqual(56);
  }
  // Nothing in the table is wider than the table: no sideways scroll inside it.
  expect(await table.evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(1);
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

// The Terms clause the agent pages restate (task terms-permit-api-agents): the
// link under "What your key can and cannot do" opens the Terms AT the clause,
// and the clause, one long list item, wraps inside a phone's width.
test("the Terms link on /agents opens the Terms at the AI agent clause", async ({ page }) => {
  await page.goto("/agents");
  await page.locator('[data-test="agents-terms-rule"] a').click();
  await expect(page).toHaveURL(/\/terms#ai-agents$/);
  const clause = page.locator('[data-test="terms-ai-agents"]');
  await expect(clause).toContainText("play through our official API");
  await expect(clause).toBeInViewport();
});

for (const theme of ["light", "dark"]) {
  test(`the Terms page does not scroll sideways at phone width (${theme})`, async ({ page }) => {
    await useTheme(page, theme);
    await page.goto("/terms#ai-agents");
    await expect(page.locator('[data-test="terms-ai-agents"]')).toBeVisible();
    expect(await pageOverflow(page)).toBeLessThanOrEqual(0);
  });
}

// A heading that is "in the viewport" can still be under the sticky navbar,
// which is where these jumps landed while Turbo followed them: the heading's
// scroll margin was ignored. toBeInViewport passed on a heading 16px short of
// the top and failed when the guide grew. So the heading's own top is measured:
// below the top of the viewport, and in its upper half.
async function expectLandedOn(page, id) {
  await expect(page).toHaveURL(new RegExp(`#${id}$`));
  await expect
    .poll(() => page.locator(`#${id}`).evaluate((el) => Math.round(el.getBoundingClientRect().top)))
    .toBeGreaterThanOrEqual(40);
  const top = await page.locator(`#${id}`).evaluate((el) => el.getBoundingClientRect().top);
  expect(top).toBeLessThan(PHONE.height / 2);
}

test("a section link on the guide lands on that section", async ({ page }) => {
  await page.goto("/agents/guide");
  await page.locator('nav[aria-label="Sections"] a', { hasText: "How to win" }).click();
  await expectLandedOn(page, "how-to-win");
});

test("a link inside the guide's text lands on its section, clear of the navbar", async ({ page }) => {
  await page.goto("/agents/guide");
  // The last section link in the page: from the MCP section back up to Errors.
  await page.locator('[data-test="agent-guide"] article a[href="#errors"]').last().click();
  await expectLandedOn(page, "errors");
});
