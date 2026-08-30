const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] /admin/nfl/weeks/:slot — the focus order board.
//
// What only a browser can prove, and what the integration suite therefore
// cannot: that a DRAG reaches the server at all. The endpoint is covered by
// Admin::Nfl::WeeksControllerTest and the board's wiring by
// AdminWeekBoardRenderTest, but both of those describe a page nobody has picked
// a card up on. Between them sits everything that makes the board work:
// SortableJS binding to the engine's dropzone, the studioBoard factory being on
// the page at all (a <script> in the wrong place renders a board that simply
// does not drag, with no error anywhere), and the reorder POST the drop fires.
// A reload at the end is what separates "the card moved on screen" from "the
// order was saved".
test.beforeEach(async ({ request }) => await reseed(request));

// SortableJS listens for real pointer travel — a single teleporting move never
// starts a drag, and a drop that arrives in one hop lands wherever the library
// last thought the pointer was. Three things make this reliable: a small move
// BEFORE the travel (which is what crosses the drag threshold and starts the
// drag at all), enough intermediate moves for the library to track a direction,
// and a final settle move at the destination before the mouse comes up.
async function dragCard(page, card, target, dropOffsetY) {
  const from = await card.boundingBox();
  const to = await target.boundingBox();
  const startX = from.x + from.width / 2;
  const startY = from.y + from.height / 2;
  const endX = to.x + to.width / 2;
  const endY = to.y + (dropOffsetY === undefined ? to.height / 2 : dropOffsetY);

  await page.mouse.move(startX, startY);
  await page.mouse.down();
  await page.mouse.move(startX, startY - 6, { steps: 3 });
  for (let i = 1; i <= 16; i += 1) {
    const t = i / 16;
    await page.mouse.move(startX + (endX - startX) * t, startY + (endY - startY) * t, { steps: 3 });
  }
  await page.mouse.move(endX, endY, { steps: 3 });
  await page.mouse.up();
}

const slugsInList = (page) =>
  page.evaluate(() =>
    Array.from(document.querySelectorAll("#dropzone-focus .kanban-card")).map((c) => c.dataset.slug)
  );

test.describe("Focus order board", () => {
  test("dragging a game up the list saves the new order", async ({ page }) => {
    // A viewport tall enough to hold the whole list. `page.mouse` works in
    // VIEWPORT coordinates while `boundingBox()` reports page ones, so a card
    // below the fold is a set of coordinates the pointer never reaches — the
    // drag then silently does nothing and the board looks untouched, which is
    // indistinguishable from a board that cannot drag at all.
    await page.setViewportSize({ width: 1280, height: 1000 });
    await loginAdmin(page);
    await page.goto("/admin/nfl/weeks");

    // Follow the first week rather than hardcoding a slot: which week the seed
    // lands in is the seed's business, and this board is the same for all of them.
    await page.locator('a[href^="/admin/nfl/weeks/"]').first().click();
    await page.waitForURL(/\/admin\/nfl\/weeks\/\d/);

    // The factory sets this in $nextTick, AFTER wiring the sortables — so it is
    // the honest "the board is draggable now" signal, not merely "it rendered".
    await expect(page.locator('[data-alpine-ready="true"]')).toBeVisible();

    const before = await slugsInList(page);
    expect(before.length).toBeGreaterThan(1);
    const wanted = before[before.length - 1];

    // Carry the LAST game up the list. WHERE it lands is SortableJS's business
    // — the pointer arithmetic that decides between slot 0 and slot 1 is not
    // this app's contract and pinning it here would make the spec a metronome
    // for a library. What IS the contract: the drag moved the game up, and the
    // server stored exactly the order the browser ended up showing.
    const cards = page.locator("#dropzone-focus .kanban-card");
    await dragCard(page, cards.last(), cards.first(), 6);

    await expect
      .poll(async () => (await slugsInList(page)).indexOf(wanted))
      .toBeLessThan(before.length - 1);

    const after = await slugsInList(page);
    expect(after).not.toEqual(before);

    // THE RELOAD IS THE ASSERTION. Everything above is equally true of a board
    // that moved the card on screen and never told the server.
    await page.reload();
    await expect(page.locator('[data-alpine-ready="true"]')).toBeVisible();
    expect(await slugsInList(page)).toEqual(after);
  });
});
