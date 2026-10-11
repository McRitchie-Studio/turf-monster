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
// The third is the signing ceremony, driven through the page's own
// cosignTransaction against stubbed /rebuild and /broadcast answers and a mock
// Phantom holding real keypairs. The stubbed answers take the shape
// test/controllers/admin/authorities_controller_test.rb pins on the server, so
// the two tiers meet at the JSON. This lane cannot arm a real row: arming needs
// a readable signer set, and the RPC here is black-holed.
//
// NOT HERE: a real arm and a real broadcast. Those are covered by the
// controller tests, test/services/solana/signer_rotation_test.rb for the
// guards, and a devnet rehearsal by an operator.
test.beforeEach(async ({ request }) => await reseed(request));

// A Phantom that exposes one account at a time and moves only when the spec
// calls switchAccount(), so a flow that asks for a wallet nobody holds stalls
// visibly instead of signing with whoever is selected.
async function installPhantomLab(page) {
  await page.addInitScript(() => {
    const lab = (window.__evictionLab = {
      queue: [],
      active: 0,
      signed: [],
      sign: null,
      switchAccount() {
        lab.active = Math.min(lab.active + 1, lab.queue.length - 1);
      }
    });
    const activeKey = () => lab.queue[lab.active] || null;
    window.solana = {
      isPhantom: true,
      get publicKey() {
        const key = activeKey();
        return key ? { toBase58: () => key } : null;
      },
      connect: async () => ({ publicKey: window.solana.publicKey }),
      signTransaction: async (tx) => {
        lab.signed.push(activeKey());
        return lab.sign(tx, lab.active);
      }
    };
  });
}

// An update_signers-shaped wire: account 0 (the lead, fee payer) and the
// cosigner both sign. Server-led: the server's keypair signs account 0 here,
// and Phantom holds only the cosigner. Operator-led: nothing is pre-signed,
// and Phantom holds both.
async function buildEvictionWire(page, { serverLeads }) {
  return page.evaluate((serverLed) => {
    const lab = window.__evictionLab;
    const lead = solanaWeb3.Keypair.generate();
    const cosigner = solanaWeb3.Keypair.generate();

    const tx = new solanaWeb3.Transaction();
    tx.recentBlockhash = solanaWeb3.Keypair.generate().publicKey.toBase58();
    tx.feePayer = lead.publicKey;
    tx.add(new solanaWeb3.TransactionInstruction({
      keys: [
        { pubkey: lead.publicKey, isSigner: true, isWritable: true },
        { pubkey: cosigner.publicKey, isSigner: true, isWritable: false }
      ],
      programId: solanaWeb3.SystemProgram.programId,
      data: new Uint8Array([0])
    }));
    if (serverLed) tx.partialSign(lead);
    const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });

    const phantom = serverLed ? [cosigner] : [lead, cosigner];
    lab.queue = phantom.map((k) => k.publicKey.toBase58());
    lab.active = 0;
    lab.signed = [];
    lab.sign = async (incoming, index) => {
      incoming.partialSign(phantom[index]);
      return incoming;
    };
    window.confirmSolanaNetworkIntent = async () => true;

    return {
      wire: btoa(String.fromCharCode.apply(null, new Uint8Array(bytes))),
      lead: lead.publicKey.toBase58(),
      cosigner: cosigner.publicKey.toBase58()
    };
  }, serverLeads);
}

// Route /rebuild and /broadcast for one eviction. `rebuildBody` is built from
// the fixture once it exists, in the shape Admin::AuthoritiesController#rebuild
// answers.
async function routeEviction(page, rebuildBody) {
  const state = { fixture: null, broadcasts: [] };
  await page.route("**/admin/authorities/ptx-e2e/rebuild", async (route) => {
    await route.fulfill({
      status: state.fixture ? 200 : 500,
      contentType: "application/json",
      body: JSON.stringify(state.fixture ? rebuildBody(state.fixture)
                                         : { error: "spec bug: fixture not built" })
    });
  });
  await page.route("**/admin/authorities/ptx-e2e/broadcast", async (route) => {
    state.broadcasts.push(route.request().postDataJSON());
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ status: "confirmed", tx_signature: "EvictionLanded1111111111" })
    });
  });
  return state;
}

function startEviction(page) {
  return page.evaluate(() => {
    window.__evictionDone = window.cosignTransaction("ptx-e2e", "Signer Eviction", [], null, {
      rebuildUrl: "/admin/authorities/ptx-e2e/rebuild",
      broadcastUrl: "/admin/authorities/ptx-e2e/broadcast",
      successNoun: "signer rotation",
      backLabel: "Back to Authorities"
    });
  });
}

function modalState(page) {
  return page.evaluate(() => {
    const m = window.Alpine && window.Alpine.store("solanaModal");
    return m ? { state: m.state, title: m.title, message: m.message, errorMessage: m.errorMessage } : null;
  });
}

function verifyWire(page, b64) {
  return page.evaluate((wire) => {
    const tx = window.solanaWeb3.Transaction.from(Uint8Array.from(atob(wire), (c) => c.charCodeAt(0)));
    return { verifies: tx.verifySignatures(), signed: tx.signatures.filter((p) => p.signature).length };
  }, b64);
}

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
    // The path is `/squads/<VAULT PDA>/home`. This regex used to end at the
    // address with no suffix, which is the form that 404s: app.squads.so
    // resolves a Squad by its vault PDA and wants `/home`
    // (link-squads-from-admin, measured in a browser 2026-09-29).
    expect(href).toMatch(/^https:\/\/app\.squads\.so\/squads\/[1-9A-HJ-NP-Za-km-z]{32,44}\/home$/);
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

  test("the planner warns on a malformed address before arming", async ({ page }) => {
    // QA armed `<key>.`: a full stop pasted with the key. The arm endpoint now
    // refuses it; the planner says so first.
    await loginAdmin(page);
    await page.goto("/admin/authorities");

    const verdicts = await page.evaluate(() => {
      const good = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr";
      const el = { dataset: { maxSlots: "3", required: "2", currentSigners: good } };
      const planner = window.evictionPlanner();
      planner.init(el);
      const check = (value) => { planner.slots = [good, value, ""]; return planner.malformed(); };
      return {
        clean: check(""),
        padded: check(" " + good + " "),
        trailingDot: check(good + "."),
        // Four characters short: a key one character short can still decode
        // to 32 bytes, which is a different valid key no format check sees.
        short: check(good.slice(0, -4)),
        notBase58: check("0" + good.slice(1))
      };
    });

    expect(verdicts.clean).toBe("");
    expect(verdicts.padded).toBe("");
    expect(verdicts.trailingDot).toContain("7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr.");
    expect(verdicts.trailingDot).toContain("not a Solana address");
    expect(verdicts.short).toContain("not a Solana address");
    expect(verdicts.notBase58).toContain("not a Solana address");
  });

  test("a server-led eviction collects ONE Phantom signature and broadcasts @smoke", async ({ page }) => {
    // The server signs account 0 at build time, so Phantom owes only the
    // cosigner. The defect: the queue carried the server's key too, and the
    // flow asked the operator to switch Phantom to a key no one holds.
    await installPhantomLab(page);
    await loginAdmin(page);
    const routes = await routeEviction(page, (f) => ({
      status: "rebuilt",
      serialized_tx: f.wire,
      required_signatures: 2,
      signer_queue: [f.cosigner],
      cosigner_address: f.cosigner,
      extra_cosigners: [],
      fee_payer_address: f.lead
    }));
    await page.goto("/admin/authorities");

    routes.fixture = await buildEvictionWire(page, { serverLeads: true });
    await startEviction(page);

    await expect.poll(() => routes.broadcasts.length, { timeout: 10_000 }).toBe(1);
    await page.evaluate(() => window.__evictionDone);

    // One signTransaction call, from the cosigner. No switch was asked for.
    const signedBy = await page.evaluate(() => window.__evictionLab.signed);
    expect(signedBy).toEqual([routes.fixture.cosigner]);

    const body = routes.broadcasts[0];
    expect(body.signer_queue).toEqual([routes.fixture.cosigner]);
    expect(body.signer_queue).not.toContain(routes.fixture.lead);

    // Both slots are filled and every signature checks out.
    const wire = await verifyWire(page, body.signed_tx);
    expect(wire).toEqual({ verifies: true, signed: 2 });
    await expect.poll(() => modalState(page).then((m) => m && m.state)).toBe("success");
  });

  test("an operator-led eviction collects the lead and the cosigner", async ({ page }) => {
    // Account 0 is the operator's wallet, so the queue carries it and the flow
    // waits for him to switch to the cosigner.
    await installPhantomLab(page);
    await loginAdmin(page);
    const routes = await routeEviction(page, (f) => ({
      status: "rebuilt",
      serialized_tx: f.wire,
      required_signatures: 2,
      signer_queue: [f.lead, f.cosigner],
      cosigner_address: f.cosigner,
      extra_cosigners: [],
      fee_payer_address: null
    }));
    await page.goto("/admin/authorities");

    routes.fixture = await buildEvictionWire(page, { serverLeads: false });
    await startEviction(page);

    await expect
      .poll(() => modalState(page).then((m) => m && m.title), { timeout: 10_000 })
      .toBe("Switch Phantom Account");
    await page.evaluate(() => window.__evictionLab.switchAccount());

    await expect.poll(() => routes.broadcasts.length, { timeout: 10_000 }).toBe(1);
    await page.evaluate(() => window.__evictionDone);

    const signedBy = await page.evaluate(() => window.__evictionLab.signed);
    expect(signedBy).toEqual([routes.fixture.lead, routes.fixture.cosigner]);
    expect(routes.broadcasts[0].signer_queue).toEqual([routes.fixture.lead, routes.fixture.cosigner]);
    expect(await verifyWire(page, routes.broadcasts[0].signed_tx)).toEqual({ verifies: true, signed: 2 });
  });

  test("control: a queue naming the server's key stalls on a switch nobody can make", async ({ page }) => {
    // The answer the server gave before the fix. The browser obeys the queue,
    // so it asks Phantom for the server's key and never broadcasts. This is why
    // the server, not the browser, must leave its own lead out.
    await installPhantomLab(page);
    await loginAdmin(page);
    const routes = await routeEviction(page, (f) => ({
      status: "rebuilt",
      serialized_tx: f.wire,
      required_signatures: 2,
      signer_queue: [f.lead, f.cosigner],
      cosigner_address: f.cosigner,
      extra_cosigners: [],
      fee_payer_address: f.lead
    }));
    await page.goto("/admin/authorities");

    routes.fixture = await buildEvictionWire(page, { serverLeads: true });
    await startEviction(page);

    await expect
      .poll(() => modalState(page).then((m) => m && m.title), { timeout: 10_000 })
      .toBe("Switch Phantom Account");
    const modal = await modalState(page);
    const lead = routes.fixture.lead;
    expect(modal.message).toContain(lead.slice(0, 4) + "\u2026" + lead.slice(-4));
    expect(routes.broadcasts).toHaveLength(0);
  });

  test("the page is reachable only by an admin", async ({ page }) => {
    // It names every key that can move money on this platform.
    await page.goto("/admin/authorities");
    await expect(page.getByRole("heading", { name: /Vault signer set/ })).toHaveCount(0);
  });
});
