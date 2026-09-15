require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# bin/deploy's EXPECTED_IDL_HASH dance, driven end to end against a FAKE Heroku
# target (task make-deploy-governance-aware).
#
# THE BUG, MEASURED. `wire-rails-to-governance` taught Solana::Config to select
# one of FOUR IDLs — two clusters x two turf-vault versions — by
# SOLANA_VAULT_GOVERNANCE. bin/deploy kept selecting on SOLANA_NETWORK alone. Run
# the pre-fix script against the post-ceremony steady state (governance on, pin =
# the v0.26 hash) and it does this, measured 2026-09-15 by this very harness:
#
#   config:set EXPECTED_IDL_HASH=d1eea2a…,b9b5226…   (widen)
#   push heroku-mainnet main
#   config:set EXPECTED_IDL_HASH=b9b5226…            (tighten — THE v0.25 HASH)
#
# That last line drops d1eea2a… — the hash of the file the running app actually
# reads — and a `config:set` restarts the dynos, so the app stops booting on the
# spot. verify_governance_alignment! is deliberately outside BYPASS_IDL_CHECK
# (the hatch covers hash SKEW, not a wrong SHAPE), so there is no hatch either.
#
# WHY A REAL RUN AND NOT A SOURCE READ. A structural assertion that bin/deploy
# "mentions the switch" would have passed on plenty of wrong scripts. What has to
# be true is about the VALUE the script writes at the end, and the only honest
# way to see that value is to let the script compute it.
#
# SAFETY. The child PATH is the shim directory plus /usr/bin:/bin:/usr/sbin:/sbin
# — the real `heroku` (Homebrew, /opt/homebrew/bin) is not on it, the shim is
# first regardless, and `git push` is intercepted. assert_target_is_fake below
# pins that property so a future edit cannot quietly point this at production.
class DeployIdlDanceTest < ActiveSupport::TestCase
  DEPLOY = Rails.root.join("bin", "deploy")
  SELECTION_RB = Rails.root.join("lib", "solana", "idl_selection.rb")
  IDLS = %w[
    turf_vault.idl.json turf_vault.v026.idl.json
    turf_vault.mainnet.idl.json turf_vault.mainnet.v026.idl.json
  ].freeze

  V025 = Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.idl.json")))
  V026 = Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.v026.idl.json")))
  STALE = "0" * 64 # a pin left over from an earlier turf-vault revision

  REAL_GIT = `command -v git`.strip.freeze
  CHILD_PATH_TAIL = "/usr/bin:/bin:/usr/sbin:/sbin".freeze

  # ── THE REGRESSION ────────────────────────────────────────────────────────

  test "after the ceremony an ordinary deploy rewrites NOTHING" do
    result = deploy(governance: "on", pin: V026)

    assert_equal 0, result[:status], result[:stderr]
    assert_empty result[:config_sets],
                 "the live IDL is already pinned, so there is no bump and no dance — " \
                 "the pre-fix script wrote two config:sets here, the second of them fatal"
    assert_includes result[:log], "push heroku-mainnet main"
    assert_match(%r{config/turf_vault\.mainnet\.v026\.idl\.json}, result[:stdout],
                 "the script must name the file the app boots against")
  end

  # ── THE TIGHTEN WRITES THE LIVE HASH ──────────────────────────────────────

  test "a genuine bump under governance tightens onto the hash the app boots with" do
    result = deploy(governance: "on", pin: STALE)

    assert_equal 0, result[:status], result[:stderr]
    assert_equal 2, result[:config_sets].length, "widen, then tighten"

    widen, tighten = result[:config_sets]
    assert_includes widen.split(","), STALE, "the outgoing slug must stay bootable across the release"
    assert_includes widen.split(","), V026

    assert_includes tighten.split(","), V026, "the tighten must keep the hash the running app reads"
    refute_includes tighten.split(","), STALE, "and must drop the stale one — that is what a tighten is for"
    assert_equal V026, tighten.split(",").first, "the live shape leads the set"
  end

  # THE ROLLBACK THE WHOLE DESIGN WAS CHOSEN FOR. `heroku config:unset
  # SOLANA_VAULT_GOVERNANCE` re-resolves IDL_PATH to the other shape's file and
  # restarts the dynos — no deploy, no second Squads ceremony. It boots only
  # while that file's hash is still allow-listed, so a tighten onto ONE hash
  # spends the reversibility silently.
  test "the tighten keeps the other switch position bootable" do
    result = deploy(governance: "on", pin: STALE)
    tighten = result[:config_sets].last.split(",")

    assert_includes tighten, V025,
                    "unsetting SOLANA_VAULT_GOVERNANCE must still boot: the v0.25 IDL's hash stays allow-listed"
    assert_equal 2, tighten.length, "exactly the two IDLs this slug ships for this cluster"
  end

  # The same property in the direction that is live TODAY: the switch is unset,
  # so the v0.25 file is selected and the v0.26 hash is the one kept — which is
  # what makes the ceremony's forward flip a config write rather than a deploy.
  test "with the switch unset the v0.25 IDL is selected and v0.26 is kept" do
    result = deploy(governance: nil, pin: STALE)
    tighten = result[:config_sets].last.split(",")

    assert_equal V025, tighten.first
    assert_includes tighten, V026
    assert_match(%r{config/turf_vault\.mainnet\.idl\.json}, result[:stdout])
  end

  # ── REFUSALS HAPPEN BEFORE ANYTHING IS WRITTEN ────────────────────────────

  test "a garbage switch stops the deploy before the widen and before the push" do
    result = deploy(governance: "yeah", pin: V026)

    refute_equal 0, result[:status], "a typo must not resolve to a shape"
    assert_empty result[:config_sets]
    refute_includes result[:log], "push heroku-mainnet main"
    assert_match(/SOLANA_VAULT_GOVERNANCE is set to "yeah"/, result[:stderr])
  end

  # An empty SOLANA_NETWORK is also what a FAILED `heroku config` read looks
  # like. The pre-fix script treated it as "devnet" and would have pinned a
  # mainnet app to a devnet IDL's hash.
  test "a target that names no cluster is refused rather than assumed to be devnet" do
    result = deploy(governance: "on", pin: V026, network: nil)

    refute_equal 0, result[:status]
    assert_empty result[:config_sets]
    assert_match(/SOLANA_NETWORK is empty or unset/, result[:stderr])
  end

  # ── HARNESS ───────────────────────────────────────────────────────────────

  private

  def deploy(governance:, pin:, network: "mainnet-beta")
    Dir.mktmpdir("deploy-dance") do |work|
      repo = File.join(work, "repo")
      shims = File.join(work, "shims")
      config = File.join(work, "config.json")
      log = File.join(work, "heroku.log")

      build_repo(repo)
      build_shims(shims, log)
      File.write(config, target_config(governance: governance, pin: pin, network: network).to_json)
      FileUtils.touch(log)

      assert_target_is_fake(shims)

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{shims}:#{CHILD_PATH_TAIL}",
          "HOME" => work,
          "SKIP_TESTS" => "1",
          "FAKE_HEROKU_CONFIG" => config,
          "FAKE_HEROKU_LOG" => log
        },
        "/bin/bash", "bin/deploy", "--yes",
        chdir: repo, unsetenv_others: true
      )

      lines = File.read(log).lines.map(&:chomp)
      {
        status: status.exitstatus, stdout: stdout, stderr: stderr, log: lines,
        config_sets: lines.grep(/^config:set EXPECTED_IDL_HASH=/).map { |l| l.split("=", 2).last }
      }
    end
  end

  def target_config(governance:, pin:, network:)
    config = { "EXPECTED_IDL_HASH" => pin, "STRIPE_SECRET_KEY" => "sk_live_fake" }
    config["SOLANA_NETWORK"] = network if network
    config["SOLANA_VAULT_GOVERNANCE"] = governance if governance
    config
  end

  def build_repo(repo)
    FileUtils.mkdir_p(File.join(repo, "bin"))
    FileUtils.mkdir_p(File.join(repo, "lib", "solana"))
    FileUtils.mkdir_p(File.join(repo, "config"))
    FileUtils.cp(DEPLOY, File.join(repo, "bin", "deploy"))
    FileUtils.cp(SELECTION_RB, File.join(repo, "lib", "solana", "idl_selection.rb"))
    IDLS.each { |f| FileUtils.cp(Rails.root.join("config", f), File.join(repo, "config", f)) }

    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "harness@example.test")
    git(repo, "config", "user.name", "harness")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "harness")
    # The remote only has to EXIST — the git shim intercepts the push.
    git(repo, "remote", "add", "heroku-mainnet", "https://example.invalid/fake.git")
  end

  def git(repo, *args)
    out, status = Open3.capture2e(REAL_GIT, "-C", repo, *args)
    assert status.success?, "harness git #{args.first} failed: #{out}"
  end

  def build_shims(shims, log)
    FileUtils.mkdir_p(shims)

    write_shim(shims, "heroku", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      store = ENV.fetch("FAKE_HEROKU_CONFIG")
      log = ENV.fetch("FAKE_HEROKU_LOG")
      cfg = JSON.parse(File.read(store))
      cmd = ARGV.shift
      app = ARGV.each_cons(2).find { |flag, _| flag == "--app" }&.last
      abort "harness: refusing an app this test does not own (\#{app.inspect})" unless app == "turf-monster-mainnet"

      case cmd
      when "config"     then puts JSON.generate(cfg)
      when "config:get" then puts cfg.fetch(ARGV.shift, "")
      when "config:set"
        key, value = ARGV.shift.split("=", 2)
        File.open(log, "a") { |f| f.puts("config:set " + key + "=" + value) }
        cfg[key] = value
        File.write(store, JSON.generate(cfg))
      when "releases" then puts "v187  Deploy abc1234  harness@example.test  2026/09/15 12:00:00 -0600"
      when "rollback" then File.open(log, "a") { |f| f.puts("rollback " + ARGV.first.to_s) }
      when "info"     then puts "Web URL: http://fake.invalid/"
      else abort "harness: unexpected heroku \#{cmd}"
      end
    RUBY

    write_shim(shims, "git", <<~SH)
      #!/bin/sh
      if [ "$1" = "push" ]; then echo "push $2 $3" >> "#{log}"; exit 0; fi
      exec #{REAL_GIT} "$@"
    SH

    write_shim(shims, "curl", "#!/bin/sh\necho 200\n")
    write_shim(shims, "ruby", "#!/bin/sh\nexec #{RbConfig.ruby} \"$@\"\n")
  end

  def write_shim(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # The one assertion that keeps this test off a real app: on the child's PATH,
  # `heroku` can only be the shim.
  def assert_target_is_fake(shims)
    reachable = "#{shims}:#{CHILD_PATH_TAIL}".split(":")
                                             .map { |dir| File.join(dir, "heroku") }
                                             .select { |candidate| File.executable?(candidate) }

    assert_equal [File.join(shims, "heroku")], reachable,
                 "the child PATH must reach the shim and nothing else — the real CLI lives at " \
                 "#{`command -v heroku`.strip.inspect} and must stay unreachable from this test"
  end
end
