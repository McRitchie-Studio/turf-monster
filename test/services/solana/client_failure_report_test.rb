require "test_helper"

# Solana::ClientFailureReport — the sanitiser standing between a WALLET-composed
# string and an error_logs row.
#
# The tests below are split by which layer of the PII rule they exercise. Layer 1
# (the four-key allowlist) lives in the controller and is tested in
# test/controllers/solana_client_failure_report_test.rb; everything here is layer
# 2 — the by-VALUE rules, which exist because `raw_message` is free text the app
# does not compose and the key allowlist can say nothing about what is inside it.
class Solana::ClientFailureReportTest < ActiveSupport::TestCase
  # THE EXACT STRING THIS APP HANDS A WALLET TO SIGN — the non-signIn fallback in
  # app/views/layouts/application.html.erb, byte for byte in shape. It is
  # reproduced here rather than paraphrased because the whole point of the nonce
  # rule is that a wallet can quote THIS back at us in an error, and a test built
  # on a paraphrase would certify a redactor against a string the app never emits
  # (the mistake app/javascript/debug_logger.js's own comment records making).
  NONCE = "a1b2c3d4e5f60718293a4b5c6d7e8f90".freeze # SecureRandom.hex(16) shape
  PUBKEY = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze # 44 chars, 32 bytes
  SIWS_MESSAGE = <<~MSG.freeze
    turfmonster.media wants you to sign in with your Solana account:
    #{PUBKEY}

    Sign in to Turf Monster

    Nonce: #{NONCE}
  MSG

  # An ed25519 signature is 64 bytes -> 87-88 base58 characters.
  #
  # IT MUST CONTAIN NON-HEX BASE58 CHARACTERS, and that is the whole reason this
  # is a literal rather than `"5" * 88`. Measured 2026-09-07: with the all-"5"
  # form, deleting SIGNATURE_RE entirely left this file GREEN — every character
  # of `"5" * 88` is also a hex digit, so HEX_SECRET_RE caught the string and the
  # signature test was passing on its sibling's rule. A fixture that two rules
  # both match cannot tell you which one is load-bearing. Verified against both:
  # this value matches SIGNATURE_RE and does NOT match HEX_SECRET_RE.
  SIGNATURE = "LDTEtogGVHwvu8FBPzatztKdh1GQtnwvo483Tg1C7SR82eHsS6c7ENpBFM3bPJ7KVrqSCpFES1bJaPia8QP6w61V".freeze

  def build(raw: "boom", mapped: "Something went wrong", provider: "Phantom", stage: "wallet_setup_connect")
    Solana::ClientFailureReport.new(
      provider: provider, stage: stage, raw_message: raw, mapped_message: mapped
    )
  end

  # ── Layer 2: credentials never reach the row ────────────────────────────────

  test "a wallet error quoting the SIWS message loses the nonce" do
    report = build(raw: "Failed to sign message: #{SIWS_MESSAGE}")

    refute_includes report.raw_message, NONCE,
                    "the live nonce reached an error_logs row inside a wallet's own error string"
    refute_includes report.summary, NONCE, "the nonce survived into ErrorLog#message"
  end

  test "the nonce is redacted in the labelled form the SIWS message writes" do
    report = build(raw: "rejected, Nonce: #{NONCE}")

    assert_includes report.raw_message, "nonce: [redacted]"
  end

  test "an ed25519 signature is redacted" do
    report = build(raw: "signature #{SIGNATURE} was rejected")

    refute_includes report.raw_message, SIGNATURE, "a live SIWS signature reached the row"
    assert_includes report.raw_message, "[redacted]"
  end

  test "a bare 32-char hex nonce is redacted without its label" do
    # The unlabelled half of the nonce rule. base58 cannot cover it: hex uses
    # `0`, which the base58 alphabet does not contain, so a hex nonce slips past
    # a base58-only redactor entirely.
    report = build(raw: "challenge #{NONCE} expired")

    refute_includes report.raw_message, NONCE
  end

  test "an RPC endpoint's api-key is redacted out of a quoted error" do
    # Delegated to Solana::Config.redact_message, so an endpoint a wallet or an
    # RPC layer quoted back at us cannot land the credentialed URL in error_logs
    # — the same exposure Solana::ClientLogger redacts for on the outbound side.
    # Sentinel key rather than the configured one: this rule fires on the SHAPE
    # of a URL, so it must be provable without depending on how a lane is wired.
    sentinel = "SENTINEL-NOT-A-REAL-KEY-0000"
    report = build(raw: "RPC failed: https://rpc.example.test/?api-key=#{sentinel}")

    refute_includes report.raw_message, sentinel, "an RPC credential reached the row"
    assert_includes report.raw_message, "api-key=***", "the operator still needs WHICH param carried it"
  end

  # ── Layer 2: the public identifiers SURVIVE, deliberately ───────────────────

  test "the wallet pubkey survives redaction" do
    # OVER-REDACTION IS THE OTHER FAILURE MODE, and it is the one that quietly
    # makes the row worthless. A pubkey is public — it is already rendered on
    # <body data-wallet-address> — and it is the single field that lets an
    # operator find the user this row is about when there is no session to target.
    # It is 44 base58 characters; the signature rule starts at 64 SO THAT this
    # passes. If someone lowers that bound, this test is what says no.
    report = build(raw: "wallet #{PUBKEY} refused")

    assert_includes report.raw_message, PUBKEY,
                    "the pubkey was redacted; the row can no longer identify a wallet"
  end

  test "the sentence a wallet actually said survives around the redactions" do
    report = build(raw: "User rejected the request.")

    assert_includes report.raw_message, "User rejected the request."
  end

  # ── Normalisation ───────────────────────────────────────────────────────────

  test "the provider is normalised through the wallet registry" do
    assert_equal "phantom", build(provider: "Phantom").provider
    assert_equal "phantom", build(provider: "  PHANTOM ").provider
  end

  test "an unregistered provider or stage is recorded as unknown, never dropped" do
    # A report we cannot LABEL is still a report. Refusing it would put the
    # surface back in the dark for exactly the call site nobody registered.
    report = build(provider: "MetaMask", stage: "some_new_modal")

    assert_equal "unknown", report.provider
    assert_equal "unknown", report.stage
    assert_includes report.summary, "stage=unknown"
  end

  test "a registered stage is preserved" do
    assert_equal "web3_step_up", build(stage: "web3_step_up").stage
  end

  test "the fallback's own stage survives, so its rows are filterable" do
    # `connect_verify_fallback` is not a render surface — it is the connect +
    # signMessage fallback INSIDE solanaConnectAndVerify, which reports before it
    # replaces an unusable wallet's message with our own setup sentence
    # (/tasks/raw-message-is-ours). Unregistered, every one of those reports lands
    # as `unknown` and the one class the endpoint exists for becomes the one class
    # an operator cannot filter for.
    report = build(stage: "connect_verify_fallback")

    assert_equal "connect_verify_fallback", report.stage
    assert_includes report.summary, "stage=connect_verify_fallback"
  end

  test "the signature guard's stage survives, and is NOT the fallback's" do
    # THE SECOND SUBSTITUTING GUARD, registered separately on purpose. It fires
    # when connect() ANSWERED with a publicKey and signMessage then refused —
    # a wallet that demonstrably holds a keypair. `connect_verify_fallback` means
    # the opposite (no keypair at all), and the two want different responses from
    # an operator, so collapsing them would put the app's two most confusable
    # wallet failures behind one filter.
    #
    # Unregistered, this lands as `unknown`: narrow-wallet-setup-diagnosis added
    # the guard without a stage or a report, and the rows it produced carried our
    # sentence in both halves (/tasks/raw-message-is-ours).
    report = build(stage: "connect_verify_signature")

    assert_equal "connect_verify_signature", report.stage
    assert_includes report.summary, "stage=connect_verify_signature"
    refute_equal build(stage: "connect_verify_fallback").stage, report.stage
  end

  test "a differing raw and mapped half both reach the row, and are told apart" do
    # THE WHOLE POINT OF THE PAIR. Until 2026-09-07 the malfunction class arrived
    # with these two byte-identical — both of them OUR sentence — so a row proved
    # only that something failed. Each half is carried under its OWN label, which
    # is what lets a reader see which one is the wallet's; a summary that printed
    # one, or ran them together, would read the same on a useful row and a
    # useless one.
    report = build(
      raw: "Unexpected error",
      mapped: "Finish setting up your wallet in Phantom — create or import one, then try again."
    )

    refute_equal report.raw_message, report.mapped_message,
                 "the fixture must differ or this test asserts nothing"
    assert_includes report.summary, "raw=Unexpected error"
    assert_includes report.summary, "shown=Finish setting up your wallet in Phantom"
    assert_operator report.summary.index("shown="), :<, report.summary.index("raw="),
                    "the sentence the user READ leads; the wallet's own words follow it"
  end

  # ── Hostile input ───────────────────────────────────────────────────────────

  test "invalid UTF-8 does not raise" do
    # gsub on a string with invalid UTF-8 raises ArgumentError, and every rule in
    # the scrubber is a gsub — so `scrub` guards its own contract for any caller.
    #
    # DEFENCE IN DEPTH, NOT A LIVE GUARD, and labelled so nobody credits it with
    # more: these bytes cannot reach the endpoint. Measured 2026-09-07 — Ruby's
    # JSON generator refuses to emit them and Rack answers a form post carrying
    # them 400 before the controller runs (asserted in
    # test/controllers/solana_client_failure_report_test.rb, which is where that
    # boundary is pinned).
    assert_nothing_raised do
      build(raw: "boom \xC3\x28 rejected".dup.force_encoding("UTF-8"))
    end
  end

  test "an oversized message is truncated" do
    # THE INPUT HAS TO SURVIVE THE SCRUBS TO REACH THE TRUNCATION, which `"x" *
    # 5_000` does not: it is one unbroken run of base58, so SIGNATURE_RE ate the
    # whole string and left 10 characters. Measured 2026-09-07 — deleting
    # `truncate` outright kept this test green, because truncation was never
    # reached. Spaces are what keep the sentence intact through every rule above.
    raw = "wallet rejected the request " * 40

    report = build(raw: raw)

    assert_operator raw.length, :>, Solana::ClientFailureReport::MAX_MESSAGE,
                    "the fixture must exceed the cap or this test asserts nothing"
    assert_includes report.raw_message, "wallet rejected the request",
                    "the fixture was redacted away before truncation could be exercised"
    assert_operator report.raw_message.length, :<=, Solana::ClientFailureReport::MAX_MESSAGE
  end

  test "nil messages produce a readable summary rather than blanks" do
    report = build(raw: nil, mapped: nil)

    assert_includes report.summary, "raw=(none)"
    assert_includes report.summary, "shown=(none)"
  end

  # ── The summary is the operator's row ───────────────────────────────────────

  test "the summary carries BOTH message halves" do
    # The pair is the whole diagnostic value: the 2026-09-06 incident was a
    # correct mapper meeting a wallet string it had never seen, and it is
    # undiagnosable from the mapped half alone.
    report = build(raw: "Unexpected error", mapped: "Check your USDC balance.")

    assert_includes report.summary, "raw=Unexpected error"
    assert_includes report.summary, "shown=Check your USDC balance."
  end
end
