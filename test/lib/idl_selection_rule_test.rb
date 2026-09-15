require "test_helper"
require "open3"
require "tmpdir"

# ONE rule, TWO callers — and the day they were two rules (task
# make-deploy-governance-aware).
#
# `wire-rails-to-governance` made Solana::Config::IDL_PATH governance-aware:
# four artifacts, two clusters x two program versions, selected at boot by
# SOLANA_VAULT_GOVERNANCE. `bin/deploy` carried its OWN copy of the selection in
# bash — network only — under a comment claiming it mirrored Config. So after the
# v0.26 ceremony the deploy would hash the v0.25 IDL, call it a bump, and tighten
# EXPECTED_IDL_HASH onto a hash the running app does not read. Measured against
# the pre-fix script in test/lib/deploy_idl_dance_test.rb, which is the end of
# that story; this file is about the beginning of it — the rule now lives in
# exactly one place, `lib/solana/idl_selection.rb`, and both callers apply it.
class IdlSelectionRuleTest < ActiveSupport::TestCase
  RULE = Solana::IdlSelection
  SELECTION_RB = Rails.root.join("lib", "solana", "idl_selection.rb")
  CONFIG_RB = Rails.root.join("app", "services", "solana", "config.rb")
  DEPLOY = Rails.root.join("bin", "deploy")

  MATRIX = {
    ["mainnet-beta", true]  => "config/turf_vault.mainnet.v026.idl.json",
    ["mainnet-beta", false] => "config/turf_vault.mainnet.idl.json",
    ["devnet", true]        => "config/turf_vault.v026.idl.json",
    ["devnet", false]       => "config/turf_vault.idl.json"
  }.freeze

  # ── THE TABLE ─────────────────────────────────────────────────────────────

  test "the four cells of cluster x switch select four distinct committed files" do
    MATRIX.each do |(network, governance), expected|
      assert_equal expected, RULE.relative_idl_path(network: network, governance: governance)
      assert File.exist?(Rails.root.join(expected)), "#{expected} must be committed"
    end

    assert_equal 4, MATRIX.values.uniq.length, "four cells, four files — no cell may alias another"
  end

  test "an unrecognised cluster takes the devnet files, never mainnet's" do
    %w[localnet testnet mainnet].each do |network|
      assert_equal "config/turf_vault.idl.json", RULE.relative_idl_path(network: network, governance: false),
                   "#{network.inspect} must not resolve to the mainnet artifact"
    end
  end

  test "the sibling is the same cluster with the switch flipped" do
    assert_equal "config/turf_vault.mainnet.idl.json",
                 RULE.sibling_relative_idl_path(network: "mainnet-beta", governance: true)
    assert_equal "config/turf_vault.mainnet.v026.idl.json",
                 RULE.sibling_relative_idl_path(network: "mainnet-beta", governance: false)
  end

  # ── PRESENCE BEFORE PARSE ─────────────────────────────────────────────────
  #
  # Taking a plain Hash is the point: absent-vs-empty is now exercisable
  # directly, rather than re-derived in a test because the real parse was frozen
  # into a constant at class-load.

  test "an ABSENT switch resolves to v0.25, which is the shape actually deployed" do
    refute RULE.governance?({})
  end

  test "a present-but-EMPTY switch raises rather than resolving like absent" do
    assert_raises(RULE::UnreadableSwitchError) { RULE.governance?({ "SOLANA_VAULT_GOVERNANCE" => "" }) }
    assert_raises(RULE::UnreadableSwitchError) { RULE.governance?({ "SOLANA_VAULT_GOVERNANCE" => "  " }) }
  end

  test "the vocabularies decide, case and whitespace insensitively" do
    %w[on 1 true yes enabled ON True YES].each do |v|
      assert RULE.governance?({ "SOLANA_VAULT_GOVERNANCE" => " #{v} " }), "#{v.inspect} selects v0.26"
    end
    %w[off 0 false no disabled OFF False].each do |v|
      refute RULE.governance?({ "SOLANA_VAULT_GOVERNANCE" => v }), "#{v.inspect} selects v0.25"
    end
  end

  test "a present-but-GARBAGE switch raises, naming the value and the accepted set" do
    error = assert_raises(RULE::UnreadableSwitchError) do
      RULE.governance?({ "SOLANA_VAULT_GOVERNANCE" => "yeah" })
    end
    assert_match(/"yeah"/, error.message)
    assert_match(/Accepted \(case-insensitive\): on 1 true yes enabled off 0 false no disabled/, error.message)
  end

  test "the presence read is ENV.key?, which is what tells absent from empty" do
    assert_match(/env\.key\?\(GOVERNANCE_ENV_VAR\)/, SELECTION_RB.read,
                 "`ENV.fetch(k, default)` fires only on ABSENCE and would read `VAR=` as off")
  end

  # A blank cluster is also what a FAILED `heroku config` read looks like, and a
  # selection rule that guesses there pins a hash for a cluster nobody chose.
  test "a blank cluster refuses rather than defaulting to devnet" do
    assert_raises(RULE::UnknownNetworkError) { RULE.network_from({}) }
    assert_raises(RULE::UnknownNetworkError) { RULE.network_from({ "SOLANA_NETWORK" => "  " }) }
    assert_equal "mainnet-beta", RULE.network_from({ "SOLANA_NETWORK" => " mainnet-beta " })
  end

  # ── THE DISCRIMINATOR IS STRUCTURAL ───────────────────────────────────────
  #
  # turf-vault built v0.26 with `version = "0.25.0"` still in Cargo.toml, so all
  # four artifacts report metadata.version "0.25.0" (filed separately as
  # cargo-version-lies-about-program). Anything keyed on that string returns a
  # plausible answer and selects the wrong wire format.

  test "init_governance, not the version string, tells the two shapes apart" do
    MATRIX.each do |(_network, governance), path|
      absolute = Rails.root.join(path)
      assert_equal governance, RULE.declares_governance?(absolute),
                   "#{path} must declare init_governance iff it is the v0.26 artifact"
      assert_equal "0.25.0", JSON.parse(File.read(absolute)).dig("metadata", "version"),
                   "if turf-vault finally bumps Cargo, this test is where that is noticed"
    end
  end

  test "the rule never reads metadata.version" do
    code = SELECTION_RB.read.lines.reject { |l| l =~ /^\s*#/ }
    version_keyed = code.grep(/metadata|version/)
    assert_empty version_keyed.map(&:strip),
                 "a version-keyed selection looks right, passes review, and ships the wrong shape"
  end

  # ── CALLER 1: THE APP ─────────────────────────────────────────────────────

  test "Solana::Config applies the rule rather than restating it" do
    assert_equal Rails.root.join(RULE.relative_idl_path(network: Solana::Config::NETWORK,
                                                        governance: Solana::Config::GOVERNANCE)),
                 Solana::Config::IDL_PATH
    assert_equal RULE.governance?(ENV), Solana::Config::GOVERNANCE
    assert_equal RULE.vault_shape(Solana::Config::GOVERNANCE), Solana::Config.vault_shape
    assert_equal RULE.declares_governance?(Solana::Config::IDL_PATH), Solana::Config.idl_declares_governance?
  end

  test "config.rb spells no IDL filename of its own" do
    source = CONFIG_RB.read
    refute_match(/turf_vault(\.mainnet)?(\.v026)?\.idl\.json/, source.gsub(/^\s*#.*$/, ""),
                 "an IDL filename literal outside the rule is a second selection waiting to drift")
    refute_match(/\.v026/, source.gsub(/^\s*#.*$/, ""), "the version suffix belongs to the rule")
  end

  # ── CALLER 2: THE DEPLOY ──────────────────────────────────────────────────

  test "bin/deploy asks the rule instead of branching on the cluster itself" do
    source = DEPLOY.read
    assert_match(%r{ruby lib/solana/idl_selection\.rb --deploy-preflight}, source,
                 "bin/deploy must resolve the IDL through the app's own rule")

    code = source.lines.reject { |l| l =~ /^\s*#/ }.join
    refute_match(/turf_vault.*\.idl\.json/, code,
                 "an IDL filename in the deploy script is the copy that went stale")
    refute_match(/mainnet-beta/, code,
                 "selecting on the cluster here is exactly the rule that forgot the governance switch")
  end

  # `bin/rails runner` would be the obvious way to ask the app — and it cannot
  # work: booting under the TARGET's environment trips OPSEC-039's genesis check
  # against whatever RPC the deploy machine has. Measured 2026-09-15 on this
  # laptop: SOLANA_NETWORK=mainnet-beta + the local devnet RPC raises "Solana
  # network mis-alignment — refusing to boot" before any constant is printed.
  # Hence a plain-Ruby rule that answers with no Rails at all.
  test "the rule loads and answers without Rails" do
    out, err, status = Open3.capture3({ "PATH" => ENV["PATH"] },
                                      RbConfig.ruby, "-r", SELECTION_RB.to_s, "-e",
                                      'puts Solana::IdlSelection.relative_idl_path(network: "mainnet-beta", governance: true)',
                                      unsetenv_others: true)
    assert status.success?, "the rule must load standalone (no Rails, no bundler): #{err}"
    assert_equal "config/turf_vault.mainnet.v026.idl.json", out.strip
  end

  # ── THE CLI CONTRACT bin/deploy DEPENDS ON ────────────────────────────────

  def cli(env_json)
    Open3.capture3(RbConfig.ruby, SELECTION_RB.to_s, "--deploy-preflight", stdin_data: env_json)
  end

  def fields(stdout)
    stdout.lines.to_h { |l| l.chomp.split("=", 2) }
  end

  test "the CLI answers the same cell of the table the app would boot into" do
    MATRIX.each do |(network, governance), expected|
      env = { "SOLANA_NETWORK" => network }
      env["SOLANA_VAULT_GOVERNANCE"] = governance ? "on" : "off"

      out, err, status = cli(env.to_json)
      assert status.success?, "#{env.inspect} must resolve: #{err}"

      f = fields(out)
      assert_equal expected, f["idl_path"]
      assert_equal governance.to_s, f["declares_governance"],
                   "the CLI must probe the file it selected, structurally"
      assert_equal RULE.sibling_relative_idl_path(network: network, governance: governance), f["sibling_idl_path"]
      assert_equal governance ? "v0.26" : "v0.25", f["vault_shape"]
    end
  end

  test "an absent switch and an explicit off give the deploy the same answer" do
    absent = fields(cli({ "SOLANA_NETWORK" => "mainnet-beta" }.to_json).first)
    off = fields(cli({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "off" }.to_json).first)
    assert_equal off, absent
    assert_equal "config/turf_vault.mainnet.idl.json", absent["idl_path"]
  end

  test "the CLI refuses a garbage switch, a blank cluster, and unparseable input" do
    _, err, status = cli({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "yeah" }.to_json)
    refute status.success?, "a typo must stop the deploy, not pick a shape"
    assert_match(/SOLANA_VAULT_GOVERNANCE is set to "yeah"/, err)

    _, err, status = cli({ "STRIPE_SECRET_KEY" => "sk_live_x" }.to_json)
    refute status.success?
    assert_match(/SOLANA_NETWORK is empty or unset/, err)

    _, err, status = cli("not json at all")
    refute status.success?
    assert_match(/could not parse/i, err)
  end

  # The CLI reads the target's environment on STDIN because that JSON carries
  # every config var the app holds — argv is world-readable in `ps`.
  test "the CLI takes the environment on stdin, not argv" do
    source = SELECTION_RB.read
    assert_match(/\$stdin\.read/, source)
    assert_match(/ARGV == \["--deploy-preflight"\]/, source, "argv carries the mode, never the secrets")
  end

  # A DEPLOY SHELL MAY CARRY NO LOCALE, and the IDLs carry non-ASCII in their
  # doc strings. With no LANG, Ruby's default_external is US-ASCII (measured on
  # this laptop), File.read tags those bytes US-ASCII, and JSON.parse dies with
  # `"\xE2" on US-ASCII` — which reads as a corrupt IDL rather than a missing
  # environment. Rails hands the app UTF-8, so only the deploy path was exposed;
  # the rule now names the encoding rather than inheriting one.
  test "the CLI answers, and refuses, with no locale in the environment" do
    bare = { "PATH" => "/usr/bin:/bin" }

    out, err, status = Open3.capture3(bare, RbConfig.ruby, SELECTION_RB.to_s, "--deploy-preflight",
                                      stdin_data: { "SOLANA_NETWORK" => "mainnet-beta",
                                                    "SOLANA_VAULT_GOVERNANCE" => "on" }.to_json,
                                      unsetenv_others: true)
    assert status.success?, "a LANG-less deploy shell must still read the IDL: #{err}"
    assert_equal "config/turf_vault.mainnet.v026.idl.json", fields(out)["idl_path"]
    assert_equal "true", fields(out)["declares_governance"], "the structural probe must have parsed the file"

    _, err, status = Open3.capture3(bare, RbConfig.ruby, SELECTION_RB.to_s, "--deploy-preflight",
                                    stdin_data: { "SOLANA_NETWORK" => "mainnet-beta",
                                                  "SOLANA_VAULT_GOVERNANCE" => "yeah" }.to_json,
                                    unsetenv_others: true)
    refute status.success?
    assert_match(/refusing to boot/, err, "the refusal is prose with em-dashes — it has to survive the write too")
  end

  # ── THE SHAPE GUARD, READ AHEAD OF THE PUSH ───────────────────────────────
  #
  # Solana::Config.verify_governance_alignment! refuses a boot whose switch and
  # IDL disagree, and it sits OUTSIDE BYPASS_IDL_CHECK on purpose. Reading it
  # before the push turns a release-phase crash into a deploy that never starts.
  test "a swapped IDL file is refused before anything is pushed" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      # The v0.26 NAME carrying the v0.25 BODY — a bad copy, a half-applied
      # revert, or a hand-edited file all land here.
      FileUtils.cp(Rails.root.join("config", "turf_vault.mainnet.idl.json"),
                   File.join(root, "config", "turf_vault.mainnet.v026.idl.json"))

      RULE.stub(:repo_root, root) do
        error = assert_raises(RULE::UnreadableSwitchError) do
          RULE.deploy_preflight({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "on" })
        end
        assert_match(/declares init_governance: false/, error.message)
        assert_match(/BYPASS_IDL_CHECK does not cover it/, error.message)
      end
    end
  end

  test "a missing IDL file is refused by name, not deployed around" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      RULE.stub(:repo_root, root) do
        error = assert_raises(RULE::UnknownNetworkError) do
          RULE.deploy_preflight({ "SOLANA_NETWORK" => "mainnet-beta" })
        end
        assert_match(%r{config/turf_vault\.mainnet\.idl\.json is missing}, error.message)
      end
    end
  end

  # A slug that ships only ONE shape is legitimate — the day the v0.25 artifacts
  # are finally deleted. The sibling then reports empty rather than a path that
  # does not exist, so bin/deploy pins one hash instead of hashing a ghost.
  test "a slug shipping one shape reports no sibling" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.cp(Rails.root.join("config", "turf_vault.mainnet.v026.idl.json"),
                   File.join(root, "config", "turf_vault.mainnet.v026.idl.json"))

      RULE.stub(:repo_root, root) do
        result = RULE.deploy_preflight({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "on" })
        assert_equal "", result["sibling_idl_path"]
        assert_equal "", result["sibling_shape"]
      end
    end
  end
end
