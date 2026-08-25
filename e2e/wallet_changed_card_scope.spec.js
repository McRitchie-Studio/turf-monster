const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

// THE WALLET-CHANGED CARD MUST CONTAIN ONLY ITSELF.
//
// On 2026-08-24 it contained the whole contest page. Removing the card's
// subtitle BLOCK without passing a `subtitle:` local left
// studio/modals/blocks/_card_header falling through to its last branch:
//
//   <% elsif block_given? %>
//     <p class="<%= sub_cls %>"><%= yield %></p>
//
// A Rails partial's block_given? reads TRUE off the LAYOUT's yield even when no
// block was passed, so that `yield` emitted the entire page into the card's
// subtitle. Measured: board, board-config, entry-sidebar, entry-sidebar-title,
// leaderboard-container, contest_1_messages, chat-reaction-picker and
// contest-chat-input all present TWICE, the second copy INSIDE div[role=dialog].
// On screen it reads as the page nested in a frame; it also put a second
// "Start New Session" in the DOM, so the card's own button stopped being
// clickable under Playwright's strict locators.
//
// WHY AN E2E TIER AND NOT A RENDER TEST: the injected content comes from the
// LAYOUT's yield. A partial rendered in isolation has no layout, so the bug is
// invisible to any test that does not run a real page in a real browser — which
// is exactly why every existing tier stayed green through it.
//
// The assertion is structural, not a list of those eight ids: whatever the
// contest page gains next is covered without an edit here.
test.setTimeout(90_000);
test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST = "/contests/nfl-2026-weeks-1-3";

async function duplicateIds(page) {
  return await page.evaluate(() => {
    const seen = {};
    document.querySelectorAll("[id]").forEach((el) => {
      seen[el.id] = (seen[el.id] || 0) + 1;
    });
    return Object.entries(seen)
      .filter(([, n]) => n > 1)
      .map(([id]) => id)
      .sort();
  });
}

test("opening the wallet-changed card does not clone the page into it", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: true });
  await loginViaPhantom(page);
  await page.goto(CONTEST);
  await page.waitForLoadState("networkidle");

  // The page must be clean FIRST, or a pre-existing duplicate would make the
  // post-open assertion pass for the wrong reason.
  expect(await duplicateIds(page)).toEqual([]);

  await page.evaluate(() =>
    Alpine.store("modals").open("wallet-changed", {
      oldAddress: "4MCkYMrLCVXap9jW1pL8kDyNNtgWF19WGp6B5m1TVsCr",
      newAddress: "14Gn2cCA69PwKU7t8x1fS6WQwBPnwXkSA4KRM8ibmBP4",
      providerLabel: "Phantom",
      dismissible: false,
    })
  );
  await expect(page.getByRole("dialog")).toBeVisible();

  expect(await duplicateIds(page)).toEqual([]);

  // The page's own board must live in the body, never inside the card.
  const boardInDialog = await page.locator('div[role="dialog"] #board').count();
  expect(boardInDialog).toBe(0);

  // And the card still says what it is meant to say.
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Wallet changed");
  await expect(dialog).toContainText("4MCkYM...VsCr");
  await expect(dialog).toContainText("14Gn2c...mBP4");
});
