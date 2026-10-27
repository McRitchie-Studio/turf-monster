const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, lazyController } = require("./helpers");

// [e2e] /admin/authorities — the signer console and the Squads proposals,
// driven in a real browser against a MOCK Phantom holding real keypairs.
//
// ── WHAT THIS LANE CAN HONESTLY ASSERT ──────────────────────────────────────
//
// CI's playwright server black-holes SOLANA_RPC_URL (test/lib/
// ci_playwright_hermetic_test.rb), so every server-side chain read fails. The
// console therefore takes its state from JSON endpoints (console, plan,
// rotations, broadcast, proposals, approve), and this spec stands in for the
// chain by routing them, in the shapes test/controllers/admin/
// authorities_controller_test.rb pins on the server. The two tiers meet at the
// JSON. Nothing here signs or sends on any cluster: Phantom is a mock, and
// every endpoint that would broadcast is routed.
//
// NOT HERE: the server's derivation (test/services/solana/signer_plan_test.rb),
// the build and its server-held signatures (vault_update_signers_server_
// cosigners_test.rb), and a real devnet run by an operator.
test.beforeEach(async ({ request }) => await reseed(request));

// A Phantom that exposes one account at a time and moves only when the spec
// calls switchAccount(), so a flow that asks for a wallet nobody holds stalls
// visibly instead of signing with whoever is selected.
async function installPhantomLab(page) {
  await page.addInitScript(() => {
    const lab = (window.__consoleLab = {
      keys: [],
      active: 0,
      signed: [],
      sent: [],
      switchAccount() { lab.active = Math.min(lab.active + 1, lab.keys.length - 1); }
    });
    const activeKey = () => lab.keys[lab.active] || null;
    window.solana = {
      isPhantom: true,
      get publicKey() {
        const key = activeKey();
        return key ? key.publicKey : null;
      },
      // `lab.holdConnect = true` keeps the connect prompt "open" until the
      // spec calls lab.releaseConnect(), so it can act while Phantom waits.
      connect: () => {
        if (!lab.holdConnect) return Promise.resolve({ publicKey: window.solana.publicKey });
        return new Promise((resolve) => {
          lab.releaseConnect = () => { lab.holdConnect = false; resolve({ publicKey: window.solana.publicKey }); };
        });
      },
      signTransaction: async (tx) => {
        const key = activeKey();
        lab.signed.push(key.publicKey.toBase58());
        tx.partialSign(key);
        return tx;
      },
      signAndSendTransaction: async (tx) => {
        const key = activeKey();
        tx.partialSign(key);
        lab.sent.push({ signer: key.publicKey.toBase58(), verifies: tx.verifySignatures() });
        return { signature: "ApproveLanded1111111111111111111111111111" };
      }
    };
    window.confirmSolanaNetworkIntent = async () => true;
  });
}

// Generate the cast in the page (solanaWeb3 is loaded there) and build an
// update_signers-shaped wire the SERVER and its held cosigner already signed.
async function castAndWire(page, { phantomCount }) {
  return page.evaluate((count) => {
    const W = window.solanaWeb3;
    const lab = window.__consoleLab;
    const server = W.Keypair.generate();
    const held = W.Keypair.generate();
    const added = W.Keypair.generate().publicKey.toBase58();
    lab.keys = Array.from({ length: count }, () => W.Keypair.generate());
    lab.active = 0;

    const tx = new W.Transaction();
    tx.recentBlockhash = W.Keypair.generate().publicKey.toBase58();
    tx.feePayer = server.publicKey;
    tx.add(new W.TransactionInstruction({
      keys: [server, held, ...lab.keys].map((k, i) => ({ pubkey: k.publicKey, isSigner: true, isWritable: i === 0 })),
      programId: W.SystemProgram.programId,
      data: new Uint8Array([0])
    }));
    tx.partialSign(server, held);
    const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
    return {
      server: server.publicKey.toBase58(),
      held: held.publicKey.toBase58(),
      alex: lab.keys.map((k) => k.publicKey.toBase58()),
      added,
      wire: btoa(String.fromCharCode.apply(null, new Uint8Array(bytes)))
    };
  }, phantomCount);
}

function labels(cast) {
  const out = {
    [cast.server]: { name: "Server key", holder: "agent", server: true, unknown: false },
    [cast.held]: { name: "Mason", holder: "agent", server_held: true, unknown: false },
    [cast.added]: { name: "New server key", holder: "agent", unknown: false }
  };
  cast.alex.forEach((k, i) => { out[k] = { name: `Alex ${i + 1}`, holder: "alex", unknown: false } })
  return out;
}

function consoleState(cast) {
  return {
    ok: true,
    rules: {
      shape: "v0.26", network: "devnet", max_slots: 5, required: 3,
      intents: { replace: null, add: null, remove: null },
      continuity: "3 of the wallets that sign a rotation must stay in the new set.",
      server: cast.server, server_seated: true, server_held: [cast.held], operator_led_allowed: true
    },
    current: [cast.server, ...cast.alex, cast.held],
    labels: labels(cast),
    candidates: [cast.added],
    console_nonce: { state: "missing", pubkey: null, prepare_url: "/admin/authorities/console_nonce" },
    live_rotation: null
  };
}

function planFor(cast) {
  const current = [cast.server, ...cast.alex, cast.held];
  const queue = cast.alex;
  const authorizers = cast.alex.length === 1 ? [cast.server, cast.held, cast.alex[0]] : [cast.server, ...cast.alex];
  return {
    ok: true, shape: "v0.26", max_slots: 5, required_signatures: 3,
    current, proposed: [...current, cast.added], evicted: [], added: [cast.added],
    authorizers, lead_signer: cast.server, server_leads: true,
    server_held: cast.alex.length === 1 ? [cast.held] : [],
    phantom_queue: queue, prompt_count: queue.length,
    sentence: "The server signs for itself.", labels: labels(cast)
  };
}

// Route every console endpoint. `cast` is filled once the page has generated
// it; the console's first read happens before that and answers unreadable,
// which is itself the dead-RPC path. Connecting Phantom re-reads.
async function routeConsole(page, overrides = {}) {
  const state = { cast: null, plans: [], rotations: 0, broadcasts: [], cancels: 0, prepares: 0,
                  nonceReady: !!overrides.nonceReady, outstanding: overrides.outstanding };
  const json = (route, status, body) =>
    route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

  await page.route("**/admin/authorities/console*", (route) =>
    state.cast ? json(route, 200, withNonce(consoleState(state.cast), state))
               : json(route, 503, { ok: false, code: "unreadable", message: "Vault state could not be read." }));
  await page.route("**/admin/authorities/console_nonce", (route) => {
    state.prepares++;
    state.nonceReady = true;
    return json(route, 200, { ok: true, signature: "NoncePrepared1111111111111111" });
  });
  await page.route("**/admin/authorities/plan", (route) => {
    state.plans.push(route.request().postDataJSON());
    const refused = overrides.plan && overrides.plan(state);
    return refused ? json(route, 422, refused) : json(route, 200, planFor(state.cast));
  });
  await page.route("**/admin/authorities/rotations", (route) => {
    state.rotations++;
    state.rotationBodies = (state.rotationBodies || []).concat([route.request().postDataJSON()]);
    const refused = overrides.rotations && overrides.rotations(state);
    if (refused) return json(route, 422, refused);
    const plan = planFor(state.cast);
    const built = overrides.builtSet ? overrides.builtSet(plan.proposed) : plan.proposed;
    return json(route, 200, {
      new_signers: [...built, ...Array(5 - built.length).fill("11111111111111111111111111111111")],
      status: "rebuilt", serialized_tx: state.cast.wire,
      signer_queue: overrides.queue ? overrides.queue(state) : plan.phantom_queue,
      server_signed: [state.cast.server, state.cast.held], slug: "ptx-e2e",
      nonce_anchored: state.nonceReady,
      broadcast_url: "/admin/authorities/ptx-e2e/broadcast", cancel_url: "/admin/authorities/ptx-e2e/cancel",
      rebuild_url: "/admin/authorities/ptx-e2e/rebuild"
    });
  });
  await page.route("**/admin/authorities/ptx-e2e/broadcast", (route) => {
    state.broadcasts.push(route.request().postDataJSON());
    const expected = planFor(state.cast).proposed;
    const signers = overrides.readBack ? overrides.readBack(expected) : expected;
    return json(route, 200, { status: "confirmed", tx_signature: "RotationLanded111111111111111", signers, expected });
  });
  await page.route("**/admin/authorities/ptx-e2e/cancel", (route) => {
    state.cancels++;
    return json(route, 200, { ok: true, message: "Armed eviction discarded." });
  });
  await page.route("**/admin/authorities/proposals*", (route) =>
    json(route, 200, { ok: true, network: "devnet", squads_url: "https://app.squads.so/squads/VAULT/transactions", proposals: [] }));
  return state;
}

// The console nonce as the server reports it: ready once prepared.
function withNonce(body, state) {
  if (state.outstanding) body.outstanding_wires = state.outstanding;
  if (state.nonceReady) {
    body.console_nonce = { state: "ready", pubkey: "NonceAcct1111111111111111111111111111111111",
                           prepare_url: "/admin/authorities/console_nonce" };
  }
  return body;
}

async function openConsole(page, { phantomCount = 1, overrides = {}, clock = false } = {}) {
  if (clock) await page.clock.install();
  await installPhantomLab(page);
  const routes = await routeConsole(page, overrides);
  await loginAdmin(page);
  await page.goto("/admin/authorities");
  await lazyController(page, "signer-console");
  routes.cast = await castAndWire(page, { phantomCount });
  await page.getByRole("button", { name: /Connect Phantom/ }).click();
  await expect(page.getByText("Vault signer set: v0.26, 5 slots, 3 signatures to rotate.")).toBeVisible();
  return routes;
}

async function draftAdd(page, routes) {
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await page.locator(`input[data-pick][value="${routes.cast.added}"]`).check();
}

function verifies(page, b64) {
  return page.evaluate((wire) => {
    const tx = window.solanaWeb3.Transaction.from(Uint8Array.from(atob(wire), (c) => c.charCodeAt(0)));
    return tx.verifySignatures();
  }, b64);
}

test.describe("Signer console", () => {
  test("renders with every chain read failing @smoke", async ({ page }) => {
    // Under CI's black-holed RPC the page must still render and name all three
    // authorities; the console says it cannot plan rather than guessing.
    await loginAdmin(page);
    await page.goto("/admin/authorities");
    await expect(page.getByRole("heading", { name: "Authorities", level: 1 })).toBeVisible();
    await expect(page.getByRole("heading", { name: /Vault signer set/ }).first()).toBeVisible();
    await expect(page.getByRole("heading", { name: /Program upgrade authority/ })).toBeVisible();
    await expect(page.getByRole("heading", { name: /Server signing identity/ })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Source" })).toBeVisible();
    await expect(page.locator("[data-signer-console-target='cta']")).toBeDisabled();
  });

  test("the Squads link carries the cluster in its address, not its host", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/authorities");
    const link = page.getByRole("link", { name: /Open this cluster’s Squad/ });
    const href = await link.getAttribute("href");
    expect(href).toMatch(/^https:\/\/app\.squads\.so\/squads\/[1-9A-HJ-NP-Za-km-z]{32,44}\/home$/);
  });

  test("server-led: one Phantom prompt, as Alex, never as a server-held key @smoke", async ({ page }) => {
    const routes = await openConsole(page);
    await draftAdd(page, routes);

    const cta = page.locator("[data-signer-console-target='cta']");
    await expect(cta).toHaveText("Sign in Phantom (1 prompt)");
    await expect(cta).toBeEnabled();
    // The review shows the full address, grouped, and the connected-account match.
    await expect(page.getByText("Matches your connected Phantom account.").first()).toBeVisible();

    await cta.click();
    await expect(page.getByText("Landed. The chain now holds:")).toBeVisible();

    const lab = await page.evaluate(() => window.__consoleLab.signed);
    expect(lab).toEqual(routes.cast.alex);
    expect(lab).not.toContain(routes.cast.server);
    expect(lab).not.toContain(routes.cast.held);
    expect(routes.broadcasts).toHaveLength(1);
    expect(routes.broadcasts[0].signer_queue).toEqual(routes.cast.alex);
    expect(await verifies(page, routes.broadcasts[0].signed_tx)).toBe(true);
  });

  test("two prompts, in order, with the account switch between them", async ({ page }) => {
    const routes = await openConsole(page, { phantomCount: 2 });
    await draftAdd(page, routes);

    const cta = page.locator("[data-signer-console-target='cta']");
    await expect(cta).toHaveText("Sign in Phantom (2 prompts)");
    await cta.click();

    // The first prompt signs as account 1, then the console waits for account 2.
    const second = routes.cast.alex[1];
    await expect(page.getByText(`switch to ${second.slice(0, 4)}…${second.slice(-4)}`)).toBeVisible();
    expect(routes.broadcasts).toHaveLength(0);
    await page.evaluate(() => window.__consoleLab.switchAccount());

    await expect(page.getByText("Landed. The chain now holds:")).toBeVisible();
    expect(await page.evaluate(() => window.__consoleLab.signed)).toEqual(routes.cast.alex);
    expect(await verifies(page, routes.broadcasts[0].signed_tx)).toBe(true);
  });

  // ptx-432 and ptx-433 died while Alex switched accounts between two prompts.
  // A missing console nonce says so and offers one click; once ready, the
  // console promises no time limit.
  test("a missing console nonce offers one prepare click, then the console reads untimed", async ({ page }) => {
    const routes = await openConsole(page);
    const nonce = page.locator("[data-signer-console-target='nonce']");
    const prepare = page.getByRole("button", { name: "Prepare console nonce" });

    await expect(nonce).toHaveText(/about 45 seconds/);
    await expect(prepare).toBeVisible();
    await prepare.click();

    await expect(nonce).toHaveText(/No time limit/);
    await expect(prepare).toBeHidden();
    expect(routes.prepares).toBe(1);
  });

  test("a nonce-anchored build keeps waiting for the account switch past three minutes", async ({ page }) => {
    const routes = await openConsole(page, { phantomCount: 2, clock: true, overrides: { nonceReady: true } });
    await draftAdd(page, routes);
    await page.locator("[data-signer-console-target='cta']").click();

    const second = routes.cast.alex[1];
    await expect(page.getByText(`switch to ${second.slice(0, 4)}…${second.slice(-4)}`)).toBeVisible();
    // Past the blockhash-era three-minute cutoff: the console is still waiting.
    await page.clock.runFor(4 * 60 * 1000);
    // A timed-out wait cancels the row over the network before it shows its
    // error, so give that path real time to surface before asserting it did not.
    await page.waitForTimeout(1000);
    await expect(page.getByText(/Timed out waiting for Phantom/)).toHaveCount(0);
    expect(routes.cancels).toBe(0);

    await page.evaluate(() => window.__consoleLab.switchAccount());
    await page.clock.runFor(1000);
    await expect(page.getByText("Landed. The chain now holds:")).toBeVisible();
    expect(await verifies(page, routes.broadcasts[0].signed_tx)).toBe(true);
  });

  // A signed rotation that ended without landing stays landable until its
  // nonce moves. One the server cannot kill (another key's nonce) is named.
  test("an ended rotation stranded on another key's nonce is named on the console", async ({ page }) => {
    await openConsole(page, {
      overrides: { outstanding: [{ slug: "ptx-old", nonce: "NonceOld111111111111111111111111111111111", voidable: false }] }
    });
    const nonce = page.locator("[data-signer-console-target='nonce']");
    await expect(nonce).toHaveText(/1 ended rotation\(s\) could still land \(ptx-old\)/);
    await expect(nonce).toHaveText(/advance it with the old server key/);
  });

  test("a malformed paste is refused in the field and makes no request", async ({ page }) => {
    const routes = await openConsole(page);
    await page.getByRole("button", { name: "Add", exact: true }).click();
    const before = routes.plans.length;

    await page.locator("#signer-console-paste").fill(`${routes.cast.added}.`);
    await expect(page.getByText(/is not a Solana address \(32 bytes of base58\)/)).toBeVisible();
    await expect(page.locator("[data-signer-console-target='cta']")).toBeDisabled();
    expect(routes.plans.length).toBe(before);
  });

  test("a refused plan renders inline and keeps the draft", async ({ page }) => {
    const routes = await openConsole(page, {
      overrides: {
        plan: () => ({ ok: false, code: "chain_rule", chain_code: 6017,
                       message: "Refused: continuity (turf-vault would reject this as SignerContinuityRequired, 6017.)" })
      }
    });
    await draftAdd(page, routes);

    await expect(page.getByText(/SignerContinuityRequired, 6017/)).toBeVisible();
    await expect(page.getByRole("button", { name: "Add", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator(`input[data-pick][value="${routes.cast.added}"]`)).toBeChecked();
    await expect(page.locator("[data-signer-console-target='cta']")).toBeDisabled();
    expect(routes.rotations).toBe(0);
  });

  test("a read-back that differs from the plan is loud and names the slot", async ({ page }) => {
    const routes = await openConsole(page, {
      overrides: { readBack: (expected) => [...expected.slice(0, 3), expected[4], expected[3]] }
    });
    await draftAdd(page, routes);
    await page.locator("[data-signer-console-target='cta']").click();
    await expect(page.getByText(/One slot differs from the plan: slot 4/)).toBeVisible();
    await expect(page.locator("tr[data-readback-row='4'][data-match='false']")).toBeVisible();
  });

  test("control: a server queue that differs from the reviewed plan signs nothing and cancels", async ({ page }) => {
    const routes = await openConsole(page, { overrides: { queue: (s) => [s.cast.held, ...s.cast.alex] } });
    await draftAdd(page, routes);
    await page.locator("[data-signer-console-target='cta']").click();

    await expect(page.getByText(/differs from the plan you reviewed/)).toBeVisible();
    expect(await page.evaluate(() => window.__consoleLab.signed)).toEqual([]);
    expect(routes.cancels).toBe(1);
    expect(routes.broadcasts).toHaveLength(0);
  });

  test("a pick changed while the connect prompt is open never reaches the build", async ({ page }) => {
    const routes = await openConsole(page);
    await draftAdd(page, routes);
    await page.evaluate(() => { window.__consoleLab.holdConnect = true; });
    await page.locator("[data-signer-console-target='cta']").click();

    // Phantom's connect prompt is open. The picks are locked, and even a
    // forced change event is ignored by the console.
    const pick = page.locator(`input[data-pick][value="${routes.cast.added}"]`);
    await expect(pick).toBeDisabled();
    await expect(page.getByRole("button", { name: "Remove", exact: true })).toBeDisabled();
    await page.evaluate((key) => {
      const box = document.querySelector(`input[data-pick][value="${key}"]`);
      box.checked = false;
      box.dispatchEvent(new Event("change", { bubbles: true }));
    }, routes.cast.added);
    const plansBefore = routes.plans.length;
    await page.evaluate(() => window.__consoleLab.releaseConnect());

    await expect(page.getByText("Landed. The chain now holds:")).toBeVisible();
    const body = routes.rotationBodies[0];
    expect(body.add).toEqual([routes.cast.added]);
    expect(body.reviewed_proposed).toEqual(planFor(routes.cast).proposed);
    expect(body.reviewed_authorizers).toEqual(planFor(routes.cast).authorizers);
    expect(routes.plans.length).toBe(plansBefore);
  });

  test("the server refusing an unreviewed set signs nothing and keeps the draft", async ({ page }) => {
    const routes = await openConsole(page, {
      overrides: { rotations: () => ({ ok: false, code: "reviewed_set_mismatch",
                                       message: "The set or signers about to be built differ from the plan you reviewed." }) }
    });
    await draftAdd(page, routes);
    await page.locator("[data-signer-console-target='cta']").click();

    await expect(page.getByText(/differ from the plan you reviewed/)).toBeVisible();
    expect(await page.evaluate(() => window.__consoleLab.signed)).toEqual([]);
    expect(routes.broadcasts).toHaveLength(0);
    await expect(page.locator(`input[data-pick][value="${routes.cast.added}"]`)).toBeEnabled();
  });

  test("control: bytes carrying a set other than the reviewed one sign nothing and cancel", async ({ page }) => {
    const routes = await openConsole(page, {
      overrides: { builtSet: (proposed) => [...proposed.slice(0, -1), proposed[1]] }
    });
    await draftAdd(page, routes);
    await page.locator("[data-signer-console-target='cta']").click();

    await expect(page.getByText(/built signer set differs from the set you reviewed/)).toBeVisible();
    expect(await page.evaluate(() => window.__consoleLab.signed)).toEqual([]);
    expect(routes.cancels).toBe(1);
    expect(routes.broadcasts).toHaveLength(0);
  });

  test("a ceremony link pre-fills the intent and the keys", async ({ page }) => {
    // Public roster keys stand in for the cast: nothing signs in this test.
    const routes = await routeConsole(page);
    routes.cast = {
      server: "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd",
      held: "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR",
      alex: ["7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"],
      added: "4S39sKHHPV8GPjUif9noN9gdsAFGs9WASuGxs7B9s5CY",
      wire: ""
    };
    await loginAdmin(page);
    await page.goto(`/admin/authorities?intent=add&add=${routes.cast.added}`);
    await lazyController(page, "signer-console");

    await expect(page.getByRole("button", { name: "Add", exact: true })).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator(`input[data-pick][value="${routes.cast.added}"]`)).toBeChecked();
    await expect(page.locator("[data-signer-console-target='cta']")).toHaveText("Sign in Phantom (1 prompt)");
    expect(routes.plans[0]).toMatchObject({ intent: "add", add: [routes.cast.added] });
  });

  test("the page is reachable only by an admin", async ({ page }) => {
    await page.goto("/admin/authorities");
    await expect(page.locator("[data-studio-controller='signer-console']")).toHaveCount(0);
  });
});

test.describe("Squads proposals", () => {
  test("an open upgrade is approved in one Phantom prompt, and read back", async ({ page }) => {
    await installPhantomLab(page);
    const state = { member: null, approved: false, wire: null, approvals: 0 };
    const row = () => ({
      index: 9, status: "active", stale: false, kind: "vault",
      summary: { kind: "upgrade", buffer: "Buffer1111111111111111111111111111111111111", program: "Program11111111111111111111111111111111111",
                 spill: "VAULT", authority: "VAULT" },
      verification: { ok: true, build_version: "v0.27.0", buffer_hash: "ab".repeat(32) },
      approved: state.approved ? ["SysSeat", "GovSeat", state.member] : ["SysSeat", "GovSeat"],
      threshold: 3, approvals_needed: state.approved ? 0 : 1,
      squads_url: "https://app.squads.so/squads/VAULT/transactions",
      connected: state.member, connected_is_voter: !!state.member,
      connected_approved: state.approved, can_approve: !!state.member && !state.approved,
      approve_blocked: state.member ? null : "Connect Phantom to vote."
    });
    await page.route("**/admin/authorities/console*", (route) =>
      route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ ok: false, message: "unread" }) }));
    await page.route("**/admin/authorities/proposals?*", (route) =>
      route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, squads_url: "https://app.squads.so/squads/VAULT/transactions", proposals: [row()] }) }));
    await page.route("**/admin/authorities/proposals", (route) =>
      route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, squads_url: "https://app.squads.so/squads/VAULT/transactions", proposals: [row()] }) }));
    await page.route("**/admin/authorities/proposals/9/approve", (route) => {
      state.approvals++;
      state.approved = true;
      return route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, serialized_tx: state.wire, index: 9 }) });
    });

    await loginAdmin(page);
    await page.goto("/admin/authorities");
    await lazyController(page, "squads-proposals");
    const built = await page.evaluate(() => {
      const W = window.solanaWeb3;
      const member = W.Keypair.generate();
      window.__consoleLab.keys = [member];
      const tx = new W.Transaction();
      tx.recentBlockhash = W.Keypair.generate().publicKey.toBase58();
      tx.feePayer = member.publicKey;
      tx.add(new W.TransactionInstruction({ keys: [{ pubkey: member.publicKey, isSigner: true, isWritable: true }],
                                             programId: W.SystemProgram.programId, data: new Uint8Array([0]) }));
      const bytes = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
      return { member: member.publicKey.toBase58(), wire: btoa(String.fromCharCode.apply(null, new Uint8Array(bytes))) };
    });
    state.member = built.member;
    state.wire = built.wire;
    await page.evaluate(() => window.dispatchEvent(new CustomEvent("signer-console:connected")));

    const card = page.locator("[data-proposal='9']");
    await expect(card.getByText("Buffer verified: matches build v0.27.0.")).toBeVisible();
    await expect(card.getByText(/2 of 3 approvals/)).toBeVisible();
    await card.getByRole("button", { name: "Approve in Phantom (1 prompt)" }).dblclick();

    await expect(page.getByText(/Your approval on #9 is on chain: 3 of 3/)).toBeVisible();
    const sent = await page.evaluate(() => window.__consoleLab.sent);
    expect(sent).toEqual([{ signer: built.member, verifies: true }]); // a double click raised ONE prompt
    expect(state.approvals).toBe(1);
  });

  test("an unverified upgrade offers no Approve, and says why", async ({ page }) => {
    await page.route("**/admin/authorities/proposals*", (route) =>
      route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, proposals: [{
        index: 4, status: "active", stale: false, kind: "vault",
        summary: { kind: "upgrade", buffer: "B", program: "P", spill: "V", authority: "V" },
        verification: { ok: false, reason: "The buffer's hash matches no verified build." },
        approved: [], threshold: 3, approvals_needed: 3, squads_url: "https://app.squads.so/squads/V/transactions",
        connected: null, can_approve: false, approve_blocked: "The buffer's hash matches no verified build."
      }] }) }));
    await loginAdmin(page);
    await page.goto("/admin/authorities");
    await lazyController(page, "squads-proposals");
    const card = page.locator("[data-proposal='4']");
    await expect(card.getByText(/NOT VERIFIED/)).toBeVisible();
    await expect(card.getByRole("button", { name: /Approve/ })).toBeHidden();
  });
});

// ── THE PLATFORM COSIGNER, ON REQUEST ONLY (platform-cosigns-mainnet-settles) ──
//
// The checkbox renders only when the app holds SOLANA_PLATFORM_COSIGNER_KEY,
// which this lane does not, so the spec places it exactly as the partial does
// (inside the controller, as its `platformCosign` target, re-planning on
// change). What is under test is the controller: a plan asks for the platform
// cosigner only while the box is ticked, and the frozen payload Sign sends
// carries the same answer.
test.describe("Signer console platform opt-in", () => {
  test("plans carry platform_cosign only while the box is ticked", async ({ page }) => {
    const routes = await openConsole(page);
    await page.locator("[data-studio-controller='signer-console']").evaluate((root) => {
      const box = document.createElement("input");
      box.type = "checkbox";
      box.setAttribute("data-signer-console-target", "platformCosign");
      box.setAttribute("data-studio-action", "change->signer-console#requestPlan");
      box.id = "platform-cosign-fixture";
      root.prepend(box);
    });

    await draftAdd(page, routes);
    await expect.poll(() => routes.plans.length, { timeout: 5_000 }).toBeGreaterThan(0);
    expect(routes.plans[routes.plans.length - 1].platform_cosign).toBe(false);

    const before = routes.plans.length;
    await page.locator("#platform-cosign-fixture").check();
    await expect.poll(() => routes.plans.length, { timeout: 5_000 }).toBeGreaterThan(before);
    expect(routes.plans[routes.plans.length - 1].platform_cosign).toBe(true);

    const cta = page.locator("[data-signer-console-target='cta']");
    await expect(cta).toBeEnabled();
    await cta.click();
    await expect.poll(() => routes.rotations, { timeout: 5_000 }).toBe(1);
    expect(routes.rotationBodies[0].platform_cosign).toBe(true);
  });
});
