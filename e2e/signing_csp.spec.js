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
// sample a report quotes ('report-sample'). Each entry names what clears it;
// drop the entry when the lock takes that release.
const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

const CONTEST = "/contests/world-cup-2026";
const LAX = "/contests";

const PENDING = [
  // studio-engine studio/banners/_button: hover styles in inline handlers.
  { directive: "script-src-attr", sample: /^this\.style\./ },
  // solana-studio solana_studio/_phantom_deeplink: an un-nonced <script>.
  { directive: "script-src-elem", sample: /^\s*\(function \(\) \{\s*var STATEMENT/ },
  // studio-engine solana_sessions/phantom_callback: an un-nonced <script>.
  { directive: "script-src-elem", sample: /^\(function\(\) \{\s*var logEl = /, path: "/auth/phantom/callback" }
];

function pending(violation, path) {
  return PENDING.some((item) =>
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

async function enforce(request, enforced) {
  const response = await request.post("/test/signing_csp", { form: { enforced: String(enforced) } });
  expect(response.ok()).toBe(true);
}

const navigationUrl = (page) => page.evaluate(() => new URL(performance.getEntriesByType("navigation")[0].name).pathname);
const injected = (page) => page.evaluate(() => window.__injected);

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

test.beforeEach(async ({ request }) => await reseed(request));
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
    for (const path of [CONTEST, `${CONTEST}/edit`, "/contests/new", "/contests/generator", "/account", "/profile",
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
    await expect(page.locator("[data-controller~='chat-reactions']")).toHaveCount(1);
    expect(await injected(page)).toBeUndefined();
  });

  test("a script injected through a frame or a stream does not run on a signing page", async ({ page, request }) => {
    await enforce(request, true);
    await page.goto(CONTEST);
    await injectThroughFrame(page);
    await injectThroughStream(page);
    expect(await injected(page)).toBeUndefined();
  });

  // THE CONTROLS. The same probes, where nothing refuses them.
  test("the same Drive injection runs when the signing policy only reports", async ({ page }) => {
    await injectInto(page, CONTEST);
    await page.goto(CONTEST);
    expect(await injected(page)).toBe("drive");
  });

  test("the same frame and stream injections run on a page outside the group", async ({ page, request }) => {
    await enforce(request, true);
    await page.goto(LAX);
    await injectThroughFrame(page);
    expect(await injected(page)).toBe("frame");
    await injectThroughStream(page);
    expect(await injected(page)).toBe("stream");
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
    const button = page.locator("button[data-controller='cosign-button']").first();
    const slug = await button.getAttribute("data-tx-slug");
    await button.click();
    await expect.poll(() => page.evaluate(() => window.__cosignCalls.length)).toBe(1);
    const [ call ] = await page.evaluate(() => window.__cosignCalls);
    expect(call[0]).toBe(slug);
    expect(call[2]).toBe(true);
    await request.post("/test/set_pending_signatures", { form: { live: 0, stale: 0 } });
  });
});
