require "test_helper"

# POST /auth/solana/report_failure — the only path by which a wallet failure that
# happened ENTIRELY in the browser reaches error_logs.
#
# ⚠️ READ THIS BEFORE ADDING A TEST HERE. This endpoint answers 204 whether it
# recorded a row or not — that is its fail-open contract, and it is also the
# shape in which an inert test breeds. `assert_response :no_content` passes with
# the action's body deleted. So EVERY test below that means "it recorded"
# asserts on the ROW, and the two that assert the status are explicitly the
# fail-open ones, where 204-with-no-row is the correct outcome.
#
# Verified by mutation, 2026-09-07: replacing #record_client_wallet_failure with
# `nil` reddens five tests here; a status-only suite stays green.
class SolanaClientFailureReportTest < ActionDispatch::IntegrationTest
  PATH = "/auth/solana/report_failure".freeze
  NONCE = "a1b2c3d4e5f60718293a4b5c6d7e8f90".freeze
  PUBKEY = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze
  # Non-hex base58 on purpose — see the note on the same constant in
  # test/services/solana/client_failure_report_test.rb. An all-hex stand-in is
  # caught by HEX_SECRET_RE and proves nothing about the signature rule.
  SIGNATURE = "LDTEtogGVHwvu8FBPzatztKdh1GQtnwvo483Tg1C7SR82eHsS6c7ENpBFM3bPJ7KVrqSCpFES1bJaPia8QP6w61V".freeze

  def report(**overrides)
    post PATH, params: {
      provider: "Phantom",
      stage: "wallet_setup_connect",
      raw_message: "User rejected the request.",
      mapped_message: "Signature rejected"
    }.merge(overrides), as: :json
  end

  # ── It records ──────────────────────────────────────────────────────────────

  test "a reported client failure creates an ErrorLog row" do
    assert_difference "ErrorLog.count", 1 do
      report
    end

    log = ErrorLog.last
    assert_includes log.inspect_field, "Solana::ClientWalletFailure",
                    "the row must be findable by the class that names this failure surface"
    assert_includes log.message, "stage=wallet_setup_connect"
    assert_includes log.message, "provider=phantom"
  end

  test "the row carries BOTH the raw wallet string and the mapped one" do
    # The pair is the entire reason this endpoint exists. A row holding only what
    # the user was shown cannot tell an operator that the mapping was WRONG,
    # which is the failure that cost seven sessions on 2026-09-06.
    report(raw_message: "Unexpected error", mapped_message: "Check your USDC balance.")

    log = ErrorLog.last
    assert_includes log.message, "raw=Unexpected error"
    assert_includes log.message, "shown=Check your USDC balance."
  end

  test "a guest report is recorded with no target" do
    # The failure this endpoint exists to see happens BEFORE sign-in, so the
    # unauthenticated path is the PRIMARY one, not an edge case.
    assert_difference "ErrorLog.count", 1 do
      report
    end

    assert_nil ErrorLog.last.target, "a guest has no user to file the row against"
  end

  test "a signed-in report targets the USER" do
    # Stated as a test because the answer is routinely assumed wrong here: this
    # app's other on-chain rows target the ENTRY, so an operator searching
    # error_logs by user finds nothing and reads it as "nothing was logged".
    # These rows are the deliberate exception — the subject is a person's wallet.
    user = users(:alex)
    log_in_as(user)

    report(stage: "web3_step_up")

    log = ErrorLog.last
    assert_equal user, log.target
    assert_equal user.slug, log.target_name
  end

  # ── PII, layer 1: the four-key allowlist ────────────────────────────────────

  test "a signature posted under its own key never reaches the row" do
    # Layer 1, from the client's side: a credential posted under its own key is
    # not stored. Note what this does NOT pin — widening client_failure_params
    # alone leaves this green, because `from_params` reads four keys by name and
    # ignores the rest. The permit list and that reader are pinned together in
    # test/controllers/wallet_failure_reporter_wiring_test.rb.
    report(signature: SIGNATURE, message: "sign this", nonce: NONCE)

    log = ErrorLog.last
    refute_includes log.message, SIGNATURE
    refute_includes log.message, NONCE
    refute_includes log.message, "sign this"
  end

  # ── PII, layer 2: the by-value scrub, proven end to end ─────────────────────

  test "a nonce quoted inside the raw wallet message never reaches the row" do
    # The gap layer 1 cannot see: `raw_message` is a PERMITTED key holding free
    # text a WALLET composed, and this app hands the wallet a string containing
    # its own nonce to sign. Unit coverage of the scrub lives in
    # test/services/solana/client_failure_report_test.rb; this asserts the
    # controller actually routes through it.
    report(raw_message: "Failed to sign: Nonce: #{NONCE}")

    refute_includes ErrorLog.last.message, NONCE,
                    "the live nonce reached an error_logs row through a permitted field"
  end

  test "the wallet pubkey survives into the row" do
    # The other half of the rule. A redactor that also ate the pubkey would leave
    # a row that cannot identify the wallet it is about — and for a GUEST report
    # the pubkey is the only handle there is.
    report(raw_message: "wallet #{PUBKEY} refused")

    assert_includes ErrorLog.last.message, PUBKEY
  end

  # ── Fail open ───────────────────────────────────────────────────────────────

  test "a failing ErrorLog write still answers 204 and raises nothing" do
    # THE POINT OF THE ENDPOINT'S SHAPE. The reporting of a failure must never
    # become a failure: the user has already been told what went wrong, and this
    # request runs after that. Status IS the assertion here — a 500 would surface
    # as an unhandled rejection in the browser and, in dev/test, re-raise.
    ErrorLog.stub :capture!, ->(_e) { raise ActiveRecord::StatementInvalid, "error_logs is gone" } do
      assert_no_difference "ErrorLog.count" do
        report
      end
    end

    assert_response :no_content
  end

  test "a recorded report logs nothing claiming it was dropped" do
    # THE HOLE A MUTANT FOUND, 2026-09-07. #record_client_wallet_failure enters
    # the shared logging path by RAISING one line deep, and `rescue_and_log`
    # re-raises by contract — so the success path ends in a raise that something
    # must absorb. Deleting its `rescue Solana::ClientWalletFailure` left every
    # test here green: the outer `rescue StandardError` in #report_failure caught
    # the re-raise, the row was already written, and the status was still 204.
    #
    # What changed, and what nothing was watching, is the LOG. Every SUCCESSFUL
    # report began emitting "[solana][client-failure] report dropped:" — an
    # operator-facing line that is not merely noisy but false, about the one
    # surface this whole task exists to make legible. A row that records and a
    # log that says it did not is worse than either alone.
    logged = []
    Rails.logger.stub(:error, ->(message = nil, &_blk) { logged << message.to_s }) do
      assert_difference "ErrorLog.count", 1 do
        report
      end
    end

    refute logged.any? { |line| line.include?("report dropped") },
           "a report that WAS recorded logged that it was dropped: #{logged.inspect}"
  end

  test "a report with no body at all is absorbed" do
    post PATH, params: {}, as: :json

    assert_response :no_content
  end

  test "an unknown stage and brand are recorded rather than refused" do
    # A report we cannot LABEL is still a report — refusing it would put the
    # surface back in the dark for exactly the call site nobody registered.
    assert_difference "ErrorLog.count", 1 do
      report(provider: "MetaMask", stage: "some_future_modal")
    end

    assert_includes ErrorLog.last.message, "stage=unknown"
    assert_includes ErrorLog.last.message, "provider=unknown"
  end

  test "invalid UTF-8 never reaches the action — Rack refuses it upstream" do
    # MEASURED, 2026-09-07, and recorded because it moves a guard from "live" to
    # "defence in depth". `gsub` on a string with invalid UTF-8 raises
    # ArgumentError and the scrubber is all gsub, so the obvious worry is a
    # hostile byte pair reaching it. It cannot, by either encoding: Ruby's JSON
    # generator REFUSES to emit `\xC3\x28`, and a form post carrying it is
    # answered 400 by Rack before the controller runs.
    #
    # The scrubber still calls `.scrub` (inherited from Solana::Config
    # .redact_message, which needs it for its own callers) — but nothing in THIS
    # path depends on it today, and a unit test asserting it must not be read as
    # evidence that the endpoint is exposed. If this assertion ever flips to 204,
    # the byte path opened and Solana::ClientFailureReport.scrub became live.
    post PATH,
         params: "provider=Phantom&stage=wallet_setup_connect&raw_message=boom+%C3%28",
         headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

    assert_response :bad_request
    assert_equal 0, ErrorLog.count, "nothing should be recorded for a request that never ran"
  end
end
