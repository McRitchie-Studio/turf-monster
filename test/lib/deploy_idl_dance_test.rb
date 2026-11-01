require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# bin/deploy's EXPECTED_IDL_HASH dance, driven end to end against a FAKE Heroku
# target (task make-deploy-governance-aware).
#
# THE BUG THIS EXISTS FOR. bin/deploy once selected its IDL apart from the app,
# wrote `EXPECTED_IDL_HASH` to a hash the running app did not read, and a
# `config:set` restarts the dynos, so the app stopped booting on the spot.
# verify_governance_alignment! is deliberately outside BYPASS_IDL_CHECK (the hatch
# covers hash SKEW, not a wrong SHAPE), so there is no hatch either.
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
  IDLS = %w[turf_vault.v026.idl.json turf_vault.mainnet.v026.idl.json].freeze

  # The retired v0.25 hash production still pins until Steffon tightens it.
  V025 = "b9b522635894a42f5434f1faa1cd126d146f3042ae2c233acd1dd76a300f7152".freeze
  V026 = Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.v026.idl.json")))
  STALE = "0" * 64 # a pin left over from an earlier turf-vault revision

  CHILD_PATH_TAIL = "/usr/bin:/bin:/usr/sbin:/sbin".freeze

  # A PATH search in pure Ruby, NOT `command -v` in backticks: `command` is a
  # shell BUILTIN, and Ruby execs a metacharacter-free command string directly
  # rather than through a shell. Measured on CI 2026-09-15 — the backtick form
  # raised `Errno::ENOENT - command` while loading this class, taking the whole
  # test lane down before a single test ran (it happened to work on the author's
  # laptop, which is exactly how this shape survives review).
  def self.which(name)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
               .map { |dir| File.join(dir, name) }
               .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  end

  REAL_GIT = which("git").freeze

  # ── THE REGRESSION ────────────────────────────────────────────────────────

  test "after the ceremony an ordinary deploy rewrites NOTHING" do
    result = deploy(governance: "on", pin: "#{V026},#{V025}")

    assert_equal 0, result[:status], result[:stderr]
    assert_empty result[:config_sets],
                 "both shapes are already pinned, so there is no bump and no dance — " \
                 "the pre-fix script wrote two config:sets here, the second of them fatal"
    assert_includes result[:log], "push heroku-mainnet main"
    assert_match(%r{config/turf_vault\.mainnet\.v026\.idl\.json}, result[:stdout],
                 "the script must name the file the app boots against")
  end

  test "a pin of the live hash alone writes nothing" do
    result = deploy(governance: "on", pin: V026)

    assert_equal 0, result[:status], result[:stderr]
    assert_empty result[:config_sets]
  end

  test "an absent switch deploys the same file" do
    result = deploy(governance: nil, pin: V026)

    assert_equal 0, result[:status], result[:stderr]
    assert_match(%r{config/turf_vault\.mainnet\.v026\.idl\.json}, result[:stdout])
  end

  # ── THE TIGHTEN WRITES THE LIVE HASH ──────────────────────────────────────

  test "a genuine bump under governance tightens onto the hash the app boots with" do
    result = deploy(governance: "on", pin: STALE)

    assert_equal 0, result[:status], result[:stderr]
    assert_equal 2, result[:config_sets].length, "widen, then tighten"

    widen, tighten = result[:config_sets]
    assert_includes widen.split(","), STALE, "the outgoing slug must stay bootable across the release"
    assert_includes widen.split(","), V026

    assert_equal [V026], tighten.split(","), "the tighten is the hash the running app reads, and only it"
  end

  # The same property in the direction that is live TODAY: the switch is unset,
  # so the v0.25 file is selected and the v0.26 hash is the one kept — which is
  # what makes the ceremony's forward flip a config write rather than a deploy.
  # TODAY'S REAL STATE (read 2026-10-12): both apps pin the v0.25 hash ALONE
  # and the switch is unset. The live file is pinned, so the pre-fix script saw
  # no bump, wrote nothing, and the v0.26 hash never reached the allow-list —
  # the forward flip would then have refused to boot. A deploy must add it.
  # ── REFUSALS HAPPEN BEFORE ANYTHING IS WRITTEN ────────────────────────────

  test "a target set to the retired shape stops the deploy before anything is written" do
    result = deploy(governance: "off", pin: V026)

    refute_equal 0, result[:status]
    assert_empty result[:config_sets]
    refute_includes result[:log], "push heroku-mainnet main"
    assert_match(/code revert/, result[:stderr])
  end

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

    # FIRST, not ONLY: PATH resolution takes the first match, so a real CLI
    # further down the list is never reached — and asserting "only" would redden
    # this test on any image that ships one in /usr/bin.
    assert_equal File.join(shims, "heroku"), reachable.first,
                 "the child PATH must resolve `heroku` to the shim before anything else — the real CLI " \
                 "on this machine is #{self.class.which("heroku").inspect} and must never be what runs"
  end
end
