require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# bin/deploy's signer-isolation pre-flight, driven end to end against FAKE
# Heroku apps (task separate-qa-solana-signing-key).
#
# WHAT HAS TO BE TRUE, AND WHY ONLY A RUN SHOWS IT. turf-monster#624 put a
# signing-key guard in this same pre-flight and was closed because merging it
# would have refused every production deploy until the QA rotation ran. So the
# property that matters is behavioural: with today's facts (QA holds
# production's key) and the committed default (warn), the deploy must still
# PUSH — and with enforce on, it must stop BEFORE the push. A source read that
# found "signer_isolation" in the script would pass either way.
#
# SAFETY. As in deploy_idl_dance_test.rb: the child PATH is the shim directory
# plus the system bins, the real Heroku CLI is not on it, `git push` is
# intercepted, and the shim refuses any app this test does not own. Every key is
# derived from a published seed; none is real.
class DeploySignerIsolationTest < ActiveSupport::TestCase
  DEPLOY = Rails.root.join("bin", "deploy")
  COPIED = %w[
    lib/solana/idl_selection.rb
    lib/solana/signer_isolation.rb
    config/turf_vault.idl.json config/turf_vault.v026.idl.json
    config/turf_vault.mainnet.idl.json config/turf_vault.mainnet.v026.idl.json
  ].freeze
  V025 = Digest::SHA256.hexdigest(File.read(Rails.root.join("config", "turf_vault.mainnet.idl.json")))
  CHILD_PATH_TAIL = "/usr/bin:/bin:/usr/sbin:/sbin".freeze
  APPS = %w[turf-monster-mainnet turf-monster-qa].freeze

  def self.keypair(label) = Solana::Keypair.from_bytes(Digest::SHA256.digest("deploy-signer-isolation #{label}"))
  def self.secret(kp) = Solana::Keypair.encode_base58(kp.to_bytes)

  PROD = keypair("prod")
  QA = keypair("qa")
  PROD_SECRET = secret(PROD)
  QA_SECRET = secret(QA)

  def self.which(name)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
               .map { |dir| File.join(dir, name) }
               .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  end
  REAL_GIT = which("git").freeze

  # ── TODAY'S FACTS, TODAY'S DEFAULT ──────────────────────────────────────

  test "warn mode: QA sharing production's key is reported and the deploy still pushes" do
    result = deploy(qa_key: PROD_SECRET)

    assert_equal 0, result[:status], result[:stderr]
    assert_includes result[:log], "push heroku-mainnet main", "warn mode must never block a deploy"
    assert_match(/turf-monster-mainnet signs as production's own system wallet/, result[:stdout])
    assert_match(/qa holds production's system wallet #{PROD.to_base58}/, result[:stderr])
    assert_match(/Signer isolation finding on turf-monster-qa \(warn mode — deploy continues\)/, result[:stderr])
    assert_no_secret(result)
  end

  # ── ENFORCE STOPS BEFORE THE PUSH ───────────────────────────────────────

  test "enforce in the registry refuses before the push" do
    result = deploy(qa_key: PROD_SECRET, mode: "enforce")

    refute_equal 0, result[:status]
    refute_includes result[:log], "push heroku-mainnet main"
    assert_match(/Signer isolation refused on turf-monster-qa \(enforce mode\)/, result[:stderr])
    assert_no_secret(result)
  end

  test "SIGNER_ISOLATION=enforce in the deploying shell refuses too" do
    result = deploy(qa_key: PROD_SECRET, shell_env: { "SIGNER_ISOLATION" => "enforce" })

    refute_equal 0, result[:status]
    refute_includes result[:log], "push heroku-mainnet main"
  end

  # The switch on an app's own config escalates THAT app's check only. The
  # mainnet app is clean, so its enforce passes; QA's finding stays a warning,
  # because nothing escalated QA's check.
  test "SIGNER_ISOLATION=enforce on one app's config escalates only that app's check" do
    result = deploy(qa_key: PROD_SECRET, mainnet_extra: { "SIGNER_ISOLATION" => "enforce" }, qa_wallet: QA.to_base58)

    assert_equal 0, result[:status], result[:stderr]
    assert_match(/turf-monster-mainnet signs as production's own system wallet/, result[:stdout])
    assert_match(/Signer isolation finding on turf-monster-qa \(warn mode/, result[:stderr])
  end

  # ── AFTER THE CEREMONY ──────────────────────────────────────────────────

  test "after the ceremony, enforce passes both apps and pushes" do
    result = deploy(qa_key: QA_SECRET, mode: "enforce", qa_wallet: QA.to_base58)

    assert_equal 0, result[:status], result[:stderr]
    assert_match(/turf-monster-qa signs as qa's own system wallet/, result[:stdout])
    assert_includes result[:log], "push heroku-mainnet main"
  end

  # ── A READ THAT FAILS IS NOT A PASS ─────────────────────────────────────

  test "an unreadable QA config warns in warn mode and refuses under enforce" do
    warned = deploy(qa_key: nil)
    assert_equal 0, warned[:status], warned[:stderr]
    assert_match(/qa's config could not be read/, warned[:stderr])

    refused = deploy(qa_key: nil, mode: "enforce", qa_wallet: QA.to_base58)
    refute_equal 0, refused[:status]
    refute_includes refused[:log], "push heroku-mainnet main"
  end

  test "a guard that cannot run warns and never blocks a warn-mode deploy" do
    result = deploy(qa_key: PROD_SECRET, drop_guard: true)

    assert_equal 0, result[:status], result[:stderr]
    assert_match(/Signer isolation guard did not run/, result[:stderr])
    assert_includes result[:log], "push heroku-mainnet main"
  end

  # ── A BROKEN REGISTRY FAILS CLOSED; A CRASHED GUARD DOES NOT ────────────
  #
  # fix-qa-signer-ceremony-tooling: a malformed config/solana_signers.yml used
  # to read as "guard did not run" and the deploy pushed, dropping a committed
  # `mode: enforce` in silence. The file is where enforce lives, so a file that
  # cannot be read refuses — in warn mode too, because nothing can prove warn.

  test "an unparseable registry refuses before the push, even with no enforce anywhere" do
    result = deploy(qa_key: QA_SECRET, registry_body: "mode: enforce\nenvironments: [unclosed\n")

    refute_equal 0, result[:status]
    refute_includes result[:log], "push heroku-mainnet main"
    assert_match(/Signer isolation refused: config\/solana_signers.yml could not be read/, result[:stderr])
    refute_match(/guard did not run/, result[:stderr])
  end

  test "a registry that parses but is the wrong shape refuses too" do
    result = deploy(qa_key: QA_SECRET, registry_body: "- mode\n- enforce\n")

    refute_equal 0, result[:status]
    refute_includes result[:log], "push heroku-mainnet main"
  end

  test "a guard that CRASHES on a valid registry still warns and pushes" do
    result = deploy(qa_key: PROD_SECRET, crash_guard: true)

    assert_equal 0, result[:status], result[:stderr]
    assert_match(/Signer isolation guard did not run/, result[:stderr])
    assert_includes result[:log], "push heroku-mainnet main"
  end

  # Ruby's stderr (a warning, a deprecation) must never be read as an app name.
  test "stderr from the guard is not parsed as part of the app list" do
    result = deploy(qa_key: QA_SECRET, qa_wallet: QA.to_base58, noisy_guard: true)

    assert_equal 0, result[:status], result[:stderr]
    refute_match(/(on|for) harness-noise/, result[:stderr], "a stderr line was checked as if it were a Heroku app")
    assert_match(/turf-monster-qa signs as qa's own system wallet/, result[:stdout])
  end

  private

  def assert_no_secret(result)
    [result[:stdout], result[:stderr]].each do |stream|
      refute_includes stream, PROD_SECRET
      refute_includes stream, QA_SECRET
    end
  end

  # qa_key nil = the QA app's config cannot be read at all.
  def deploy(qa_key:, mode: "warn", qa_wallet: nil, shell_env: {}, mainnet_extra: {}, drop_guard: false,
             registry_body: nil, crash_guard: false, noisy_guard: false)
    Dir.mktmpdir("deploy-signer") do |work|
      repo = File.join(work, "repo")
      shims = File.join(work, "shims")
      store = File.join(work, "configs")
      log = File.join(work, "heroku.log")

      build_repo(repo, mode: mode, qa_wallet: qa_wallet, drop_guard: drop_guard,
                       registry_body: registry_body, crash_guard: crash_guard, noisy_guard: noisy_guard)
      build_shims(shims, log)
      FileUtils.mkdir_p(store)
      mainnet = { "EXPECTED_IDL_HASH" => V025, "STRIPE_SECRET_KEY" => "sk_live_fake",
                  "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_ADMIN_KEY" => PROD_SECRET }.merge(mainnet_extra)
      File.write(File.join(store, "turf-monster-mainnet.json"), mainnet.to_json)
      if qa_key
        File.write(File.join(store, "turf-monster-qa.json"),
                   { "SOLANA_NETWORK" => "devnet", "SOLANA_ADMIN_KEY" => qa_key }.to_json)
      end
      FileUtils.touch(log)

      assert_target_is_fake(shims)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{shims}:#{CHILD_PATH_TAIL}", "HOME" => work, "SKIP_TESTS" => "1",
          "FAKE_HEROKU_STORE" => store, "FAKE_HEROKU_LOG" => log }.merge(shell_env),
        "/bin/bash", "bin/deploy", "--yes",
        chdir: repo, unsetenv_others: true
      )
      { status: status.exitstatus, stdout: stdout, stderr: stderr, log: File.read(log).lines.map(&:chomp) }
    end
  end

  def build_repo(repo, mode:, qa_wallet:, drop_guard:, registry_body: nil, crash_guard: false, noisy_guard: false)
    FileUtils.mkdir_p(File.join(repo, "bin"))
    FileUtils.cp(DEPLOY, File.join(repo, "bin", "deploy"))
    COPIED.each do |rel|
      next if drop_guard && rel == "lib/solana/signer_isolation.rb"

      FileUtils.mkdir_p(File.join(repo, File.dirname(rel)))
      FileUtils.cp(Rails.root.join(rel), File.join(repo, rel))
    end
    guard = File.join(repo, "lib", "solana", "signer_isolation.rb")
    # A crash AFTER the registry is proven readable: a bug in the guard, not a
    # broken file. The real code is loaded and then a check blows up.
    if crash_guard
      File.write(guard, File.read(guard).sub(/^exit\(Solana::SignerIsolation\.cli\(ARGV\)\).*$/,
                                             'Solana::SignerIsolation::Registry.load; raise "harness: guard bug"'))
    end
    File.write(guard, "$stderr.puts 'harness-noise warning: something deprecated'\n" + File.read(guard)) if noisy_guard
    registry_body ||= {
      "mode" => mode,
      "environments" => {
        "production" => { "network" => "mainnet-beta", "deployed" => true,
                          "heroku_app" => "turf-monster-mainnet", "system_wallet" => PROD.to_base58 },
        "qa" => { "network" => "devnet", "deployed" => true,
                  "heroku_app" => "turf-monster-qa", "system_wallet" => qa_wallet }
      }
    }.to_yaml
    File.write(File.join(repo, "config", "solana_signers.yml"), registry_body)

    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "harness@example.test")
    git(repo, "config", "user.name", "harness")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "harness")
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
      store = ENV.fetch("FAKE_HEROKU_STORE")
      log = ENV.fetch("FAKE_HEROKU_LOG")
      cmd = ARGV.shift
      app = ARGV.each_cons(2).find { |flag, _| flag == "--app" }&.last
      abort "harness: refusing an app this test does not own (\#{app.inspect})" unless #{APPS.inspect}.include?(app)
      path = File.join(store, app + ".json")
      abort "harness: \#{app} config unreadable" unless File.exist?(path)
      cfg = JSON.parse(File.read(path))

      case cmd
      when "config"     then puts JSON.generate(cfg)
      when "config:get" then puts cfg.fetch(ARGV.shift, "")
      when "config:set"
        File.open(log, "a") { |f| f.puts("config:set " + ARGV.first.to_s.split("=", 2).first) }
      when "releases" then puts "v187  Deploy abc1234  harness@example.test  2026/09/27 12:00:00 -0600"
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

  def assert_target_is_fake(shims)
    reachable = "#{shims}:#{CHILD_PATH_TAIL}".split(":")
                                             .map { |dir| File.join(dir, "heroku") }
                                             .select { |candidate| File.executable?(candidate) }
    assert_equal File.join(shims, "heroku"), reachable.first,
                 "the child PATH must resolve `heroku` to the shim before any real CLI"
  end
end
