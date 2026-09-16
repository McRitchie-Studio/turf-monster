const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] /admin/authorities — the two things only a live browser can witness.
//
// ── WHAT THIS LANE CAN HONESTLY ASSERT, AND WHY IT IS NOT THE WHOLE PAGE ────
//
// CI's playwright server points SOLANA_RPC_URL at a black-hole loopback port on
// purpose (test/lib/ci_playwright_hermetic_test.rb: without it every
// authenticated render blocks on public devnet and the tightest assertion
// windows die first). So in THIS lane every server-side chain read fails and
// the page renders its degraded state. That is a constraint, not a gap to
// paper over — and it makes the FIRST assertion below one of the most valuable
// on the page:
//
//   AN AUTHORITY PAGE MUST SURVIVE AN UNREACHABLE RPC. It is opened during an
//   incident, which is exactly when a provider is most likely to be throttling
//   or down. Three live reads feed it and any of them can fail; a page that
//   500s on one, or that quietly renders a stale constant in place of a read,
//   is useless at the only moment it exists for. CI's black hole gives that
//   scenario for free, every run.
//
// The second is the Alpine planner. Its guards — compact-on-evict, and the
// continuity refusal — are JAVASCRIPT, and they have a failure mode with NO
// server-side symptom whatsoever: one stray quote in an `x-data` expression
// leaves the element rendered and nothing bound, so the markup greps clean,
// every Ruby tier passes, and the operator gets an inert form. The factory is
// defined at the bottom of the partial precisely so this lane can execute it.
//
// DELIBERATELY NOT HERE: arming, signing, broadcasting. Those need a readable
// signer set and a real wallet. They are covered at the tiers that CAN see
// them — test/controllers/admin/authorities_controller_test.rb for the server
// contract, test/services/solana/signer_rotation_test.rb for the guards, and a
// devnet rehearsal by an operator before it ships. A @devnet spec is NOT
// written here on purpose: devnet-nightly.yml has never once executed, so a
// spec filed there would be a tier that looks strict and collects nothing.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Authorities", () => {
  test("renders with every chain read failing @smoke", async ({ page }) => {
    // THE ASSERTIONS HERE ARE DELIBERATELY THE ONES THAT HOLD EITHER WAY.
    // CI black-holes the RPC and a developer's stack usually does not, so
    // anything keyed on a SUCCESSFUL read would pass in one place and fail in
    // the other — and a spec with two truths is worse than no spec. What is
    // asserted is what must be true of this page regardless: it renders, and it
    // names all three authorities.
    //
    // The degraded COPY ("could not be read", "refusing to guess") is pinned at
    // the component tier instead, where the failure can be stubbed rather than
    // waited for — test/views/admin_authorities_render_test.rb.
    await loginAdmin(page);
    await page.goto("/admin/authorities");

    // It renders at all under an unreachable RPC. Not a 500, not a blank —
    // which is the property that matters, because this page is opened during an
    // incident, exactly when a provider is most likely to be down.
    await expect(page.getByRole("heading", { name: "Authorities", level: 1 })).toBeVisible();

    await expect(page.getByRole("heading", { name: /Vault signer set/ })).toBeVisible();
    await expect(page.getByRole("heading", { name: /Program upgrade authority/ })).toBeVisible();
    await expect(page.getByRole("heading", { name: /Server signing identity/ })).toBeVisible();

    // The threshold table is derived from the Ruby mirror plus the program's
    // floors, so it survives a dead RPC — and it carries a `Source` column
    // precisely so a reader can tell a stored number from an assumed one.
    await expect(page.getByRole("columnheader", { name: "Source" })).toBeVisible();
  });

  test("the Squads link carries the cluster in its address, not its host", async ({ page }) => {
    // `devnet.squads.so` is decommissioned, so there is no cluster-flavoured
    // host to switch to. Asserting the rendered ANCHOR — rather than the helper
    // that built it — is what catches a hardcoded href creeping back in; the
    // admin hub tile carried one, pointing every cluster at the mainnet Squad.
    await loginAdmin(page);
    await page.goto("/admin/authorities");

    const link = page.getByRole("link", { name: /Open this cluster’s Squad/ });
    await expect(link).toBeVisible();
    const href = await link.getAttribute("href");
    expect(href).toMatch(/^https:\/\/app\.squads\.so\/squads\/[1-9A-HJ-NP-Za-km-z]{32,44}$/);
    expect(href).not.toContain("devnet.squads.so");
  });

  test("the eviction planner's JavaScript parsed and its guards run", async ({ page }) => {
    // THE FAILURE MODE THIS EXISTS FOR IS SILENT. An Alpine factory that throws
    // on parse, or an `x-data` attribute whose quoting ERB mangled, leaves the
    // page looking correct and bound to nothing. No Ruby tier can see it: the
    // markup is byte-identical either way.
    await loginAdmin(page);
    await page.goto("/admin/authorities");

    await expect
      .poll(() => page.evaluate(() => typeof window.evictionPlanner))
      .toBe("function");

    // ── COMPACT ON EVICT, NEVER GAP ──────────────────────────────────────
    // turf-vault refuses a set with a hole (SignerSetTooSmall 6052) so that
    // "empty" is always a suffix. Clearing a field in place would produce one
    // on the operator's very first click.
    const afterEvict = await page.evaluate(() => {
      const el = { dataset: { maxSlots: "5", required: "3",
                              currentSigners: "AAA,BBB,CCC,DDD,EEE" } };
      const planner = window.evictionPlanner();
      planner.init(el);
      planner.evict(0); // drop the first slot
      return { slots: planner.slots, live: planner.liveCount };
    });

    expect(afterEvict.slots).toEqual(["BBB", "CCC", "DDD", "EEE", ""]);
    expect(afterEvict.live).toBe(4);
    // The hole is gone, not moved: every empty is at the end.
    const firstEmpty = afterEvict.slots.indexOf("");
    expect(afterEvict.slots.slice(firstEmpty).every((s) => s === "")).toBe(true);

    // ── THE CONTINUITY REFUSAL, IN THE BROWSER ───────────────────────────
    // The rule an operator reliably trips: he picks the wallets he has, and one
    // of them is the key he is trying to remove. Saying so as he ticks is worth
    // far more than saying it after three Phantom dialogs and a fee.
    const refusal = await page.evaluate(() => {
      const el = { dataset: { maxSlots: "5", required: "3",
                              currentSigners: "AAA,BBB,CCC,DDD,EEE" } };
      const planner = window.evictionPlanner();
      planner.init(el);
      planner.slots = ["BBB", "CCC", "DDD", "", ""]; // AAA and EEE evicted
      planner.authorizers = ["AAA", "BBB", "CCC"];   // ...but AAA is signing
      return planner.conflict();
    });

    expect(refusal).toContain("AAA");
    expect(refusal).toContain("SignerContinuityRequired");
    expect(refusal).toContain("would sign this rotation and then be evicted by it");
  });

  test("a clean plan produces no refusal — the guard is not always-on", async ({ page }) => {
    // The control. A refusal that fires on every input is indistinguishable
    // from a refusal that fires correctly, and would pass the assertion above
    // just as happily.
    await loginAdmin(page);
    await page.goto("/admin/authorities");

    const verdicts = await page.evaluate(() => {
      const el = { dataset: { maxSlots: "5", required: "3",
                              currentSigners: "AAA,BBB,CCC,DDD,EEE" } };
      const planner = window.evictionPlanner();
      planner.init(el);

      planner.slots = ["BBB", "CCC", "DDD", "", ""];
      planner.authorizers = ["BBB", "CCC", "DDD"]; // every signer survives
      const clean = planner.conflict();

      planner.authorizers = ["BBB", "BBB", "CCC"]; // the same wallet twice
      const duplicate = planner.conflict();

      return { clean, duplicate };
    });

    expect(verdicts.clean).toBe("");
    expect(verdicts.duplicate).toContain("DuplicateSigner");
  });

  test("the page is reachable only by an admin", async ({ page }) => {
    // It names every key that can move money on this platform.
    await page.goto("/admin/authorities");
    await expect(page.getByRole("heading", { name: /Vault signer set/ })).toHaveCount(0);
  });
});
