const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// The WEB3 STEP-UP card: a self-custody account signs in with a web2 credential
// (here, a magic link), so the session cannot sign on-chain.
//
// Only a browser can prove what this tier asserts. The server decides WHETHER to
// arm the card; everything that makes it a usable step — that it opens at all,
// that it leads with the remembered brand, that dismissing it releases the
// onboarding chain instead of stranding the user — lives in the layout's chain
// driver and the card's own Alpine component. A markup tier can assert every
// element renders and still miss a card that never opens, or a hand-off that
// leaves the next step permanently unreachable.
test.setTimeout(90_000);

test.beforeEach(async ({ request }) => await reseed(request));

// Stage a wallet-backed account, then walk the real magic-link round trip into
// it — the exact shape of the operator's report.
async function signInAsWalletUser(page, { provider = "phantom" } = {}) {
  const email = `stepup-${Date.now().toString(36)}@example.com`;
  const staged = await page.request.post("/test/grant_web3_wallet", { data: { email, provider } });
  expect(staged.ok(), "staging the wallet account").toBeTruthy();

  const minted = await page.request.post("/test/magic_link_token", { data: { email } });
  expect(minted.ok()).toBeTruthy();
  const { url } = await minted.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/")
  );
  return { email, ...(await staged.json()) };
}

// The open card. Scoping matters: the navbar shows the SAME truncated address
// this card does, so an unscoped text query matches two elements and fails
// strict mode rather than the assertion.
function dialog(page) {
  return page.getByRole("dialog");
}

// THE WRONG-WALLET ROUTE. Its SPELLING is the gem's and it moved: up to
// solana-studio 0.6.0 a full-width "Use a different wallet" row, and from the
// next release a quiet "Not your wallet?" link beside the address (operator
// call). This app renders whichever its lock resolves, and the release sweep
// bumps that lock without touching this file — so the locator accepts either
// and the WALK, which is what this spec is actually for, stays pinned.
function pickerLink(page) {
  return dialog(page).getByRole("button", { name: /Use a different wallet|Not your wallet\?/i });
}

async function currentModal(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    // current() always returns an OBJECT, empty when the stack is — the layout's
    // registrations read c.id off it with no null guard. So an empty stack is an
    // id-less object, not a null, and keying on truthiness alone would report a
    // closed host as still showing something.
    return c && c.id ? { id: c.id, props: c.props || {} } : null;
  });
}

test("a wallet account signing in by magic link is met with the step-up card", async ({ page }) => {
  await signInAsWalletUser(page);

  await expect
    .poll(async () => (await currentModal(page))?.id, { timeout: 15_000 })
    .toBe("web3-step-up");

  // The card must say what happened, not just demand a signature.
  //
  // Matched LOOSELY on purpose. The body copy is solana-studio's, this app
  // stopped overriding it on 2026-09-06, and the gem cut that copy from four
  // lines to one in the very next release — so the exact sentence differs
  // either side of a lock bump the release sweep performs without touching
  // this file. What both spellings share is the reason the card exists, and
  // that is what this asserts.
  await expect(dialog(page).getByText("Sign in with your wallet")).toBeVisible();
  await expect(dialog(page).getByText(/secured by a Solana wallet/i)).toBeVisible();
});

test("the card leads with the wallet the account actually used", async ({ page }) => {
  const staged = await signInAsWalletUser(page, { provider: "solflare" });
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");

  // The whole point of remembering the brand: one button, named.
  // The STANDARD web3 auth row: the wallet's own name, not a "Continue with …"
  // sentence. Same shape the connect picker and the wallet-setup step use.
  await expect(dialog(page).getByRole("button", { name: /Solflare/i })).toBeVisible();
  // ...and the address, so signing with a different wallet is a visible choice.
  const hint = `${staged.address.slice(0, 4)}\u2026${staged.address.slice(-4)}`;
  await expect(dialog(page).getByText(hint)).toBeVisible();
});

test("an account with no remembered brand gets the picker, not a dead end", async ({ page }) => {
  // Every wallet linked before the provider column existed is in this state.
  await signInAsWalletUser(page, { provider: "" });
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");

  await expect(dialog(page).getByRole("button", { name: /Connect your wallet/i })).toBeVisible();
  await expect(dialog(page).getByRole("button", { name: /Phantom|Solflare|Backpack/i })).toHaveCount(0);

  // ...and NO correction link. This account has an address but no remembered
  // brand, so the card still names the wallet — but the primary button is
  // already the picker, and a "not this one" link beside the address would be a
  // second door into the same room, competing with the one action on the card.
  // Asserted as not-VISIBLE rather than absent: the gem ships both halves of
  // every branch in the markup and lets the browser choose, so a count of zero
  // would be asserting something neither release is true of.
  await expect(pickerLink(page)).not.toBeVisible();
});

test("the wrong-wallet route reaches the picker and comes back", async ({ page }) => {
  await signInAsWalletUser(page);
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");

  await expect(pickerLink(page)).toBeVisible();
  await pickerLink(page).click();
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 10_000 }).toBe("wallet-connect");

  // Back must return to the step-up card. Before the picker learned this
  // backTo target it closed instead, dropping the user out of the flow with
  // nothing on screen and no way back to it.
  await dialog(page).getByRole("button", { name: /Back/i }).click();
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 10_000 }).toBe("web3-step-up");
  // ...carrying its props, so the returned-to card is the one they left.
  expect((await currentModal(page))?.props?.provider).toBe("phantom");
});

test("dismissing closes the card and leaves the session usable", async ({ page }) => {
  await signInAsWalletUser(page);
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");

  await dialog(page).getByRole("button", { name: /^Not now$/ }).click();
  await expect
    .poll(async () => (await currentModal(page))?.id, { timeout: 10_000 })
    .not.toBe("web3-step-up");

  // Advisory, not a lock (operator call): they are still signed in and browsing.
  // The teeth stay where they were — every on-chain gate still refuses this
  // session — so dismissal costs the user nothing it should not.
  // data-user-id is the app layout's logged-in signal (data-logged-in is the
  // PREVIEW layout's — the two carry different attributes).
  await expect(page.locator("body")).toHaveAttribute("data-user-id", /\d+/);
});

test("dismissing hands off to the onboarding chain instead of stranding the user", async ({ page }) => {
  // The step-up HOLDS the chain rather than racing it: both are armed on the
  // same render, and the driver will not start the chain until this card reports
  // done. That makes dismissal the only thing that releases it — so a hand-off
  // that silently failed would not merely skip a card, it would make every step
  // the user still owes permanently unreachable for the session. Only a browser
  // can catch that; the server emits both payloads either way.
  await signInAsWalletUser(page);
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");

  await dialog(page).getByRole("button", { name: /^Not now$/ }).click();

  // The chain's next outstanding card opens on its own. Which one it is depends
  // on what this account still owes (the age gate here, under the e2e env's
  // ENABLE_AGE_GATE), so assert that SOMETHING took over rather than pinning a
  // specific step this spec does not own.
  await expect
    .poll(async () => (await currentModal(page))?.id, { timeout: 10_000 })
    .toBeTruthy();
});

test("the card is a one-shot — it does not nag on the next page", async ({ page }) => {
  await signInAsWalletUser(page);
  await expect.poll(async () => (await currentModal(page))?.id, { timeout: 15_000 }).toBe("web3-step-up");
  await dialog(page).getByRole("button", { name: /^Not now$/ }).click();

  // Navigate away rather than closing whatever the chain handed us. The
  // navigation clears the stack anyway, and both prompts are consumed on the
  // render that armed them — which is precisely the property under test.
  await page.waitForTimeout(500);
  await page.goto("/contests");
  await page.waitForLoadState("domcontentloaded");
  // Give the driver the same window it gets on any other load before concluding
  // nothing opened.
  await page.waitForTimeout(1500);
  expect(await currentModal(page)).toBeNull();
});
