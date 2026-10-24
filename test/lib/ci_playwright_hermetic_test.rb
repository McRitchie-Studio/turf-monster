require "test_helper"
require "yaml"

# Pins the root cause of the model_page e2e flake (task fix-model-page-flake).
#
# The CI playwright job's test server must NEVER reach a live Solana RPC.
# Without an explicit SOLANA_RPC_URL, Solana::Client falls back to public
# devnet (https://api.devnet.solana.com), and every authenticated HTML request
# blocks on it: perform_solana_preload runs as a before_action for
# wallet-connected users, and the test env's :null_store cache disables the
# 60-second caches, so every request re-fires live RPCs. When public devnet
# throttles (peak hours: 429s + stalls against a 10s open / 30s read timeout),
# page renders degrade from milliseconds to 3-6s+ and the tightest post-click
# assertion window dies first — model_page.spec.js's toHaveURL(5s) failed with
# the URL stuck on /admin/dashboard while GET /models/contest/random starved
# (Actions run 29254091915, trace network log: status -1, never answered).
#
# The fix pins the playwright job to a black-hole loopback URL on a closed
# port: connect fails instantly (Errno::ECONNREFUSED is not in the RPC
# client's retry set), and the app takes its designed nil-safe fallbacks.
#
# COVERAGE, STATED HONESTLY: server-side on-chain paths are NOT exercised by
# any e2e that runs in CI. CI excludes the @devnet specs (--grep-invert), and no
# workflow runs them: Devnet Nightly never ran on schedule and was deleted
# (turf-devnet-config-truth); the devnet signal is the per-release
# contest-rehearsal gauntlet, outside CI. This pin is NOT justified by e2e
# coverage living elsewhere in CI — it lives nowhere there.
#
# WHAT LICENSES THE PIN: no e2e asserts the observables these RPCs feed. That is
# a MEASUREMENT, not an argument — the full chromium suite is 79/79 green under
# the black hole. It is NOT that "nothing changes"; it is that nothing we assert
# changes. Do not weaken this into a no-op claim.
#
# The e2e user is an ADMIN (e2e/global-setup.js swaps the canonical admin's
# wallet to MOCK_PUBKEY_B58), so an admin render fires TWO server-side on-chain
# RPCs, both re-firing every request under :null_store:
#
#   1. list_entry_tokens (application_controller.rb:617) →
#      getProgramAccounts(dataSize:124, memcmp@8=wallet) (vault.rb:1771-1786).
#      Against devnet for the e2e wallet it returns [] — NOT vacuously: the
#      program holds 72 entry-token accounts today, none owned by that wallet.
#      0 live, rescues to 0 here. CONTINGENT: mint one to that wallet and this
#      stops being true.
#   2. vault_state (application_controller.rb:626-639) → read_vault_state →
#      get_account_info on the vault PDA (seeds [b"vault"] = J7b5g9uS…HkK2).
#      That PDA EXISTS on devnet (1515 bytes, program-owned): live returns a
#      real struct, whereas under this pin it rescues to Current.vault_state =
#      nil + vault_state_error = true (:643-652). This observable REALLY DOES
#      CHANGE — no running spec asserts it, which is exactly why the pin holds.
#
# Do NOT restate this as "the e2e wallet has no devnet state" — it does: 6ASf…
# pGWt holds ~86 SOL on devnet in a real program-owned account. These reads stay
# harmless only because the preload no longer fires get_balance / the USDC+seeds
# reads (application_controller.rb:605-614). Browser RPC: e2e/rpc-mock.js.
class CiPlaywrightHermeticTest < ActiveSupport::TestCase
  WORKFLOW_PATH = Rails.root.join(".github/workflows/ci.yml")

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  # The discard port: reserved by RFC 863 and closed everywhere, so connect is
  # REFUSED instantly. Asserted exactly rather than denylisting known-listening
  # ports — a denylist misses whatever happens to listen next (postgres 5432 and
  # redis 6379 both listen in this job) and rots the moment the e2e server moves
  # off 3100. Any port that ANSWERS is disqualifying: the RPC client would POST
  # JSON-RPC, get something back, and pay a real round trip before failing.
  BLACK_HOLE_PORT = 9

  def playwright_job
    workflow = YAML.safe_load_file(WORKFLOW_PATH)
    workflow.fetch("jobs").fetch("playwright")
  end

  test "playwright job pins SOLANA_RPC_URL so the e2e server never reaches a live RPC" do
    rpc_url = playwright_job.fetch("env", {})["SOLANA_RPC_URL"]

    assert rpc_url.present?,
           "playwright job must set SOLANA_RPC_URL: without it the e2e test " \
           "server defaults to public devnet and every authenticated page " \
           "render blocks on live RPC — the model_page toHaveURL flake " \
           "(Actions run 29254091915). Point it at a black-hole loopback " \
           "port (e.g. http://127.0.0.1:9)."

    uri = URI.parse(rpc_url)

    assert_includes LOOPBACK_HOSTS, uri.host,
                    "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) must " \
                    "stay on loopback — a non-local RPC reintroduces the " \
                    "time-of-day e2e flake"

    # Loopback alone is not enough: the URL must point at a CLOSED port, so the
    # connection is refused instantly instead of being answered by something.
    assert_equal BLACK_HOLE_PORT, uri.port,
                 "playwright job SOLANA_RPC_URL (#{rpc_url.inspect}) must use the " \
                 "discard port #{BLACK_HOLE_PORT} — the only port guaranteed closed. " \
                 "Any port that ANSWERS (the e2e server on 3100, postgres 5432, " \
                 "redis 6379) is not a black hole: the RPC client would POST " \
                 "JSON-RPC, pay a real round trip, and fail slowly instead of " \
                 "being refused instantly."
  end
end
