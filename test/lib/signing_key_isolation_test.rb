# frozen_string_literal: true

require "test_helper"

# The regression: on 2026-09-08 `SOLANA_ADMIN_KEY` was measured byte-identical
# on `turf-monster-mainnet` and `turf-monster-qa` (len 88, matching SHA-256), so
# the QA app signed as production with the Alex Bot key.
#
# These tests drive the verdict engine directly. They are the ONLY place the
# comparison logic is exercised — CI holds no Heroku session and neither
# secret, so the live comparison happens exclusively in `bin/deploy`'s
# pre-flight on the operator's machine. What CI proves is that the engine
# reaches the right verdict for every shape of input it can be handed,
# including the ones where the honest answer is "I cannot tell".
class SigningKeyIsolationTest < ActiveSupport::TestCase
  Guard = TurfMonster::SigningKeyIsolation
  Reading = TurfMonster::SigningKeyIsolation::Reading

  # Obviously fake. A real credential never appears in a test or its output.
  SENTINEL_PROD = "SENTINEL-NOT-A-REAL-KEY-PRODUCTION-0000"
  SENTINEL_QA   = "SENTINEL-NOT-A-REAL-KEY-QA-1111"

  # Another app's secret, riding in the same config payload. Nothing this code
  # prints may ever contain it.
  SENTINEL_BYSTANDER = "SENTINEL-NOT-A-REAL-KEY-RAILS-MASTER-2222"

  def present(app, raw)  = Reading.for(app: app, present: true, raw: raw)
  def missing(app)       = Reading.for(app: app, present: false)
  def empty(app)         = Reading.for(app: app, present: true, raw: "")
  def unreadable(app)    = Reading.unreadable(app: app, reason: "not logged in")

  def guard(prod, qa) = Guard.new(production: prod, qa: qa)

  # ── The bug itself ────────────────────────────────────────────────────────

  test "identical values on the two apps is SHARED and does not pass" do
    g = guard(present("turf-monster-mainnet", SENTINEL_PROD),
              present("turf-monster-qa", SENTINEL_PROD))

    assert_equal :shared, g.verdict
    assert g.shared?
    refute g.ok?, "a shared signing key must never pass the guard"
    assert_match(/SHARED SIGNING KEY/, g.report)
  end

  test "different values on the two apps is ISOLATED and passes" do
    g = guard(present("turf-monster-mainnet", SENTINEL_PROD),
              present("turf-monster-qa", SENTINEL_QA))

    assert_equal :isolated, g.verdict
    assert g.ok?
    assert_match(/OK — turf-monster-qa signs with its own key/, g.report)
  end

  test "the same key wearing different whitespace is still SHARED" do
    # Heroku stores what you set. A value re-pasted with a stray newline or
    # leading space is the SAME signing key and must not read as isolation.
    g = guard(present("turf-monster-mainnet", SENTINEL_PROD),
              present("turf-monster-qa", "  #{SENTINEL_PROD}\n"))

    assert_equal :shared, g.verdict
    refute g.ok?
  end

  # ── The vacuous cases: absence is not isolation ───────────────────────────

  test "a missing production value is INDETERMINATE, not isolated" do
    g = guard(missing("turf-monster-mainnet"), present("turf-monster-qa", SENTINEL_QA))

    assert_equal :indeterminate, g.verdict
    refute g.ok?
  end

  test "a missing QA value is INDETERMINATE, not isolated" do
    g = guard(present("turf-monster-mainnet", SENTINEL_PROD), missing("turf-monster-qa"))

    assert_equal :indeterminate, g.verdict
    refute g.ok?
  end

  # The trap this guard exists to avoid answering confidently.
  test "BOTH values missing is INDETERMINATE — neither shared nor isolated" do
    g = guard(missing("turf-monster-mainnet"), missing("turf-monster-qa"))

    assert_equal :indeterminate, g.verdict
    refute g.ok?, "two absences compare EQUAL; that is not evidence of anything"
    refute g.shared?, "two absences are not a shared key either"
  end

  test "an empty-but-present value is INDETERMINATE on either side" do
    assert_equal :indeterminate,
                 guard(present("turf-monster-mainnet", SENTINEL_PROD), empty("turf-monster-qa")).verdict
    assert_equal :indeterminate,
                 guard(empty("turf-monster-mainnet"), present("turf-monster-qa", SENTINEL_QA)).verdict
    assert_equal :indeterminate,
                 guard(empty("turf-monster-mainnet"), empty("turf-monster-qa")).verdict
  end

  test "an unreadable side is INDETERMINATE, not isolated" do
    g = guard(present("turf-monster-mainnet", SENTINEL_PROD), unreadable("turf-monster-qa"))

    assert_equal :indeterminate, g.verdict
    refute g.ok?
  end

  test "BOTH sides unreadable is INDETERMINATE — two unknowns are not distinct" do
    g = guard(unreadable("turf-monster-mainnet"), unreadable("turf-monster-qa"))

    assert_equal :indeterminate, g.verdict
    refute g.ok?, "comparing two failed reads would say 'different' and be wrong"
  end

  test "the indeterminate report names which side it could not prove" do
    report = guard(present("turf-monster-mainnet", SENTINEL_PROD), missing("turf-monster-qa")).report

    assert_match(/INDETERMINATE/, report)
    assert_match(/turf-monster-qa: key ABSENT/, report)
    refute_match(/turf-monster-mainnet: /, report,
                 "the side that read cleanly should not be listed as a reason")
  end

  # ── The secret never escapes ──────────────────────────────────────────────

  test "no report ever contains the value it compared" do
    reports = [
      guard(present("a", SENTINEL_PROD), present("b", SENTINEL_PROD)).report,
      guard(present("a", SENTINEL_PROD), present("b", SENTINEL_QA)).report,
      guard(present("a", SENTINEL_PROD), missing("b")).report
    ]

    reports.each do |report|
      refute_includes report, SENTINEL_PROD, "the guard published the key it was comparing"
      refute_includes report, SENTINEL_QA, "the guard published the key it was comparing"
      # A floor, so an empty report cannot satisfy the two refutes above.
      assert_match(/Signing key isolation \(SOLANA_ADMIN_KEY\)/, report)
      assert_operator report.length, :>, 100, "report is too short to have said anything"
    end
  end

  test "a Reading keeps no plaintext behind any accessor" do
    reading = present("turf-monster-mainnet", SENTINEL_PROD)

    reading.public_methods(false).each do |name|
      next unless reading.method(name).arity.zero?

      value = reading.public_send(name).to_s
      refute_includes value, SENTINEL_PROD, "Reading##{name} leaked the key"
    end

    refute_includes reading.inspect, SENTINEL_PROD
    refute_includes reading.to_s, SENTINEL_PROD
    refute_includes reading.describe, SENTINEL_PROD
    # Floor: the accessors we just swept must actually be there.
    assert_operator reading.public_methods(false).length, :>=, 6
  end

  test "a Reading retains no instance variable holding the plaintext" do
    # Stronger than the accessor sweep above: the value must not be RETAINED at
    # all. A stashed `@raw` leaks through nothing today, but it is one removed
    # `inspect` override, one exception dump, or one debugger session away from
    # publishing the Alex Bot key. The constructor digests and discards.
    reading = present("turf-monster-mainnet", SENTINEL_PROD)

    reading.instance_variables.each do |ivar|
      value = reading.instance_variable_get(ivar).to_s
      refute_includes value, SENTINEL_PROD, "Reading kept the plaintext in #{ivar}"
    end

    # Floor: the sweep above must have had something to sweep.
    assert_operator reading.instance_variables.length, :>=, 4
    assert_includes reading.instance_variables, :@digest
  end

  test "a present Reading reports a hex digest prefix and the length, nothing else" do
    reading = present("turf-monster-mainnet", SENTINEL_PROD)

    assert_equal 12, reading.digest_prefix.length
    assert_match(/\A[0-9a-f]{12}\z/, reading.digest_prefix)
    assert_equal SENTINEL_PROD.length, reading.length
    assert_equal "len=#{SENTINEL_PROD.length} sha256[0,12]=#{reading.digest_prefix}", reading.describe
  end

  test "equal values digest equal and unequal values digest unequal" do
    assert_equal present("a", SENTINEL_PROD).digest, present("b", SENTINEL_PROD).digest
    refute_equal present("a", SENTINEL_PROD).digest, present("b", SENTINEL_QA).digest
  end

  # ── HerokuReader: presence vs emptiness vs failure ────────────────────────
  #
  # `heroku config --json` is used rather than `heroku config:get` precisely so
  # these three states stay distinguishable — see docs/SOLANA.md, "Check it by
  # KEY PRESENCE".

  def reader_returning(payload, ok: true)
    TurfMonster::SigningKeyIsolation::HerokuReader.new(runner: ->(_app) { [payload, ok] })
  end

  def read(payload, ok: true)
    reader_returning(payload, ok: ok).read(app: "turf-monster-qa", variable: "SOLANA_ADMIN_KEY")
  end

  test "a config payload carrying the key reads as present" do
    reading = read({ "SOLANA_ADMIN_KEY" => SENTINEL_QA, "RAILS_MASTER_KEY" => SENTINEL_BYSTANDER }.to_json)

    assert_equal :present, reading.state
    assert_equal SENTINEL_QA.length, reading.length
  end

  test "a config payload without the key reads as MISSING, not empty" do
    reading = read({ "RAILS_MASTER_KEY" => SENTINEL_BYSTANDER }.to_json)

    assert_equal :missing, reading.state
    assert_nil reading.digest
  end

  test "a present-but-empty key reads as EMPTY, not missing" do
    reading = read({ "SOLANA_ADMIN_KEY" => "" }.to_json)

    assert_equal :empty, reading.state
  end

  test "a failed heroku command reads as UNREADABLE, never as absent" do
    reading = read("", ok: false)

    assert_equal :unreadable, reading.state
    refute reading.readable?, "a failed read must not be mistaken for a clean look"
  end

  test "a non-JSON response reads as UNREADABLE without echoing the body" do
    # An HTML error page, a truncated payload, or a partial config dump. The
    # body may still hold every other secret the app has.
    body = %(<html>oops #{SENTINEL_BYSTANDER}</html>)
    reading = read(body)

    assert_equal :unreadable, reading.state
    refute_includes reading.reason, SENTINEL_BYSTANDER, "the reader echoed the config body"
    refute_includes reading.describe, SENTINEL_BYSTANDER
    assert_match(/not JSON/, reading.reason)
  end

  test "a JSON payload that is not an object reads as UNREADABLE" do
    reading = read("[1,2,3]")

    assert_equal :unreadable, reading.state
  end

  test "the reader returns only the requested key, never the surrounding config" do
    reading = read({ "SOLANA_ADMIN_KEY" => SENTINEL_QA, "RAILS_MASTER_KEY" => SENTINEL_BYSTANDER }.to_json)

    serialized = [reading.inspect, reading.to_s, reading.describe].join(" ")
    refute_includes serialized, SENTINEL_BYSTANDER
    refute_includes serialized, SENTINEL_QA
    assert_match(/len=#{SENTINEL_QA.length}/, reading.describe)
  end

  test "probe reads both apps and builds the comparison" do
    payloads = {
      "turf-monster-mainnet" => { "SOLANA_ADMIN_KEY" => SENTINEL_PROD }.to_json,
      "turf-monster-qa" => { "SOLANA_ADMIN_KEY" => SENTINEL_PROD }.to_json
    }
    reader = TurfMonster::SigningKeyIsolation::HerokuReader.new(
      runner: ->(app) { [payloads.fetch(app), true] }
    )

    g = Guard.probe(reader: reader)

    assert_equal :shared, g.verdict
    assert_equal "turf-monster-mainnet", g.production.app
    assert_equal "turf-monster-qa", g.qa.app
  end
end
