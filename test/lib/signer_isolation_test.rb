require "test_helper"
require "open3"
require "stringio"
require "tmpdir"

# Solana::SignerIsolation — "this app's key IS this environment's system wallet"
# (task separate-qa-solana-signing-key).
#
# Every key in this file is generated from a fixed, published seed. None is a
# real key. The assertions that matter most are the ones that search captured
# output for the secret: the guard reads a production credential on every
# deploy, and a report that echoed it would be a worse incident than the one
# the guard exists to catch.
class SignerIsolationTest < ActiveSupport::TestCase
  GUARD = Solana::SignerIsolation
  GUARD_RB = Rails.root.join("lib", "solana", "signer_isolation.rb").to_s

  def self.keypair(label)
    Solana::Keypair.from_bytes(Digest::SHA256.digest("signer-isolation-test #{label}"))
  end

  PROD = keypair("prod")
  QA = keypair("qa")
  STRANGER = keypair("stranger")

  # The secret the way SOLANA_ADMIN_KEY holds it: base58 of the 64-byte key.
  def self.secret(keypair) = Solana::Keypair.encode_base58(keypair.to_bytes)

  PROD_SECRET = secret(PROD)
  QA_SECRET = secret(QA)
  STRANGER_SECRET = secret(STRANGER)

  def registry(mode: "warn", qa_wallet: nil)
    GUARD::Registry.new(
      "mode" => mode,
      "environments" => {
        "production" => { "network" => "mainnet-beta", "deployed" => true,
                          "heroku_app" => "turf-monster-mainnet", "system_wallet" => PROD.to_base58 },
        "qa" => { "network" => "devnet", "deployed" => true,
                  "heroku_app" => "turf-monster-qa", "system_wallet" => qa_wallet },
        "development" => { "network" => "devnet", "deployed" => false, "system_wallet" => nil }
      }
    )
  end

  # ── DERIVATION IS THE GEM'S ─────────────────────────────────────────────

  test "the stdlib derivation answers exactly what solana-studio signs as" do
    [PROD, QA, STRANGER].each do |kp|
      assert_equal kp.to_base58, GUARD.derive_pubkey(self.class.secret(kp))
    end
  end

  # from_bytes signs with bytes[0, 32], so the 32-byte seed alone and the
  # 64-byte secret are ONE signer. A string comparison would call them two.
  test "two different strings that derive one signer are one signer" do
    seed_only = Solana::Keypair.encode_base58(PROD.to_bytes.byteslice(0, 32))
    refute_equal PROD_SECRET, seed_only
    assert_equal GUARD.derive_pubkey(PROD_SECRET), GUARD.derive_pubkey(seed_only)
  end

  test "the base58 codec round-trips a public key, leading zero bytes included" do
    bytes = "\x00\x00".b + Digest::SHA256.digest("zeros").byteslice(0, 30)
    encoded = GUARD.encode_base58(bytes)
    assert encoded.start_with?("11")
    assert_equal bytes, GUARD.decode_base58(encoded)
    assert_equal Solana::Keypair.encode_base58(bytes), encoded
  end

  # ── THE FINDING THIS TASK EXISTS FOR ────────────────────────────────────

  test "warn mode: QA holding production's key is reported and not refused" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, environment: "qa", registry: registry)

    refute verdict.ok?
    refute verdict.refuse?, "warn mode must never refuse — merging this may not block a deploy"
    assert_equal %i[foreign unfiled], verdict.findings.map(&:kind)
    assert_match(/qa holds production's system wallet #{PROD.to_base58}/, verdict.report)
    assert_match(/WARNING \[mode warn\]/, verdict.report)
    assert_match(/Warn mode: nothing was blocked/, verdict.report)
    refute_includes verdict.report, PROD_SECRET
  end

  test "enforce mode (the committed switch) refuses the same finding" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, environment: "qa",
                          registry: registry(mode: "enforce"))

    assert verdict.refuse?
    assert_match(/REFUSED \[mode enforce\]/, verdict.report)
  end

  test "enforce mode refuses a key that is another environment's even once QA is filed" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, environment: "qa",
                          registry: registry(mode: "enforce", qa_wallet: QA.to_base58))

    assert verdict.refuse?
    assert_equal %i[foreign mismatch], verdict.findings.map(&:kind)
  end

  test "a matching key passes silently, in either mode" do
    %w[warn enforce].each do |mode|
      verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => QA_SECRET }, environment: "qa",
                            registry: registry(mode: mode, qa_wallet: QA.to_base58))

      assert verdict.ok?, verdict.report
      refute verdict.refuse?
      assert_equal "signer isolation (qa): OK — this key IS qa's system wallet #{QA.to_base58}", verdict.report
    end
  end

  test "production holding its own filed wallet is OK today" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET }, environment: "production", registry: registry)
    assert verdict.ok?, verdict.report
  end

  # "Different from prod" is not the rule: a key the vault does not know is
  # isolated and dead. Only the FILED wallet passes.
  test "a key that is merely different from production is still refused under enforce" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => STRANGER_SECRET }, environment: "qa",
                          registry: registry(mode: "enforce", qa_wallet: QA.to_base58))

    assert verdict.refuse?
    assert_equal [:mismatch], verdict.findings.map(&:kind)
  end

  # ── THE SWITCH ESCALATES, NEVER RELAXES ─────────────────────────────────

  test "SIGNER_ISOLATION=enforce on the target app escalates a warn registry" do
    env = { "SOLANA_ADMIN_KEY" => PROD_SECRET, "SIGNER_ISOLATION" => "enforce" }
    assert GUARD.check(env: env, environment: "qa", registry: registry).refuse?
  end

  test "SIGNER_ISOLATION=warn cannot relax a committed enforce" do
    env = { "SOLANA_ADMIN_KEY" => PROD_SECRET, "SIGNER_ISOLATION" => "warn" }
    assert GUARD.check(env: env, environment: "qa", registry: registry(mode: "enforce"),
                       mode_values: ["warn"]).refuse?
  end

  test "a typo in the switch is read as enforce, and says so" do
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => PROD_SECRET, "SIGNER_ISOLATION" => "enforec" },
                          environment: "qa", registry: registry)
    assert verdict.refuse?
    assert_match(/"enforec" is neither warn nor enforce; treated as enforce/, verdict.report)
  end

  # ── ABSENCE IS NOT ISOLATION ────────────────────────────────────────────

  test "absent, empty, underivable and unreadable are findings, never passes" do
    cases = {
      missing_key: {},
      missing_key_empty: { "SOLANA_ADMIN_KEY" => "  " },
      underivable: { "SOLANA_ADMIN_KEY" => "0OIl-not-base58" },
      underivable_short: { "SOLANA_ADMIN_KEY" => Solana::Keypair.encode_base58("\x01".b * 16) },
      unreadable: nil
    }
    cases.each do |label, env|
      verdict = GUARD.check(env: env, environment: "production", registry: registry)
      refute verdict.ok?, "#{label} must not pass"
      assert_equal label.to_s.sub(/_(empty|short)\z/, "").to_sym, verdict.findings.first.kind
    end
  end

  test "an underivable key is reported without any of its characters" do
    bad = "#{PROD_SECRET[0, 40]}0OIl"
    verdict = GUARD.check(env: { "SOLANA_ADMIN_KEY" => bad }, environment: "production", registry: registry)
    refute_includes verdict.report, PROD_SECRET[0, 40]
    refute_includes verdict.report, bad
  end

  # ── THE REGISTRY ────────────────────────────────────────────────────────

  test "the committed registry loads, warns by default, and files production as the chain's server signer" do
    committed = GUARD::Registry.load
    assert_equal "warn", committed.mode, "shipping in enforce would freeze every production deploy until the ceremony"
    assert_equal "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd", committed.system_wallet("production")
    assert_nil committed.system_wallet("qa"), "QA has no key of its own until Mr. McRitchie runs the ceremony"
    assert_equal "production", committed.environment_for(network: "mainnet-beta", deployed: true)
    assert_equal "qa", committed.environment_for(network: "devnet", deployed: true)
    assert_equal "development", committed.environment_for(network: "devnet", deployed: false)
    assert_equal "qa", committed.environment_for_app("turf-monster-qa")
  end

  test "a registry filing one wallet for two environments is refused" do
    error = assert_raises(GUARD::RegistryError) { registry(qa_wallet: PROD.to_base58) }
    assert_match(/one system wallet for several environments/, error.message)
  end

  test "a registry wallet that is not a public key is refused" do
    assert_raises(GUARD::RegistryError) { registry(qa_wallet: "not-a-key") }
  end

  # ── A BROKEN REGISTRY FAILS CLOSED ──────────────────────────────────────
  #
  # The registry is where `mode: enforce` is committed. A file that cannot be
  # read cannot say whether enforce was committed, so reading it as "the guard
  # did not run" (warn, deploy continues) silently drops the switch the day it
  # matters. Every way the file can be broken is REGISTRY_INVALID_EXIT, which
  # bin/deploy refuses on, in either mode.
  BROKEN_REGISTRIES = {
    "unparseable YAML" => "mode: enforce\nenvironments: [unclosed\n",
    "a list, not a map" => "- mode\n- enforce\n",
    "a bare string" => "enforce\n",
    "an empty file" => "",
    "environments as a list" => "mode: enforce\nenvironments:\n  - production\n",
    "a bad mode" => "mode: enforse\nenvironments: {}\n"
  }.freeze

  test "a registry that is not a map is invalid, not a crash" do
    %w[string list].zip(["enforce", %w[mode enforce]]).each do |label, data|
      assert_raises(GUARD::RegistryInvalid, label) { GUARD::Registry.new(data) }
    end
  end

  test "CLI: every broken registry exits REGISTRY_INVALID_EXIT, in warn and for both commands" do
    assert_not_equal GUARD::REFUSED_EXIT, GUARD::REGISTRY_INVALID_EXIT
    assert_not_equal 1, GUARD::REGISTRY_INVALID_EXIT, "1 is what a crashed Ruby exits"

    BROKEN_REGISTRIES.each do |label, body|
      with_registry(body) do |path|
        out = StringIO.new
        status = GUARD.cli(%w[--list-apps], out: out, env: {}, registry_path: path)
        assert_equal GUARD::REGISTRY_INVALID_EXIT, status, "--list-apps, #{label}: #{out.string}"
        assert_match(/signer registry/, out.string, label)

        out = StringIO.new
        status = GUARD.cli(%w[--environment qa], stdin: StringIO.new("{}"), out: out, env: {}, registry_path: path)
        assert_equal GUARD::REGISTRY_INVALID_EXIT, status, "--environment, #{label}: #{out.string}"
      end
    end
  end

  test "CLI: a missing registry fails closed too" do
    out = StringIO.new
    status = GUARD.cli(%w[--list-apps], out: out, env: {}, registry_path: "/nonexistent/solana_signers.yml")
    assert_equal GUARD::REGISTRY_INVALID_EXIT, status, out.string
  end

  # ── THE CLI bin/deploy RUNS ─────────────────────────────────────────────

  test "CLI: warn mode exits 0, enforce exits REFUSED_EXIT, and neither prints the secret" do
    config = { "SOLANA_ADMIN_KEY" => PROD_SECRET, "STRIPE_SECRET_KEY" => "sk_live_fake" }.to_json

    warn_out, status = run_cli(config, environment: "qa")
    assert_equal 0, status.exitstatus, warn_out
    assert_match(/WARNING/, warn_out)

    enforce_out, status = run_cli(config, environment: "qa", env: { "SIGNER_ISOLATION" => "enforce" })
    assert_equal GUARD::REFUSED_EXIT, status.exitstatus, enforce_out
    assert_match(/REFUSED/, enforce_out)

    [warn_out, enforce_out].each do |out|
      refute_includes out, PROD_SECRET
      refute_includes out, "sk_live_fake"
    end
  end

  # A JSON parser error quotes the text it choked on, and this text is every
  # secret the app holds.
  test "CLI: a malformed config is UNREADABLE and the parser never echoes it" do
    broken = %({"SOLANA_ADMIN_KEY": "#{PROD_SECRET}", "X": })
    out, status = run_cli(broken, environment: "production")

    assert_equal 0, status.exitstatus
    assert_match(/could not be read/, out)
    refute_includes out, PROD_SECRET
  end

  test "CLI: an empty STDIN (a failed heroku read) is a finding, refused under enforce" do
    out, status = run_cli("", environment: "qa", env: { "SIGNER_ISOLATION" => "enforce" })
    assert_equal GUARD::REFUSED_EXIT, status.exitstatus, out
  end

  test "CLI in-process: an unknown environment is a guard that could not run, not a crash" do
    out = StringIO.new
    status = GUARD.cli(%w[--environment staging], stdin: StringIO.new("{}"), out: out, env: {})
    assert_equal 0, status
    assert_match(/could not run — signer registry has no environment "staging"/, out.string)

    out = StringIO.new
    status = GUARD.cli(%w[--environment staging], stdin: StringIO.new("{}"), out: out,
                       env: { "SIGNER_ISOLATION" => "enforce" })
    assert_equal GUARD::REFUSED_EXIT, status
  end

  private

  def with_registry(body)
    Dir.mktmpdir("signer-registry") do |dir|
      path = File.join(dir, "solana_signers.yml")
      File.write(path, body)
      yield path
    end
  end

  # Runs the file exactly as bin/deploy does: plain `ruby`, no Rails, no
  # bundler, config on STDIN.
  def run_cli(stdin, environment:, env: {})
    out, status = Open3.capture2e(
      { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "SIGNER_ISOLATION" => nil }.merge(env),
      RbConfig.ruby, GUARD_RB, "--environment", environment,
      stdin_data: stdin, chdir: Rails.root.to_s
    )
    [out, status]
  end
end
