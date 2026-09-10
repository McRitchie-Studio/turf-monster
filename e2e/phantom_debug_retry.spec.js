const { test, expect } = require("@playwright/test");

// THE DEBUG PATCHER MUST SURVIVE PHANTOM'S INJECTION WINDOW — asserted in a real
// browser, because the claim is that a script RUNS, and no string assertion can
// observe that.
//
// app/javascript/debug_logger.js wraps Phantom's connect/signMessage/
// signTransaction to log them. attach() returned TRUE when
// walletProvider.get('phantom') was null, and its driver does
// `if (attach()) return;` BEFORE starting the retry interval — so one truthy
// answer meant the loop never ran. Phantom injects asynchronously, so null is the
// ordinary state during exactly the window the retry exists to wait out: the
// instrumentation silently never attached, and it is the tooling you reach for to
// debug Phantom.
//
// DELIBERATELY NOT setupPhantomMock: that installs via addInitScript, so Phantom
// is present before the module runs and the retry is never exercised. This spec
// loads with NO Phantom, then injects one — the real page-load timing, and the
// only shape that can fail on the old code.
test.setTimeout(60_000);

test("the Phantom debug patcher attaches to a wallet injected AFTER page load", async ({ page }) => {
  // THE STATE THE BUG NEEDS, and it cannot be planted before load: the layout
  // ASSIGNS window.walletProvider wholesale, clobbering anything an init script
  // put there. Two earlier versions of this spec passed against the broken code
  // for exactly that reason — with no `get` on the registry, attach()'s FIRST
  // guard returns false and the retry starts whether the bug is present or not.
  //
  // The discriminating state arrives on its own: once the real wallet_provider
  // module has loaded, `get` EXISTS and answers 'phantom' with null. That is the
  // ordinary shape of a page during Phantom's injection window, and the only
  // state in which the conflated guard trips.
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => typeof (window.walletProvider && window.walletProvider.get) === "function",
    null, { timeout: 10_000 }
  );

  // Let the retry take at least one tick in that state. With the bug it reports
  // "done" here and clears its interval; with the fix it keeps going.
  await page.waitForTimeout(400);

  // Phantom arrives, as an extension does a few hundred ms into a real load.
  await page.evaluate(() => {
    const stub = {
      name: "phantom",
      isPhantom: true,
      connect() { return Promise.resolve({ publicKey: { toBase58: () => "StubWallet" } }); },
      signMessage() { return Promise.resolve({ signature: new Uint8Array(64) }); },
      signTransaction(tx) { return Promise.resolve(tx); }
    };
    const registry = window.walletProvider;
    const previous = registry.get;
    registry.get = (name) => (name === "phantom" ? stub : (previous ? previous.call(registry, name) : null));
    window.__lateStub = stub;
  });

  // The driver retries every 100ms and gives up after 40 tries, so the whole
  // window is ~4s. Poll inside it.
  await expect
    .poll(async () => page.evaluate(() => !!(window.__lateStub && window.__lateStub.__debugPatched)),
          { timeout: 3500, intervals: [100] })
    .toBe(true);

  // A patched provider is a WRAPPED one — the function identity must have changed,
  // which only a live runtime can show. Asserting the flag alone would pass if
  // something merely set it.
  const wrapped = await page.evaluate(() => typeof window.__lateStub.signMessage === "function"
    && window.__lateStub.signMessage.toString().includes("arguments"));
  expect(wrapped, "the patcher must have replaced the method, not just set a flag").toBe(true);
});
