const { test, expect, devices } = require("@playwright/test");
const { reseed, attestAge } = require("./helpers");

// Auth-modal UI flows driven through the REAL login form — the path the
// login() test backdoor skips, and exactly where the #30 x-data regression
// silently broke the "Check your inbox" modal (the whole component failed to
// parse, so nothing rendered). These tests would have caught that.
//
// NOT covered here: the resend 429 / "Too many requests" error path — the e2e
// server runs in test env with rack-attack disabled, so resends never throttle
// in tests. That path stays a known Playwright gap.
//
// reseed clears rack-attack counters + volatile state between tests (when run
// locally against the dev :3100 server, rack-attack IS on; CI's test-env server
// has it off — either way reseed keeps runs isolated).
//
// Tagged @smoke: core auth, part of the fast "general" e2e lane
// (`npm run test:smoke` / `--grep @smoke`). See docs/LOCAL_STACK.md.
// Base58 decode, deliberately INDEPENDENT of the encoder it judges. The phone
// hand-off spec below reads the payload studio-engine's deep link built; decoding
// it with a second implementation is what makes "the encoder ran and produced
// something real" an assertion rather than a restatement.
//
// Standard convention, verified against 3,958 random buffers with leading zeros:
// every shape this file decodes round-trips. The ONE input that does not is an
// all-zero VALUE, where the engine's encoder emits an extra leading "1" — its
// quirk, not this decoder's, and unreachable here: an x25519 public key is never
// all zeros and a JSON payload starts with "{".
const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function decodeBase58(str) {
  let n = 0n;
  for (const ch of String(str)) {
    const i = B58_ALPHABET.indexOf(ch);
    if (i < 0) throw new Error(`not base58: ${JSON.stringify(ch)} in ${str}`);
    n = n * 58n + BigInt(i);
  }
  const bytes = [];
  while (n > 0n) {
    bytes.unshift(Number(n & 0xffn));
    n >>= 8n;
  }
  for (const ch of String(str)) {
    if (ch !== "1") break;
    bytes.unshift(0);
  }
  return Uint8Array.from(bytes);
}

test.beforeEach(async ({ request }) => await reseed(request));

test("requesting a magic link from the login form opens the Check your inbox modal @smoke", async ({ page }) => {
  await page.goto("/signin");
  await page.fill('input[name="email"]', `authmodal-${Date.now()}@example.com`);
  await attestAge(page);
  await page.getByRole("button", { name: "Email Link" }).click();

  // The auth modal's magic-link-sent step. (#30 broke this: a double-quote in
  // the x-data closed the attribute, so the modal rendered empty.)
  await expect(page.getByText("Check your inbox")).toBeVisible();
  await expect(page.locator('button:has-text("Resend link")')).toBeVisible();
});

test("resending swaps to the Link Resent confirmation and starts the cooldown @smoke", async ({ page }) => {
  await page.goto("/signin");
  await page.fill('input[name="email"]', `authmodal-resend-${Date.now()}@example.com`);
  await attestAge(page);
  await page.getByRole("button", { name: "Email Link" }).click();
  await expect(page.getByText("Check your inbox")).toBeVisible();

  await page.locator('button:has-text("Resend link")').click();

  // A successful resend swaps to the dedicated success step and disables the
  // link with a counting-down 60s cooldown.
  await expect(page.getByText("Link Resent!")).toBeVisible();
  await expect(page.getByText(/Resend available in \d+s/)).toBeVisible();
});

test("Solana button in standalone auth modal opens the wallet chooser @smoke", async ({ page }) => {
  await page.goto("/signin");

  await page.evaluate(() => {
    Alpine.store("modals").open("auth", {
      step: "credentials",
      submitting: null,
      formError: "",
      phantomError: "",
      googleError: "",
    });
  });

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: "Sign in" })).toBeVisible();

  await attestAge(page);
  await dialog.getByRole("button", { name: "Solana" }).click();

  await expect(dialog.getByRole("heading", { name: "Connect Wallet" })).toBeVisible();
  await expect(dialog.getByRole("link", { name: /Phantom Install/ })).toBeVisible();

  // ...and NOT the mobile deep-link row. It is in the DOM either way (x-show
  // toggles it), so this is a computed-visibility assertion. A desktop browser
  // CAN install the extension, so an "Open app" row here would be the
  // duplicate-Phantom bug: two Phantom rows, the top one broken.
  await expect(dialog.locator('button:has-text("Open app")')).toBeHidden();
});

// ── The MOBILE Phantom row, which no browser had ever seen ────────────────
//
// WHAT THIS COVERS AND WHY IT IS HERE. adopt-engine-phantom-deeplink deleted this
// app's app/javascript/phantom_deeplink.js and now renders studio-engine's
// studio/solana/phantom_deeplink instead. The engine picker decides what a PHONE
// sees from `typeof startPhantomDeepLink === 'function'` — both `missingInstalls`
// and `showPhantomDeepLink` read it, so the two flip together. Lose the render and
// the phone silently falls back to Phantom's browser-extension INSTALL row, which
// cannot be completed on iOS Safari. Nothing server-side can see that: the guards
// are Alpine getters evaluated in the browser, and the page ships identical markup
// either way.
//
// A VIEWPORT IS NOT A PHONE, which is why this is a describe with a use() rather
// than the page.setViewportSize its neighbours use. walletProvider.isMobile()
// (app/javascript/wallet_provider.js:442) reads navigator.userAgent, never the
// width — deliberately, because the bug wallet_picker_single_phantom_test exists to
// kill was a row gated on the bare user-agent test. Resizing the window would leave
// every getter here FALSE and both specs below would pass against the desktop
// picker, proving nothing. The UA comes from Playwright's own iPhone descriptor
// rather than a hand-typed string.
test.describe("the Connect Wallet picker on a phone", () => {
  test.use({
    viewport: devices["iPhone 13"].viewport,
    userAgent: devices["iPhone 13"].userAgent,
    hasTouch: true,
    isMobile: true,
  });

  async function openPicker(page) {
    await page.goto("/signin");
    await page.evaluate(() => {
      Alpine.store("modals").open("auth", {
        step: "credentials",
        submitting: null,
        formError: "",
        phantomError: "",
        googleError: "",
      });
    });
    const dialog = page.getByRole("dialog");
    await expect(dialog.getByRole("heading", { name: "Sign in" })).toBeVisible();
    await attestAge(page);
    await dialog.getByRole("button", { name: "Solana" }).click();
    await expect(dialog.getByRole("heading", { name: "Connect Wallet" })).toBeVisible();
    return dialog;
  }

  test("Phantom offers its deep link and drops its install row @smoke", async ({ page }) => {
    const dialog = await openPicker(page);

    // The deep-link row. Always present in the DOM — x-show toggles display — so
    // toBeVisible() is a COMPUTED check, not "is the string in the response".
    const deepLink = dialog.locator('button:has-text("Open app")');
    await expect(deepLink).toBeVisible();
    await expect(deepLink).toContainText("Phantom");

    // And Phantom's install row is gone. This one is a real DOM absence: the
    // install rows are an x-for over missingInstalls, so a filtered wallet has no
    // element at all.
    await expect(dialog.getByRole("link", { name: /Phantom Install/ })).toHaveCount(0);

    // THE CONTROL, without which "no Phantom install row" is satisfied by a picker
    // that painted nothing. We ship no deep link for these two, so a phone must
    // still be offered their download pages.
    await expect(dialog.getByRole("link", { name: /Solflare Install/ })).toBeVisible();
    await expect(dialog.getByRole("link", { name: /Backpack Install/ })).toBeVisible();
  });

  // TAPPING IT, rather than checking the symbol exists. The engine's own partial
  // records why: an earlier cut left B58_ALPHABET at module scope while inlining
  // the encoder into a classic script, so encodeBase58 read a free variable that
  // resolved to nothing AT CALL TIME and every mobile sign-in threw on the first
  // keypair encode. That was invisible to eleven passing view tests AND to a
  // browser spec that checked `typeof startPhantomDeepLink` without ever calling
  // it. A parse-time mutation cannot reach that class either — the program parses
  // fine. Only a real tap does.
  //
  // The payload is decoded with this file's OWN base58 implementation, so the
  // assertion is independent of the encoder it is judging.
  test("tapping it hands off to Phantom with a real base58 SIWS payload @smoke", async ({ page, context }) => {
    // Stub the universal link so the tap does not actually leave the app.
    await context.route("https://phantom.app/**", (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>phantom</title>" })
    );

    const dialog = await openPicker(page);

    const handoff = page.waitForRequest((r) => r.url().startsWith("https://phantom.app/ul/v1/signIn"));
    await dialog.locator('button:has-text("Open app")').click();
    const params = new URL((await handoff).url()).searchParams;

    // Where Phantom is told to come back to — this app's own callback route,
    // which this app still draws (the engine's copy is behind draw_auth_routes).
    const origin = new URL(page.url()).origin;
    expect(params.get("redirect_link")).toBe(`${origin}/auth/phantom/callback`);

    // A real x25519 public key: 32 bytes once decoded, not merely a plausible string.
    expect(decodeBase58(params.get("dapp_encryption_public_key"))).toHaveLength(32);

    // And the SIWS input the human will read inside Phantom.
    const signIn = JSON.parse(new TextDecoder().decode(decodeBase58(params.get("payload"))));
    expect(signIn.statement).toBe("Sign in to Turf Monster");
    expect(signIn.domain).toBe(new URL(page.url()).host);
    expect(signIn.nonce).toMatch(/^[0-9a-f]{32}$/);

    // The cluster comes off <body data-solana-cluster>, not a devnet default.
    expect(["devnet", "mainnet-beta"]).toContain(params.get("cluster"));
  });
});

// Regression: the navbar "Sign in" CTA opens this same modal on EVERY page, but
// its Google + email buttons used to only work when a contest board was mounted
// to catch their dispatched events. On a non-board page (/signin has no board)
// both were silent no-ops — the production bug. The modal now runs the action
// itself when no board handles the event. /signin is our no-board host.
test("Google in the auth modal works on a page with NO contest board @smoke", async ({ page, context }) => {
  // Stub the OAuth popup target so it loads a no-op page (no postMessage back, so
  // the opener does not reload mid-assertion). We only assert the popup opened.
  await context.route("**/auth/google_popup**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>oauth</title>" }),
  );

  await page.goto("/signin");
  await page.evaluate(() => {
    Alpine.store("modals").open("auth", {
      step: "credentials", submitting: null, formError: "", phantomError: "", googleError: "",
    });
  });
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await attestAge(page);

  const [popup] = await Promise.all([
    page.waitForEvent("popup"),
    dialog.getByRole("button", { name: "Google" }).click(),
  ]);
  await expect(popup).toHaveURL(/\/auth\/google_popup/);
});

test("Email link in the auth modal works on a page with NO contest board @smoke", async ({ page }) => {
  await page.goto("/signin");
  await page.evaluate(() => {
    Alpine.store("modals").open("auth", {
      step: "credentials", submitting: null, formError: "", phantomError: "", googleError: "",
    });
  });
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("heading", { name: "Sign in" })).toBeVisible();
  await attestAge(page);

  await dialog
    .locator('input[placeholder="you@example.com"]')
    .fill(`modal-noboard-${Date.now()}@example.com`);
  await dialog.getByRole("button", { name: "Email Link" }).click();

  await expect(dialog.getByText("Check your inbox")).toBeVisible();
});
