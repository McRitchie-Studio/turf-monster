const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  // CI retries: this single-worker e2e suite has documented full-suite
  // flakiness (cross-spec DB/session state pollution + timing under load).
  // The dominant "timing under load" source — the test server blocking on
  // live public-devnet RPC per authenticated page render — is fixed at the
  // root: CI pins SOLANA_RPC_URL to a black-hole loopback (see the playwright
  // job in .github/workflows/ci.yml and test/lib/ci_playwright_hermetic_test.rb).
  // Retry only in CI so a transient flake doesn't fail the whole job; a
  // genuinely broken test still fails all attempts. Local runs stay at 0 to
  // surface flakes during development.
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  // Swap alex's wallet to MOCK_PUBKEY_B58 before tests (so loginViaPhantom
  // resolves to the admin user) and restore it after. Lets the dev seed
  // default to the operator's REAL Phantom wallet without breaking e2e.
  globalSetup: require.resolve("./e2e/global-setup.js"),
  globalTeardown: require.resolve("./e2e/global-teardown.js"),
  use: {
    // bin/e2e-parallel sets PW_BASE_URL per shard to point each playwright
    // process at its own isolated stack's port. Defaults to the canonical :3100.
    baseURL: process.env.PW_BASE_URL || "http://127.0.0.1:3100",
    headless: true,
    // Smooth-load (engine 0.24) enables same-origin view transitions; under
    // prefers-reduced-motion Turbo never starts the view transition at all,
    // so e2e gets instant swaps.
    reducedMotion: "reduce",
    // Capture a Playwright trace + screenshot when a test retries/fails so
    // CI-only failures (which don't reproduce locally — e.g. geo.spec.js:54)
    // are diagnosable from the uploaded test-results/ artifact. on-first-retry
    // keeps green runs cheap (trace only recorded once a test has failed once).
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
      grepInvert: /@devnet/,
    },
    {
      name: "devnet",
      use: { browserName: "chromium" },
      grep: /@devnet/,
      timeout: 180_000,
    },
  ],
  // When PW_BASE_URL is set, the caller (bin/e2e-parallel) has already brought
  // up an isolated server on its own port + DB, so Playwright must NOT manage
  // one. Otherwise: a single test-env server on :3100 (reused if a dev server
  // is already up locally; freshly started in CI).
  webServer: process.env.PW_BASE_URL
    ? undefined
    : {
        command:
          "bin/rails db:test:prepare && bin/rails runner e2e/seed.rb && bin/rails server -p 3100 -e test",
        url: "http://127.0.0.1:3100/up",
        reuseExistingServer: !process.env.CI,
        // Boot budget covers db:test:prepare + the e2e seed (incl. the full
        // NFL 2026 totals cache) + server boot on a slow CI runner. 30s was
        // marginal once the NFL cache joined the seed and red-flaked shard 1
        // twice; the floor is guarded by test/lib/playwright_config_contract_test.rb.
        timeout: 120_000,
        env: { RAILS_ENV: "test", PLAYWRIGHT_SEED: "true" },
      },
});
