const { test, expect } = require("@playwright/test");
const { reseed, login, setupPhantomMock } = require("./helpers");

// Client-side wallet failures reaching error_logs.
//
// WHY THIS NEEDS A BROWSER. Every other tier can prove a piece: the endpoint
// records (test/controllers/solana_client_failure_report_test.rb), the scrub
// holds (test/services/solana/client_failure_report_test.rb), the URL routes
// (test/controllers/wallet_failure_reporter_wiring_test.rb). None of them can
// prove the one thing that actually failed for seven production sessions — that
// a real wallet rejection, in a real Alpine component, ends with a POST leaving
// the page. The failure is caught, mapped and painted entirely client-side, so
// the browser is the only place the whole path exists.
//
// AND THE FAIL-OPEN HALF IS ONLY PROVABLE HERE. A reporting fault must not
// change one character of what the user reads. The second test breaks the
// endpoint and asserts the screen is identical — an assertion that has no
// meaning without a screen.
test.setTimeout(60_000);

test.beforeEach(async ({ request }) => await reseed(request));

// Phantom's OWN decline, verbatim: a `code` of 4001 alongside the message. Both
// halves matter downstream — the layout rethrows on either, and the modal maps
// on the code — so a mock that carried only one would exercise half the branch.
const PHANTOM_DECLINE = { code: 4001, message: "User rejected the request." };

const REPORT_PATH = "/auth/solana/report_failure";

// THE ERROR PARAGRAPH, NAMED BY ITS SURFACE — and this is the THIRD thing these
// locators have keyed on. They were `p.text-red-400` until
// /tasks/error-text-fails-light-mode repainted every error sentence with the
// theme's derived danger ink, and six tests here went red for a change that
// altered nothing they are about. Re-aiming them at `p[role="alert"]` fixed
// that, but bought a subtler dependency: it resolved to one element only
// because exactly ONE error paragraph in the whole app carried the role.
//
// /tasks/error-paragraphs-lack-live-regions made a live region the NORM for
// error paragraphs — thirteen of them now — so "the alert on the page" stopped
// being a description of this paragraph and became a fact about page gating.
// Measured on 2026-09-09, after that change, this page still holds exactly ONE
// `p[role="alert"]`: the modal host renders only the open modal
// (`<template x-if="$store.modals.current().id === …">`), and the one other
// alert on this route lives in the quest card, which is gated on `@has_entry`
// — false for the fresh signup openWalletSetup creates. All six assertions
// passed unchanged. But a margin of one element, held up by a fixture's
// entry count, is not what these tests should rest on: give this spec's user
// an entry and the quest card's error paragraph joins the DOM, strict mode
// resolves two, and all six throw at once.
//
// So they key on the surface instead. `data-test` names WHICH paragraph
// without borrowing a colour, a role, or a container — and, unlike a role
// locator, it is independent of what the live-region test below asserts, so
// that test can actually fail on a dropped attribute instead of merely
// resolving nothing.
const WALLET_SETUP_ERROR = 'p[data-test="wallet-setup-error"]';

// A wallet nobody owns. Seed byte 1 is MOCK_PUBKEY_B58, which global-setup.js
// has already pinned to the ADMIN — linking it to a fresh signup calls
// merge_users! and absorbs the admin, which global-teardown then cannot restore.
// Same constant and same reason as e2e/wallet_setup.spec.js.
const UNOWNED_WALLET_SEED = 7;

// Open the wallet-setup modal on a freshly signed-up account.
//
// FRESH, NOT THE ADMIN, and that is load-bearing rather than tidy: global-setup
// pins the admin's wallet to the mock's own address, so an admin arrives at this
// modal ALREADY LINKED. The success spec below waits on `phantomLinked` becoming
// true — against the admin that is true before the click, the wait returns
// instantly, and the spec passes having driven nothing at all. Measured here on
// 2026-09-07: it passed in 688ms with the click doing no work.
//
// Driven through the modal store rather than by walking the onboarding chain
// (e2e/wallet_setup.spec.js owns that walk) because these specs are about the
// CATCH BLOCK, and the route taken to the modal changes nothing about it.
async function openWalletSetup(page, connectError) {
  await setupPhantomMock(page, { seedByte: UNOWNED_WALLET_SEED, connectError });
  await login(page, `walletreport-${Date.now().toString(36)}@example.com`);
  await page.goto("/");
  await page.waitForFunction(() => window.Alpine && Alpine.store("modals"));

  // THE PRECONDITION, ASSERTED. A user who already holds a wallet cannot
  // exercise any of this, and the failure mode is silence, not red.
  const linked = await page.evaluate(
    () => JSON.parse(document.getElementById("session-context").textContent).phantomLinked
  );
  expect(linked).toBe(false);

  await page.evaluate(() => Alpine.store("modals").open("wallet-setup", {}));
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  // The row only becomes the Connect button once wallet_provider.js has seen the
  // injected Phantom. Waiting on the badge is waiting on that registration.
  await expect(page.getByText("Installed", { exact: true })).toBeVisible();
}

test("a declined signature is reported with BOTH the raw and mapped message", async ({ page }) => {
  await openWalletSetup(page, PHANTOM_DECLINE);

  const [request] = await Promise.all([
    page.waitForRequest((r) => r.url().includes(REPORT_PATH) && r.method() === "POST"),
    page.getByText("Installed", { exact: true }).click(),
  ]);

  const body = JSON.parse(request.postData());

  // THE PAIR IS THE POINT. `raw` is what Phantom said; `mapped` is what the user
  // read. The 2026-09-06 incident was a correct mapper meeting a wallet string
  // it had never seen — undiagnosable from the mapped half alone.
  expect(body.raw_message).toBe("User rejected the request.");
  expect(body.mapped_message).toBe("Signature rejected");
  expect(body.stage).toBe("wallet_setup_connect");
  expect(body.provider).toBe("Phantom");

  // Layer 1 of the PII rule, asserted on the WIRE. No credential key exists in
  // the body, so none can reach a proxy buffer, an access log, or a row.
  expect(Object.keys(body).sort()).toEqual([
    "mapped_message",
    "provider",
    "raw_message",
    "stage",
  ]);

  // And the user still gets their sentence. Located by surface, not by colour
  // or role — see WALLET_SETUP_ERROR above for why it has moved twice.
  await expect(page.locator(WALLET_SETUP_ERROR)).toHaveText("Signature rejected");
});

test("a 500 from the reporter leaves the sign-in flow untouched", async ({ page }) => {
  // THE FAIL-OPEN PROOF, and it is a direct one: break the endpoint, then assert
  // the screen is what it would have been anyway. An assertion that only covers
  // the happy path is not evidence of failing open.
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));

  await openWalletSetup(page, PHANTOM_DECLINE);

  let reported = false;
  await page.route(`**${REPORT_PATH}`, (route) => {
    reported = true;
    return route.fulfill({ status: 500, contentType: "text/plain", body: "boom" });
  });

  await page.getByText("Installed", { exact: true }).click();

  // 1. The user reads exactly the same sentence.
  await expect(page.locator(WALLET_SETUP_ERROR)).toHaveText("Signature rejected");

  // 2. The modal is still theirs to retry with — `connecting` was released, so
  //    the row is not stuck in its disabled/spinner state behind a dead POST.
  await expect(page.getByText("Connecting…")).toBeHidden();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // 3. Nothing surfaced. A promise rejection with no `.catch` reaches the page
  //    as an unhandled rejection, which is the shape a broken fail-open takes.
  expect(pageErrors).toEqual([]);

  // 4. And the endpoint really was called and really did fail — without this the
  //    three assertions above would pass just as well if the reporter had never
  //    fired at all, which is the whole failure this task exists to fix.
  expect(reported).toBe(true);
});

test("a dead network while reporting leaves the sign-in flow untouched", async ({ page }) => {
  // THE HALF A 500 CANNOT REACH, and it went unproven until a mutant said so.
  //
  // `fetch` RESOLVES for a 500 — an HTTP error status is a successful round trip
  // — so the spec above never enters the reporter's `.catch()`. Measured
  // 2026-09-07: deleting `.catch(function() {})` from window.reportWalletFailure
  // outright left all four of the other specs GREEN. Only a transport failure
  // rejects the promise, and an unhandled rejection is precisely the shape a
  // broken fail-open takes on this surface: silent, invisible to the user, and
  // fatal to any Alpine handler that happened to be awaiting it.
  //
  // So this aborts the request instead of answering it.
  await page.addInitScript(() => {
    window.__unhandledRejections = [];
    window.addEventListener("unhandledrejection", (event) => {
      window.__unhandledRejections.push(
        String((event.reason && event.reason.message) || event.reason)
      );
    });
  });
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(String(error)));

  await openWalletSetup(page, PHANTOM_DECLINE);

  let aborted = false;
  await page.route(`**${REPORT_PATH}`, (route) => {
    aborted = true;
    return route.abort("failed");
  });

  await page.getByText("Installed", { exact: true }).click();

  // 1. The user reads exactly the sentence they would have read anyway.
  await expect(page.locator(WALLET_SETUP_ERROR)).toHaveText("Signature rejected");

  // 2. The modal is still theirs to retry with.
  await expect(page.getByText("Connecting…")).toBeHidden();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // 3. The transport really did fail — without this the assertions above would
  //    pass just as well if the reporter had never fired.
  expect(aborted).toBe(true);

  // 4. And the rejection was CAUGHT. This is the assertion the 500 spec cannot
  //    make: it is empty only because `.catch()` ran.
  expect(await page.evaluate(() => window.__unhandledRejections)).toEqual([]);
  expect(pageErrors).toEqual([]);
});

test("a successful connect reports nothing", async ({ page }) => {
  // The over-reporting guard. error_logs is a triage surface: a row per
  // successful sign-in would bury the failures this change exists to surface.
  await openWalletSetup(page, null);

  let reports = 0;
  page.on("request", (r) => {
    if (r.url().includes(REPORT_PATH)) reports += 1;
  });

  await page.getByText("Installed", { exact: true }).click();

  await page.waitForFunction(() => {
    const el = document.getElementById("session-context");
    return el && JSON.parse(el.textContent).phantomLinked === true;
  }, null, { timeout: 20000 });

  expect(reports).toBe(0);
});

test("the 2026-09-06 incident: an empty Phantom reports what the WALLET said", async ({ page }) => {
  // THE INCIDENT ITSELF, replayed. Phantom is installed — so the row paints
  // "Installed" and the picker offers it — but it holds no keypair, sits on its
  // own create-or-import screen, and rejects with its generic 'Unexpected error'.
  // That string used to reach parseSolanaError, whose transaction branch answered
  // with USDC balance advice in a CONNECT modal.
  //
  // AND THE HALF THAT WAS STILL BROKEN AFTER THAT FIX. solanaConnectAndVerify
  // substitutes its own sentence for the wallet's before rethrowing, so by the
  // time any surface catches it, 'Unexpected error' is gone — and the report
  // arrived with raw_message and mapped_message BYTE-IDENTICAL, both of them our
  // words. The pair is the entire diagnostic value of the call, and for the one
  // incident the whole feature was built for, the raw half said nothing.
  // /tasks/raw-message-is-ours moved the report INSIDE the layout, to the last
  // point at which the wallet's own string still exists.
  await openWalletSetup(page, { message: "Unexpected error" });

  // ── THE ROUTE, ASSERTED BEFORE THE BEHAVIOUR ──────────────────────────────
  // Real Phantom advertises solana:signIn, so a real empty extension fails
  // signIn FIRST and only then the connect + signMessage fallback. Until
  // 2026-09-07 e2e/phantom-mock.js advertised signIn on NEITHER interface, so
  // every spec in this file drove a route Phantom does not take — which is
  // precisely why none of them could see the defect above. Without this line the
  // file silently reverts to certifying that route the moment the mock changes.
  expect(
    await page.evaluate(() => window.walletProvider.get("Phantom").supportsSignIn())
  ).toBe(true);

  // Count every report this failure produces. The layout tags the error it
  // substituted so the modal's own catch skips it; untagged, the SAME failure
  // lands twice and the second row carries our sentence in both halves — the
  // useless row an operator meets first.
  const reports = [];
  page.on("request", (r) => {
    if (r.url().includes(REPORT_PATH)) reports.push(JSON.parse(r.postData()));
  });

  const [request] = await Promise.all([
    page.waitForRequest((r) => r.url().includes(REPORT_PATH) && r.method() === "POST"),
    page.getByText("Installed", { exact: true }).click(),
  ]);

  const body = JSON.parse(request.postData());

  // THE FIX, AND THE ACCEPTANCE. A malfunction — not a decline — now produces a
  // report whose two halves DIFFER: raw is Phantom's, mapped is ours.
  expect(body.raw_message).toBe("Unexpected error");
  expect(body.mapped_message).toContain("Finish setting up your wallet in Phantom");
  expect(body.raw_message).not.toBe(body.mapped_message);

  // Reported from the fallback itself, not from a surface downstream.
  expect(body.stage).toBe("connect_verify_fallback");
  expect(body.provider).toBe("Phantom");

  // `mapped` IS WHAT THE USER READ, and it is compared against the page rather
  // than against a sentence typed into this spec. A copy of the copy cannot fail
  // when the copy changes; this can.
  const shown = page.locator(WALLET_SETUP_ERROR);
  await expect(shown).toContainText("create or import one");
  expect(body.mapped_message).toBe((await shown.textContent()).trim());

  // And the user is still NOT told about their USDC balance.
  expect(body.mapped_message).not.toMatch(/USDC/i);

  // ONE ROW, NOT TWO. Asserted after the sentence is on screen, which is the
  // point past which the modal's catch has already run and either reported or
  // skipped.
  expect(reports).toHaveLength(1);
});

test("the SAME failure on the Wallet Standard interface reports the wallet's string", async ({ page }) => {
  // THIS APP HAS TWO PROVIDER INTERFACES AND A MOCK PINNED TO ONE CERTIFIES
  // HALF. Phantom reaches this app as the legacy injected provider AND as a
  // Wallet Standard adapter, and walletProvider.get() prefers the adapter once
  // it registers — so the interface the previous spec exercised is not the one a
  // current Phantom actually uses. The two run different code:
  // wallet_provider.js's _makeWsAdapter composes connect/signIn out of
  // `standard:connect` and `solana:signIn`, and normalizeSignInOutput takes its
  // OTHER branch here (`account.address`, not `address`).
  //
  // The failure and the acceptance are identical, which is the assertion: the
  // raw half must be the wallet's on both.
  await setupPhantomMock(page, {
    seedByte: UNOWNED_WALLET_SEED,
    walletStandard: true,
    connectError: { message: "Unexpected error" },
  });
  await login(page, `walletreportws-${Date.now().toString(36)}@example.com`);
  await page.goto("/");
  await page.waitForFunction(() => window.Alpine && Alpine.store("modals"));
  await page.evaluate(() => Alpine.store("modals").open("wallet-setup", {}));
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // WAIT FOR THE ADAPTER, don't hope for it. The mock registers the Wallet
  // Standard wallet on a deliberate 1.5s delay so this ordering is deterministic
  // in both places (see e2e/phantom-mock.js). `_raw` exists only on the adapter,
  // so this is the difference between the two interfaces, not a proxy for it.
  await expect
    .poll(() => page.evaluate(() => !!window.walletProvider.get("Phantom")?._raw))
    .toBe(true);
  expect(
    await page.evaluate(() => window.walletProvider.get("Phantom").supportsSignIn())
  ).toBe(true);

  const [request] = await Promise.all([
    page.waitForRequest((r) => r.url().includes(REPORT_PATH) && r.method() === "POST"),
    page.getByText("Installed", { exact: true }).click(),
  ]);

  const body = JSON.parse(request.postData());

  expect(body.raw_message).toBe("Unexpected error");
  expect(body.raw_message).not.toBe(body.mapped_message);
  expect(body.stage).toBe("connect_verify_fallback");

  const shown = page.locator(WALLET_SETUP_ERROR);
  await expect(shown).toContainText("create or import one");
  expect(body.mapped_message).toBe((await shown.textContent()).trim());
});

test("a wallet that connects and then refuses to sign reports the WALLET's string", async ({ page }) => {
  // THE SECOND SUBSTITUTION, AND THE REASON THIS SPEC EXISTS.
  // narrow-wallet-setup-diagnosis (#587) added a guard ABOVE the setup copy: if
  // connect() answered with a publicKey and signMessage refused afterwards, the
  // fallback substitutes "Your wallet connected but could not sign you in"
  // instead of the setup sentence. That guard RETURNS FIRST, so on this path the
  // setup site — the one every other spec in this file drives — never runs.
  //
  // It shipped without a report, which silently reopened the exact defect this
  // file exists to close: the substituted error reached the modal untagged, the
  // modal reported it, and because parseSolanaError passes that sentence through
  // unrecognised, `raw_message` and `mapped_message` arrived BYTE-IDENTICAL —
  // both of them ours. A whole failure class, invisible again.
  //
  // WHY THE MOCK NEEDED A NEW KNOB. `connectError` cannot express this: an
  // extension that fails connect() never reaches the guard. Only a wallet that
  // connects and THEN refuses to sign does, which is what `signMessageError`
  // models (e2e/phantom-mock.js).
  await setupPhantomMock(page, {
    seedByte: UNOWNED_WALLET_SEED,
    // signIn must fail for the connect + signMessage fallback to run at all, and
    // it must fail as something OTHER than a decline — a decline is rethrown
    // before the fallback is ever considered.
    signInError: { message: "Unexpected error" },
    // connect() SUCCEEDS. No connectError, deliberately: `connected` only flips
    // once a publicKey comes back, and that flag is the guard's whole predicate.
    signMessageError: { message: "Unexpected error" }
  });
  await login(page, `walletreportsign-${Date.now().toString(36)}@example.com`);
  await page.goto("/");
  await page.waitForFunction(() => window.Alpine && Alpine.store("modals"));
  await page.evaluate(() => Alpine.store("modals").open("wallet-setup", {}));
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();
  await expect(page.getByText("Installed", { exact: true })).toBeVisible();

  const reports = [];
  page.on("request", (r) => {
    if (r.url().includes(REPORT_PATH)) reports.push(JSON.parse(r.postData()));
  });

  const [request] = await Promise.all([
    page.waitForRequest((r) => r.url().includes(REPORT_PATH) && r.method() === "POST"),
    page.getByText("Installed", { exact: true }).click(),
  ]);

  const body = JSON.parse(request.postData());

  // THE ACCEPTANCE. The halves DIFFER: raw is what Phantom said, mapped is the
  // sentence we substituted for it.
  expect(body.raw_message).toBe("Unexpected error");
  expect(body.mapped_message).toContain("could not sign you in");
  expect(body.raw_message).not.toBe(body.mapped_message);

  // ITS OWN STAGE. Not connect_verify_fallback — that stage means connect()
  // never answered, and here it answered. An operator filtering for a wallet
  // that holds no keypair must not meet this row.
  expect(body.stage).toBe("connect_verify_signature");
  expect(body.provider).toBe("Phantom");

  // AND THE USER WAS NOT TOLD TO CREATE A WALLET. The whole point of #587's
  // guard is that this user HAS one; the setup sentence would be false.
  expect(body.mapped_message).not.toContain("create or import one");
  expect(body.mapped_message).not.toMatch(/USDC/i);

  // `mapped` IS WHAT THE USER READ, compared against the page rather than a copy
  // typed into this spec.
  const shown = page.locator(WALLET_SETUP_ERROR);
  await expect(shown).toContainText("could not sign you in");
  expect(body.mapped_message).toBe((await shown.textContent()).trim());

  // ONE ROW, NOT TWO — the tag on the substituted error keeps the modal's own
  // catch from reporting it a second time with our sentence in both halves.
  expect(reports).toHaveLength(1);
});

test("the failure paragraph is a live region that existed before the failure", async ({ page }) => {
  // PRE-EXISTING, fixed alongside the reporting defect because it is the same
  // paragraph: a screen reader was never told the connect failed. The modal's
  // only feedback for a rejected or unusable wallet is this sentence.
  //
  // AND WHY THE ORDER IS THE ASSERTION. The paragraph used to be
  // `<template x-if="error">`, so it did not exist until the error did — and a
  // live region inserted alongside its own content is not reliably announced,
  // because assistive technology has to be observing the region before the text
  // lands in it. Putting aria-live on that markup would have been a green test
  // over an unchanged experience. So this reads the region while it is still
  // EMPTY, then watches it fill: an ordering no source scan can see, and the one
  // thing that makes the attributes mean anything.
  await openWalletSetup(page, PHANTOM_DECLINE);

  // Located by the surface hook, NOT by `p[x-text="error"]` as it was: this
  // change gave five other error paragraphs that same binding, so the old
  // locator was one co-rendered modal away from resolving two. The hook is also
  // deliberately not the attribute under test — locating by `role="alert"` here
  // would mean a regression that DROPPED the role failed as "element not found"
  // rather than as "the region is not announced".
  const region = page.locator(WALLET_SETUP_ERROR);

  // 1. It is here, before anything has failed, and it is empty.
  await expect(region).toHaveAttribute("role", "alert");
  await expect(region).toHaveAttribute("aria-live", "assertive");
  expect((await region.textContent()).trim()).toBe("");

  // 2. It fills in place. Same element handle throughout — a re-inserted node
  //    would leave this locator resolving something else.
  await page.getByText("Installed", { exact: true }).click();
  await expect(region).toHaveText("Signature rejected");
  await expect(region).toBeVisible();
});
