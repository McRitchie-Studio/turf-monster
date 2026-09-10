const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The confirm dialog in front of an irreversible burn.
//
// WHY A BROWSER IS THE ONLY PLACE THIS CAN BE PROVEN.
//
// `button_to ... data: { turbo_confirm: "…" }` is a data attribute. Server-side
// it is a string in the rendered HTML, and every assertion available to the
// integration and component tiers is satisfied by that string being PRESENT —
// they can prove the attribute was written, and nothing more. Whether Turbo is
// loaded, whether it intercepts THIS form, and whether declining actually
// cancels the submit are runtime facts that live entirely in the browser.
//
// That gap matters more here than anywhere else on the page. Every other button
// on /admin/free_entries is recoverable: an accidental Mint costs some admin SOL
// rent and gifts a user an entry. A burn destroys a user's property with no undo
// and no code path that can restore it. If the confirm silently fails to wire,
// the page still looks exactly right and one stray click is a permanent loss.
//
// So these specs assert the guard, not the burn. The POST is intercepted at the
// network boundary and never reaches the controller — the on-chain write is not
// something a PR lane may perform, and it is not what is under test.
test.beforeEach(async ({ request }) => await reseed(request));

// The admin's own row, warmed with spendable tokens so the burn controls render.
// The page is cache-first by design: cold rows show "syncing…" and offer no
// buttons at all, so without this the spec would assert against an empty cell.
async function warmAdminRow(page, { minted = 3, unconsumed = 3 } = {}) {
  await loginAdmin(page);
  // page.request, NOT the fixture's `request`: they are separate cookie jars,
  // and these two endpoints act on current_user. The fixture context is
  // unauthenticated, so it answers {"error":"no user"} — which `reseed` never
  // notices because it needs no session.
  //
  // The row only lists users WITH a wallet (users_with_wallet), and the seeded
  // admin has none, so grant one before warming the cache keyed on it.
  const wallet = await page.request.post("/test/grant_managed_wallet");
  expect(wallet.ok(), `grant_managed_wallet failed: ${wallet.status()}`).toBeTruthy();

  const res = await page.request.post("/test/warm_entry_tokens", {
    form: { minted: String(minted), unconsumed: String(unconsumed) },
  });
  expect(res.ok(), `warm_entry_tokens failed: ${res.status()} ${await res.text()}`).toBeTruthy();
}

async function openWarmedBoard(page, _request, opts = {}) {
  await warmAdminRow(page, opts);
  await page.goto("/admin/free_entries");
  await expect(page.getByRole("button", { name: "Burn 1" }).first()).toBeVisible();
}

// Count burn POSTs at the network boundary and answer them without ever
// reaching the controller.
async function interceptBurns(page) {
  const posts = [];
  await page.route("**/admin/free_entries/*/burn**", async (route) => {
    posts.push(route.request().url());
    await route.fulfill({ status: 302, headers: { Location: "/admin/free_entries" } });
  });
  return posts;
}

test.describe("Admin free-entry burn confirmation", () => {
  test("declining the confirm sends no burn @smoke", async ({ page, request }) => {
    await openWarmedBoard(page, request);
    const posts = await interceptBurns(page);

    let asked = null;
    page.on("dialog", async (d) => {
      asked = d.message();
      await d.dismiss();
    });

    await page.getByRole("button", { name: "Burn 1" }).first().click();
    await page.waitForTimeout(1000);

    // The dialog must have actually appeared. A `turbo_confirm` that never
    // wires up produces no dialog AND no failure — the click just burns.
    expect(asked, "clicking Burn must raise a confirm dialog").not.toBeNull();
    expect(asked).toMatch(/cannot be undone/i);
    expect(posts, "dismissing the confirm must cancel the request").toHaveLength(0);
  });

  test("accepting the confirm sends exactly one burn", async ({ page, request }) => {
    await openWarmedBoard(page, request);
    const posts = await interceptBurns(page);

    page.on("dialog", async (d) => await d.accept());

    await page.getByRole("button", { name: "Burn 1" }).first().click();
    await page.waitForTimeout(1000);

    // The control is wired: one click, one burn, and the count it carries is the
    // one the operator agreed to.
    expect(posts).toHaveLength(1);
    expect(posts[0]).toMatch(/count=1/);
  });

  test("Burn all names the number it will destroy", async ({ page, request }) => {
    await openWarmedBoard(page, request, { minted: 3, unconsumed: 3 });
    const posts = await interceptBurns(page);

    let asked = null;
    page.on("dialog", async (d) => {
      asked = d.message();
      await d.dismiss();
    });

    await page.getByRole("button", { name: /Burn all 3/ }).first().click();
    await page.waitForTimeout(1000);

    // An operator's only chance to catch a wrong row is the number in this
    // sentence. "Burn all unspent entries?" would read identically whether it
    // was about to destroy one token or forty.
    expect(asked, "Burn all must raise a confirm dialog").not.toBeNull();
    expect(asked).toMatch(/ALL 3/);
    expect(posts).toHaveLength(0);
  });

  test("a holder with nothing spendable is offered no burn", async ({ page, request }) => {
    // Every token already redeemed. The controls must be absent, not merely
    // disabled — a disabled button that a stylesheet re-enables is still a live
    // POST route to an irreversible action.
    await warmAdminRow(page, { minted: 2, unconsumed: 0 });

    await page.goto("/admin/free_entries");

    // POSITIVE CONTROL FIRST. "the first row is visible" is also true of the
    // empty-state <tr colspan=7>, so toHaveCount(0) below could pass while the
    // admin's row never rendered at all — a vacuous green that would survive the
    // burn controls being deleted outright. Assert the row we are making a claim
    // about is actually on the page, and that the page is the one we think it is.
    const row = page.locator("#users-tbody tr", { hasText: "alex" }).first();
    await expect(row).toBeVisible();
    await expect(row.getByRole("button", { name: "Act as" })).toHaveCount(0); // admin row
    await expect(page.getByRole("button", { name: /^Burn/ })).toHaveCount(0);
  });
});
