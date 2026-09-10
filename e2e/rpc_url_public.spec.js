const { test, expect } = require("@playwright/test");

// The BROWSER half of redact-helius-key-from-browser.
//
// Six surfaces used to emit Solana::Config::RPC_URL — the SERVER's endpoint,
// which carries a provider api-key on mainnet — straight into the response
// body. They now emit Solana::Config.public_rpc_url. Two questions follow from
// that change, and they belong to two different tiers:
//
//   1. "Does anything credentialed reach the DOM?" — answered in Ruby, at
//      test/integration/rpc_credential_not_in_browser_test.rb, because only
//      there can the server's constant be SWAPPED for a keyed value. The e2e
//      stack pins SOLANA_RPC_URL to a credential-free black-hole loopback
//      (see the playwright job in ci.yml), so asking it here would assert
//      against a value that is clean whether or not the fix exists.
//
//   2. "Does the client RPC path still work off what the server now emits?" —
//      acceptance criterion 2, and answerable ONLY in a browser. That is this
//      file. Nothing below is a markup assertion: one drives web3.js against
//      the live dataset value, the other reads text that DOES NOT EXIST in the
//      response bytes.
//
// The credential predicate is still asserted here as a standing tripwire. It
// is cheap, and if the e2e stack is ever pointed at a keyed endpoint it turns
// into a real one.

// Mirror of Solana::Config.credentialed_rpc_url? (app/services/solana/config.rb).
// Same three shapes, same fail-closed posture.
function credentialed(rawUrl) {
  if (!rawUrl) return false;
  let url;
  try {
    url = new URL(rawUrl);
  } catch (_) {
    return true; // unparseable -> assume the worst, as the Ruby side does
  }
  if (url.username || url.password) return true;
  if (url.search) return true;
  return url.pathname
    .split("/")
    .some((segment) => segment.length >= 20 && /^[A-Za-z0-9_-]+$/.test(segment));
}

test.describe("browser-facing Solana RPC endpoint", () => {
  // A markup assertion can see that data-solana-rpc-url has SOME value. It
  // cannot see whether web3.js can build a Connection out of it — and a
  // Connection that throws on construction breaks every Phantom flow on the
  // site (entry, contest create, cosign, off-ramp) while every String test in
  // the repo stays green. So: read the value through the live dataset API,
  // hand it to the real web3.js the page loaded, and make the library confirm
  // it round-trips.
  test("the live page builds a web3.js Connection from data-solana-rpc-url", async ({ page }) => {
    await page.goto("/contests");

    const probe = await page.evaluate(() => {
      const value = document.body.dataset.solanaRpcUrl;
      try {
        const connection = new window.solanaWeb3.Connection(value, "confirmed");
        return { value, endpoint: connection.rpcEndpoint, error: null };
      } catch (e) {
        return { value, endpoint: null, error: String(e) };
      }
    });

    expect(probe.error).toBeNull();
    expect(probe.value, "the layout emitted no RPC URL — every client TX flow needs one").toBeTruthy();
    expect(probe.endpoint, "web3.js did not accept the emitted endpoint").toBe(probe.value);
    expect(credentialed(probe.value), `credentialed RPC URL reached the browser`).toBe(false);
  });

  // /proof-of-reserves is PUBLIC and prints the endpoint to the visitor as
  // page text. The server ships that <span> EMPTY — Alpine fills it from the
  // cfg binding after mount — so its rendered value exists nowhere in the
  // response bytes and no assert_select / assert_match can ever observe it.
  // This is the surface that leaked the key to unauthenticated visitors, and
  // this is the only tier that can watch it resolve.
  test("proof-of-reserves renders its endpoint to the visitor at runtime", async ({ page }) => {
    await page.goto("/proof-of-reserves");

    const shown = page.locator('span[x-text="cfg.rpc_url"]').first();
    await expect(shown).toBeVisible();
    // Alpine has to populate it; an empty string here means the cfg binding
    // never resolved and the page is telling the visitor nothing.
    await expect(shown).not.toHaveText("");

    // Assert the PREDICATE, never the literal: a failure here must not print
    // the endpoint it is complaining about into a CI log.
    const rendered = (await shown.textContent()).trim();
    expect(
      credentialed(rendered),
      "the public page rendered a credentialed endpoint as visible text"
    ).toBe(false);
  });
});
