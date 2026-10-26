require "test_helper"
require "tmpdir"
require "open3"
require Rails.root.join("lib", "deploy", "ci_verified").to_s

# bin/deploy SKIPS ITS LOCAL SUITE ONLY ON A CONDUCTOR-READ GREEN FOR HEAD (task
# faster-steadier-production-ship). The release conductor reads GitHub CI's verdict
# for the SHA it deploys and, only on green, passes `--ci-verified=<sha>`. The rule
# is lib/deploy/ci_verified.rb; bin/deploy calls it as a script.
class DeployCiVerifiedTest < ActiveSupport::TestCase
  DEPLOY = Rails.root.join("bin", "deploy")
  SCRIPT = Rails.root.join("lib", "deploy", "ci_verified.rb")
  HEAD = "a1" * 20

  # --- unit: the rule ---------------------------------------------------------

  test "[unit] no flag runs the suite exactly as before" do
    assert_equal :run, Deploy::CiVerified.decide(head: HEAD, verified: "").first
    assert_equal :run, Deploy::CiVerified.decide(head: HEAD, verified: nil).first
  end

  test "[unit] a flag naming HEAD skips the suite" do
    verdict, message = Deploy::CiVerified.decide(head: HEAD, verified: HEAD.upcase)

    assert_equal :skip, verdict
    assert_includes message, "GitHub CI read GREEN"
  end

  test "[unit] a flag naming another tree, or an abbreviated SHA, refuses" do
    assert_equal :refuse, Deploy::CiVerified.decide(head: HEAD, verified: "b2" * 20).first
    assert_equal :refuse, Deploy::CiVerified.decide(head: HEAD, verified: HEAD[0, 7]).first,
                 "a short SHA is ambiguous — CI vouched for one exact tree"
    assert_equal :refuse, Deploy::CiVerified.decide(head: HEAD, verified: "not-a-sha").first
  end

  # --- integration: the script against a real git HEAD -------------------------

  test "[integration] the script skips only for the checkout's real HEAD" do
    Dir.mktmpdir do |dir|
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t")
      git!(dir, "config", "user.name", "t")
      File.write(File.join(dir, "a.txt"), "a")
      git!(dir, "add", "a.txt")
      git!(dir, "commit", "-q", "-m", "a")
      head = git!(dir, "rev-parse", "HEAD").strip

      out, status = script(dir, head, head)
      assert_equal 0, status.exitstatus, out
      assert_includes out, "skipping the local suite"

      File.write(File.join(dir, "a.txt"), "b")
      git!(dir, "commit", "-qam", "b")
      out, status = script(dir, git!(dir, "rev-parse", "HEAD").strip, head)
      assert_equal 3, status.exitstatus, "a green read of the PREVIOUS commit must not vouch for this one: #{out}"

      _, status = script(dir, head, "")
      assert_equal 10, status.exitstatus, "no flag means run the suite"
    end
  end

  # --- structural: bin/deploy wires it before the suite, and keeps the suite --

  test "bin/deploy parses --ci-verified and consults the rule before running tests" do
    src = File.read(DEPLOY)

    assert_includes src, %(--ci-verified=*) + ") CI_VERIFIED_SHA=", "the flag is parsed"
    rule  = src.index("ruby lib/deploy/ci_verified.rb")
    suite = src.index("if bin/rails test >")
    assert rule && suite && rule < suite, "the rule decides before the local suite would run"
    assert_match(/RUN_LOCAL_TESTS" = "1" \] && \[ "\$\{SKIP_TESTS:-0\}" != "1" \]/, src,
                 "the suite still runs whenever the rule did not say skip")
    assert_match(/\*\)\s+fail "\$CI_VERDICT"/, src, "a refusal stops the deploy before anything changes")
  end

  private

  def script(dir, head, verified)
    Open3.capture2e("ruby", SCRIPT.to_s, "--head", head, "--verified", verified, chdir: dir)
  end

  def git!(dir, *argv)
    out, status = Open3.capture2e("git", *argv, chdir: dir)
    assert status.success?, "git #{argv.join(' ')} failed: #{out}"
    out
  end
end
