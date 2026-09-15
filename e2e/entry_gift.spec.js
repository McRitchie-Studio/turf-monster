const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] Gifting a free entry by email, from the operator's form to the friend's
// first screen.
//
// WHY A BROWSER IS THE ONLY PLACE THE SECOND HALF CAN BE PROVEN. The server
// tiers can assert that the click creates the account, mints the wallet, claims
// the gift and redirects to the contest — and they do. What they cannot see is
// the thing the whole feature was asked for: that the recipient LANDS IN THE
// ONBOARDING CHAIN (first name → birthday) rather than on a bare contest page.
// That chain is armed server-side but WALKED by the layout's driver and the
// shared Alpine modal host, so "did a card actually open" is a runtime fact that
// lives entirely in the browser. Mr. McRitchie's phrase for it was "50%
// onboarded"; this spec is what holds that claim up.
//
// The mint is deliberately NOT exercised here. It runs in a Sidekiq job against
// a real RPC, which no PR lane may do — EntryGiftMintJob's own tests own that
// half, with the vault faked at its boundary.
test.setTimeout(90_000);

test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST = "world-cup-2026";

function freshEmail() {
  return `gift-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e4)}@example.com`;
}

// Send one through the REAL admin form — not a fixture and not a test endpoint —
// so what the recipient claims below is what the operator's own send produces.
async function sendGift(page, email) {
  await loginAdmin(page);
  await page.goto("/admin/entry_gifts");
  await page.fill("input[name=recipient_email]", email);
  await page.selectOption("select[name=contest_slug]", CONTEST);
  await page.fill("textarea[name=note]", "Put a lineup in this week.");
  await page.click('input[type=submit][value="Send Free Entry"]');

  // WAIT ON THE ROW, NOT ON THE URL — and this is the whole reason this helper
  // has a comment. `waitForURL(/\/admin\/entry_gifts/)` was here, and it is a
  // NO-OP: the form lives ON /admin/entry_gifts, so the pattern already matches
  // the CURRENT url and the wait resolves instantly, before the POST has even
  // been answered. Everything after it then raced the server.
  //
  // It passed locally on speed alone and went RED in CI three times, with the
  // response body naming the exact window it landed in — {"error":"gift has no
  // link"}, i.e. after `gift.save` and before `create_magic_link`. A wait that
  // is satisfied by the state you were already in proves nothing; the row
  // appearing is the server's own confirmation that the whole create finished.
  await expect(page.locator("tr", { hasText: email })).toBeVisible();
}

// Which modal the shared host currently shows — the same probe the onboarding
// chain spec uses.
async function currentModal(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c ? { id: c.id } : null;
  });
}

test("the admin form sends a gift and the ledger records it", async ({ page }) => {
  const email = freshEmail();
  await sendGift(page, email);

  const row = page.locator("tr", { hasText: email });
  await expect(row).toBeVisible();
  await expect(row).toContainText("Sent");
  await expect(row).toContainText("Put a lineup in this week.");
  // Unclaimed gifts offer a re-send; a claimed one would not.
  await expect(row.getByRole("button", { name: "Re-send" })).toBeVisible();
});

test("the emailed link signs a stranger up and opens the onboarding chain", async ({ page, context }) => {
  const email = freshEmail();
  await sendGift(page, email);

  // Read the link the send actually produced.
  const res = await page.request.post("/test/entry_gift_link", { data: { email } });
  expect(res.ok(), `entry_gift_link failed: ${res.status()}`).toBeTruthy();
  const { url } = await res.json();

  // A different person, in a different browser: drop the operator's session
  // entirely rather than consuming the link as the admin who sent it.
  await context.clearCookies();
  await page.goto(url);

  // The gift's own return_to: they land on the contest they were invited to.
  await page.waitForURL(new RegExp(`/contests/${CONTEST}`));

  // THE CLAIM THIS SPEC EXISTS FOR — the chain is open on its first card.
  await expect
    .poll(async () => (await currentModal(page))?.id, { timeout: 15_000 })
    .toBe("onboarding");

  // And the ledger has moved off "Sent" for that address.
  await context.clearCookies();
  await loginAdmin(page);
  await page.goto("/admin/entry_gifts");
  await expect(page.locator("tr", { hasText: email })).toContainText("Claimed");
});

// [e2e] THE AUNT TEST — the operator's whole reason for this feature.
//
// He ran the real flow on QA and was walked into "Set up your wallet" twice: as
// step 3 of the onboarding chain, and AGAIN on hold-to-confirm after a refresh.
// His words: "the state of the system should sense the free entry and not gate
// any web3 guards … my easy way to make the app approachable for the aunts of
// the world."
//
// WHY A BROWSER IS THE ONLY PLACE THIS CLOSES. The server tiers assert the two
// facts the client READS (the chain's step list and session[:wallet_setup]).
// They cannot see what the page DOES with them: the chain is walked by the
// layout's driver, the wallet card is opened by the Alpine modal host, and the
// hold-to-confirm block comes from eligibilityBlocker in solana_utils.js, which
// checks walletSetupRequired BEFORE tokensAvailable. A wallet modal reappearing
// on any of those three paths is invisible to every lower tier.
test("a gifted player is never shown the wallet card, before or after a refresh", async ({ page, context }) => {
  const email = freshEmail();
  await sendGift(page, email);

  const res = await page.request.post("/test/entry_gift_link", { data: { email } });
  expect(res.ok(), `entry_gift_link failed: ${res.status()}`).toBeTruthy();
  const { url } = await res.json();

  await context.clearCookies();
  await page.goto(url);
  await page.waitForURL(new RegExp(`/contests/${CONTEST}`));

  // The chain opens on first name — that part is wanted and unchanged.
  await expect
    .poll(async () => (await currentModal(page))?.id, { timeout: 15_000 })
    .toBe("onboarding");

  // THE ASSERTION. Walk the chain to its end and the wallet card must never be
  // what is on screen. Polled rather than checked once, because the failure
  // being guarded is a card that appears a beat LATER, which a single read
  // would sail straight past.
  await page.evaluate(() => window.Alpine.store("modals").closeAll?.() ?? window.Alpine.store("modals").close());
  for (let i = 0; i < 10; i++) {
    const id = (await currentModal(page))?.id;
    expect(id, "the wallet card must never open for a gifted player").not.toBe("wallet-setup");
    await page.waitForTimeout(300);
  }

  // AND AFTER A REFRESH — the second place the operator hit it. session
  // [:wallet_setup] is computed once at sign-in and read on every later render,
  // so a stale true would reopen the card here even though the chain was clean.
  await page.reload();
  await page.waitForLoadState("domcontentloaded");
  for (let i = 0; i < 8; i++) {
    const id = (await currentModal(page))?.id;
    expect(id, "the wallet card must not return after a refresh").not.toBe("wallet-setup");
    await page.waitForTimeout(300);
  }

  // And the flag the hold-to-confirm blocker actually reads is off, which is
  // what makes Hold to Confirm reachable at all.
  const blocked = await page.evaluate(() => {
    const s = window.Alpine?.store?.("session");
    return s ? !!s.walletSetupRequired : null;
  });
  expect(blocked, "walletSetupRequired gates hold-to-confirm before tokensAvailable").toBe(false);
});

// [e2e] THE WALLET CHOICE A GIFTED NEWCOMER SHOULD NEVER MEET.
//
// WHY A BROWSER IS THE ONLY PLACE THIS CLOSES. The server tier can assert that
// the sign-in card renders without the wallet button, and it does. What it
// cannot see is whether the CARD STILL READS AS A CARD once that button is
// taken out of it — the Google CTA, the "or" divider and the email field are
// laid out by Tailwind at runtime, and a removal that collapses the divider or
// strands a margin is invisible to assert_select. It also cannot see that the
// shared modal host still renders the Connect Wallet picker on this page, which
// is exactly why the assertions below key on the card's own [data-auth-solana]
// wrapper and not on the Solana mark.
test("the gift link's sign-in bounce hides the wallet choice, and the card still holds", async ({
  page
}) => {
  // WITHOUT the nudge: the wallet option is there. This half runs FIRST on
  // purpose — it is the control, and a suppression test whose control never ran
  // passes just as well against a card that lost the button for some other
  // reason.
  await page.goto("/signin");
  await expect(page.locator("[data-auth-solana]")).toBeVisible();

  // WITH it: gone, and the rest of the card intact.
  await page.goto("/signin?wallet=managed");
  await expect(page.locator("[data-auth-solana]")).toHaveCount(0);
  await expect(page.locator('form[action^="/auth/google_oauth2"]')).toBeVisible();
  await expect(page.locator("#email")).toBeVisible();

  // THE LAYOUT ASSERTION, and the reason this is a browser test. The divider
  // still separates the one-tap options from the email field, and the card
  // never scrolls sideways at phone width.
  await expect(page.getByText("or", { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow, "the sign-in card must not scroll sideways on a phone").toBeLessThanOrEqual(0);
});
