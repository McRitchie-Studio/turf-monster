// The signing pages' script policy, in a browser (SigningCsp).
//
// REPORT-ONLY (the default outside production): a blocked script still runs
// and the browser fires securitypolicyviolation for it; the first tests
// collect every one and expect none, apart from the gem-rendered items named
// in PENDING.
//
// ENFORCED (POST /test/signing_csp, undone by reseed): a script injected into
// a signing page, through a Drive visit, a frame or a stream, does not run.
// Each injection is also made where it MUST run (a page outside the group, or
// the policy back on report-only), so the refusal is the policy's and not a
// broken probe.
//
// PENDING lists inline script a gem still renders without the nonce, by the
// sample a report quotes ('report-sample') and the gem file SigningCsp's
// PENDING_GEM_FIXES names. An entry excuses a violation only while the server
// reports that file still open in the locked gem (POST /test/signing_csp
// answers with the open list), so it lapses when the lock takes the fix.
const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

const CONTEST = "/contests/world-cup-2026";
const LIVE = `${CONTEST}/live`;
const LAX = "/contests";
const DEEP_LINK = "app/views/solana_studio/_phantom_deeplink.html.erb";

const PENDING = [
  // solana-studio solana_studio/_phantom_deeplink: an un-nonced <script>.
  { file: DEEP_LINK, directive: "script-src-elem", sample: /^\s*\(function \(\) \{\s*var STATEMENT/ }
];

// The gem files still open, as the server reads them.
let openFiles = [];

function pending(violation, path) {
  return PENDING.some((item) => openFiles.includes(item.file) &&
    violation.directive.startsWith(item.directive) && item.sample.test(violation.sample) && (!item.path || item.path === path));
}

async function watchViolations(page) {
  await page.addInitScript(() => {
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      window.__cspViolations.push({
        directive: event.effectiveDirective,
        blocked: event.blockedURI,
        sample: event.sample,
        disposition: event.disposition
      });
    });
  });
}

async function violationsOn(page, path) {
  await page.goto(path);
  await page.waitForLoadState("load");
  return page.evaluate(() => window.__cspViolations);
}

// Sets the enforce switch; answers the gem files the server reads as still open.
async function enforce(request, enforced) {
  const response = await request.post("/test/signing_csp", { form: { enforced: String(enforced) } });
  expect(response.ok()).toBe(true);
  return (await response.json()).pending;
}

const navigationUrl = (page) => page.evaluate(() => new URL(performance.getEntriesByType("navigation")[0].name).pathname);
const injected = (page) => page.evaluate(() => window.__injected);
// Turbo runs a frame's or stream's scripts just after it renders, so a probe
// gets this long to run: the controls poll for it, the refusals wait it out.
const RUN_WINDOW = 1500;
const ranWithin = (page, value) => expect.poll(() => injected(page), { timeout: RUN_WINDOW }).toBe(value);
async function neverRan(page) {
  await page.waitForTimeout(RUN_WINDOW);
  expect(await injected(page)).toBeUndefined();
}

// Adds the probe script to every HTML document the browser fetches for path.
async function injectInto(page, path) {
  await page.route(`**${path}`, async (route) => {
    const response = await route.fetch();
    const type = response.headers()["content-type"] || "";
    if (route.request().resourceType() !== "document" && !type.includes("text/html")) return route.fulfill({ response });
    const body = (await response.text()).replace("</body>", "<script>window.__injected = 'drive'</script></body>");
    await route.fulfill({ response, body });
  });
}

async function injectThroughFrame(page) {
  await page.route("**/csp-probe-frame", (route) => route.fulfill({
    contentType: "text/html",
    body: "<html><body><turbo-frame id=\"csp-probe\"><p id=\"framed\">framed</p><script>window.__injected = 'frame'</script></turbo-frame></body></html>"
  }));
  await page.evaluate(() => {
    const frame = document.createElement("turbo-frame");
    frame.id = "csp-probe";
    frame.setAttribute("src", "/csp-probe-frame");
    document.body.appendChild(frame);
  });
  await expect(page.locator("#framed")).toHaveText("framed");
}

async function injectThroughStream(page) {
  await page.evaluate(() => {
    const target = document.createElement("div");
    target.id = "csp-probe-stream";
    document.body.appendChild(target);
    window.Turbo.renderStreamMessage(
      "<turbo-stream action=\"append\" target=\"csp-probe-stream\"><template><p id=\"streamed\">streamed</p>" +
      "<script>window.__injected = 'stream'</script></template></turbo-stream>"
    );
  });
  await expect(page.locator("#streamed")).toHaveText("streamed");
}

test.beforeEach(async ({ request }) => {
  await reseed(request);
  openFiles = await enforce(request, false);
});
test.afterEach(async ({ request }) => await enforce(request, false));

test.describe("report-only", () => {
  test("a guest on the contest page meets no script violation", async ({ page }) => {
    await watchViolations(page);
    const seen = await violationsOn(page, CONTEST);
    expect(seen.filter((v) => !pending(v, CONTEST))).toEqual([]);
  });

  test("an admin meets no script violation on any signing page", async ({ page }) => {
    await setupPhantomMock(page);
    await loginAdmin(page);
    await watchViolations(page);
    for (const path of [CONTEST, LIVE, `${CONTEST}/edit`, "/contests/new", "/contests/generator", "/account", "/profile",
                        "/wallet", "/admin/pending_transactions", "/admin/authorities", "/admin/vault_init",
                        "/admin/vault_state", "/auth/phantom/callback"]) {
      const seen = await violationsOn(page, path);
      expect(seen.filter((v) => !pending(v, path)), path).toEqual([]);
    }
  });

  // A browser applies the policy of the document it loaded, so a signing
  // page is entered and left by a full load, never by a Turbo render.
  test("a Turbo visit into or out of a signing page is a full load", async ({ page }) => {
    await page.goto(LAX);
    await page.locator(`a[href="${CONTEST}"]`).first().click();
    await page.waitForURL(`**${CONTEST}`);
    await page.waitForLoadState("load");
    expect(await navigationUrl(page)).toBe(CONTEST);

    await page.evaluate((target) => window.Turbo.visit(target), LAX);
    await page.waitForURL(`**${LAX}`);
    await page.waitForLoadState("load");
    expect(await navigationUrl(page)).toBe(LAX);
  });
});

test.describe("enforced", () => {
  test("a script injected through a Drive visit does not run on a signing page", async ({ page, request }) => {
    await enforce(request, true);
    await injectInto(page, CONTEST);
    await page.goto(LAX);
    await page.locator(`a[href="${CONTEST}"]`).first().click();
    await page.waitForURL(`**${CONTEST}`);
    await page.waitForLoadState("load");
    await expect(page.locator("[data-studio-controller~='chat-reactions']")).toHaveCount(1);
    await neverRan(page);
  });

  test("a script injected through a frame or a stream does not run on a signing page", async ({ page, request }) => {
    await enforce(request, true);
    await page.goto(CONTEST);
    await injectThroughFrame(page);
    await injectThroughStream(page);
    await neverRan(page);
  });

  // THE CONTROLS. The same probes, where nothing refuses them.
  test("the same Drive injection runs when the signing policy only reports", async ({ page }) => {
    await injectInto(page, CONTEST);
    await page.goto(CONTEST);
    await ranWithin(page, "drive");
  });

  test("the same frame and stream injections run on a page outside the group", async ({ page, request }) => {
    await enforce(request, true);
    await page.goto(LAX);
    await injectThroughFrame(page);
    await ranWithin(page, "frame");
    await injectThroughStream(page);
    await ranWithin(page, "stream");
  });
});

// The live board: the contest's page once a game has started.
test.describe("live board", () => {
  test("enforced: a script injected into the live board does not run, and its own scripts do", async ({ page, request }) => {
    await enforce(request, true);
    await injectInto(page, LIVE);
    await page.goto(LIVE);
    await page.waitForLoadState("load");
    await expect(page.locator("[data-studio-controller~='chat-reactions']")).toHaveCount(1);
    expect(await page.evaluate(() => typeof window.handleSolanaVerifySuccess)).toBe("function");
    await neverRan(page);
  });

  test("control: the same injection runs on the live board when the signing policy only reports", async ({ page }) => {
    await injectInto(page, LIVE);
    await page.goto(LIVE);
    await ranWithin(page, "drive");
  });
});

// A failed save re-renders a signing template. Its form posts natively, so
// the re-render is a document of its own, under the nonce it was rendered
// with: its inline scripts run, enforced, and nothing is refused.
//
// THE CONTROL is the same submit through Turbo (data-turbo dropped from the
// form). The response is a signing page, so Turbo reloads it instead of
// rendering it under the old document's nonce, and the error is gone. Each
// submit waits for the next document's load event, so a control cannot pass
// by reading the page before the response lands.
async function markDocument(page) {
  await page.evaluate(() => { window.__sameDocument = true; });
}

async function assertOwnWorkingDocument(page, path) {
  expect(await page.evaluate(() => window.__sameDocument)).toBeUndefined();
  expect(await page.evaluate(() => typeof window.handleSolanaVerifySuccess)).toBe("function");
  await expect.poll(() => page.evaluate(() => typeof window.Turbo)).toBe("object");
  const seen = await page.evaluate(() => window.__cspViolations);
  expect(seen.filter((v) => !pending(v, path))).toEqual([]);
}

// The account save's failure branch (accounts#update rescues and renders
// :show at 422). The admin has an email, so a new address goes to the
// confirm-by-email path and cannot fail; the submit reaches the branch by
// carrying no user params (the field renamed), which the action refuses.
async function failAccountSave(page, { turbo }) {
  await loginAdmin(page);
  await watchViolations(page);
  await page.goto("/account");
  const form = page.locator("form[action='/account']").filter({ has: page.locator("input[type='email']") });
  await expect(form).toHaveAttribute("data-turbo", "false");
  if (turbo) await form.evaluate((element) => element.removeAttribute("data-turbo"));
  await form.locator("input[type='email']").evaluate((input) => { input.name = "unpermitted"; });
  await markDocument(page);
  await Promise.all([ page.waitForEvent("load"), form.locator("button[type='submit']").click() ]);
}

async function failContestSave(page, { turbo }) {
  await loginAdmin(page);
  await watchViolations(page);
  await page.goto(`${CONTEST}/edit`);
  const form = page.locator(`form[action='${CONTEST}']`).filter({ has: page.locator("#contest_name") });
  await expect(form).toHaveAttribute("data-turbo", "false");
  if (turbo) await form.evaluate((element) => element.removeAttribute("data-turbo"));
  await markDocument(page);
  await page.locator("#contest_name").fill("");
  await Promise.all([ page.waitForEvent("load"), form.locator("[type='submit']").first().click() ]);
}

test.describe("failed saves", () => {
  test("enforced: a failed account save re-renders as its own document with working scripts", async ({ page, request }) => {
    await enforce(request, true);
    await failAccountSave(page, { turbo: false });
    await expect(page.getByText("Failed to update account.")).toBeVisible();
    await assertOwnWorkingDocument(page, "/account");
  });

  test("control: the same account save through Turbo loses the error", async ({ page, request }) => {
    await enforce(request, true);
    await failAccountSave(page, { turbo: true });
    await expect.poll(() => page.evaluate(() => window.__sameDocument)).toBeUndefined();
    await expect(page.getByText("Failed to update account.")).toHaveCount(0);
  });

  test("enforced: a failed contest save re-renders as its own document with working scripts", async ({ page, request }) => {
    await enforce(request, true);
    await failContestSave(page, { turbo: false });
    await expect(page.locator("#contest_name")).toHaveValue("");
    await expect(page.getByText(/can.t be blank/i).first()).toBeVisible();
    await assertOwnWorkingDocument(page, CONTEST);
  });

  test("control: the same contest save through Turbo loses the error", async ({ page, request }) => {
    await enforce(request, true);
    await failContestSave(page, { turbo: true });
    await expect.poll(() => page.evaluate(() => window.__sameDocument)).toBeUndefined();
    await expect(page.getByText(/can.t be blank/i)).toHaveCount(0);
  });
});

// THE FLIP HAZARD the unit guard (SigningCspUnitTest, "the enforce switch
// stays off while a gem fix is pending") exists for. Enforced, a signing page
// runs solana-studio's deep link only once the locked gem nonces it: while
// the server reads that fix as open, the wallet picker's mobile Phantom entry
// point is refused (the hazard is real, so the guard is not decoration); once
// the lock takes the fix, it is defined. The control: report-only, it runs.
test.describe("mobile Phantom deep link", () => {
  test("enforced: the deep link is refused while the gem fix is open, and runs once it lands", async ({ page, request }) => {
    const open = await enforce(request, true);
    await watchViolations(page);
    await page.goto(CONTEST);
    await page.waitForLoadState("load");
    const defined = await page.evaluate(() => typeof window.startPhantomDeepLink);
    const refused = (await page.evaluate(() => window.__cspViolations))
      .filter((v) => v.disposition === "enforce" && PENDING[0].sample.test(v.sample));
    if (open.includes(DEEP_LINK)) {
      expect(defined).toBe("undefined");
      expect(refused.length).toBeGreaterThan(0);
    } else {
      expect(defined).toBe("function");
      expect(refused).toEqual([]);
    }
  });

  test("control: report-only, the deep link runs", async ({ page }) => {
    await page.goto(CONTEST);
    await page.waitForLoadState("load");
    expect(await page.evaluate(() => typeof window.startPhantomDeepLink)).toBe("function");
  });
});

test.describe("early presses", () => {
  // The chat's "+" opens the reaction picker, pressed the moment the page
  // has loaded (chat-reactions is static, so it is already connected).
  test("chat-reactions: '+' pressed straight after load opens the picker", async ({ page }) => {
    await loginAdmin(page);
    await page.goto(CONTEST);
    const posted = await page.evaluate(async (path) => {
      // The test env renders no csrf-token meta and checks none.
      const token = document.querySelector('meta[name="csrf-token"]')?.content || "";
      const response = await fetch(`${path}/messages`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": token },
        body: JSON.stringify({ message: { body: "early press probe" } })
      });
      return response.status;
    }, CONTEST);
    expect(posted).toBe(200);

    await page.goto(CONTEST);
    // Dispatched on the button: the chat sits behind a tab and the quick bar
    // shows on hover, and neither is what this press is about.
    await page.locator(".chat-react-add").first().dispatchEvent("click");
    await expect(page.locator("#chat-reaction-picker")).toHaveClass(/is-open/);
  });

  // cosign-button is static, so a press straight after load reaches
  // cosignTransaction with the row's slug, label and extra cosigners.
  test("cosign-button: Co-sign pressed straight after load starts the cosign", async ({ page, request }) => {
    const seeded = await request.post("/test/set_pending_signatures", { form: { live: 1, stale: 0 } });
    expect(seeded.ok()).toBe(true);
    await page.addInitScript(() => {
      window.__cosignCalls = [];
      Object.defineProperty(window, "cosignTransaction", {
        configurable: true,
        get: () => (...args) => { window.__cosignCalls.push([ args[0], args[1], Array.isArray(args[2]) ]); },
        set: () => {}
      });
    });
    await loginAdmin(page);
    await page.goto("/admin/pending_transactions");
    const button = page.locator("button[data-studio-controller='cosign-button']").first();
    const slug = await button.getAttribute("data-tx-slug");
    await button.click();
    await expect.poll(() => page.evaluate(() => window.__cosignCalls.length)).toBe(1);
    const [ call ] = await page.evaluate(() => window.__cosignCalls);
    expect(call[0]).toBe(slug);
    expect(call[2]).toBe(true);
    await request.post("/test/set_pending_signatures", { form: { live: 0, stale: 0 } });
  });
});
