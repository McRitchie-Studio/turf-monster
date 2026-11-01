require "test_helper"
require "open3"
require "tmpdir"

# ONE rule, TWO callers. `bin/deploy` once carried its own bash copy of the IDL
# selection, and it drifted. The rule lives in exactly one place,
# `lib/solana/idl_selection.rb`, and both callers apply it. Since the v0.25
# retirement it is cluster alone, plus a refusal for a switch expecting otherwise.
class IdlSelectionRuleTest < ActiveSupport::TestCase
  RULE = Solana::IdlSelection
  SELECTION_RB = Rails.root.join("lib", "solana", "idl_selection.rb")
  CONFIG_RB = Rails.root.join("app", "services", "solana", "config.rb")
  DEPLOY = Rails.root.join("bin", "deploy")

  MATRIX = {
    "mainnet-beta" => "config/turf_vault.mainnet.v026.idl.json",
    "devnet"       => "config/turf_vault.v026.idl.json"
  }.freeze

  # ── THE TABLE ─────────────────────────────────────────────────────────────

  test "each cluster selects its own committed file" do
    MATRIX.each do |network, expected|
      assert_equal expected, RULE.relative_idl_path(network: network)
      assert File.exist?(Rails.root.join(expected)), "#{expected} must be committed"
    end
  end

  test "an unrecognised cluster takes the devnet file, never mainnet's" do
    %w[localnet testnet mainnet].each do |network|
      assert_equal "config/turf_vault.v026.idl.json", RULE.relative_idl_path(network: network),
                   "#{network.inspect} must not resolve to the mainnet artifact"
    end
  end

  test "no retired shape is committed" do
    assert_empty Dir[Rails.root.join("config/turf_vault*.idl.json")].reject { |f| f.include?(".v026.") }
  end

  # ── THE SWITCH ONLY REFUSES ───────────────────────────────────────────────

  test "an absent switch and every true value boot" do
    assert_nil RULE.assert_switch!({})
    %w[on 1 true yes enabled ON True YES].each do |v|
      assert_nil RULE.assert_switch!({ "SOLANA_VAULT_GOVERNANCE" => " #{v} " }), "#{v.inspect} boots"
    end
  end

  test "a value asking for the retired shape refuses, and names the way back" do
    %w[off 0 false no disabled OFF False].each do |v|
      error = assert_raises(RULE::UnreadableSwitchError, "#{v.inspect} must refuse") do
        RULE.assert_switch!({ "SOLANA_VAULT_GOVERNANCE" => v })
      end
      assert_match(/code revert/, error.message)
    end
  end

  test "a present-but-EMPTY switch raises rather than resolving like absent" do
    assert_raises(RULE::UnreadableSwitchError) { RULE.assert_switch!({ "SOLANA_VAULT_GOVERNANCE" => "" }) }
    assert_raises(RULE::UnreadableSwitchError) { RULE.assert_switch!({ "SOLANA_VAULT_GOVERNANCE" => "  " }) }
  end

  test "a present-but-GARBAGE switch raises, naming the value and the accepted set" do
    error = assert_raises(RULE::UnreadableSwitchError) do
      RULE.assert_switch!({ "SOLANA_VAULT_GOVERNANCE" => "yeah" })
    end
    assert_match(/"yeah"/, error.message)
    assert_match(/Accepted \(case-insensitive\): on 1 true yes enabled, or unset it/, error.message)
  end

  test "the presence read is ENV.key?, which is what tells absent from empty" do
    assert_match(/env\.key\?\(GOVERNANCE_ENV_VAR\)/, SELECTION_RB.read,
                 "`ENV.fetch(k, default)` fires only on ABSENCE and would read `VAR=` as unset")
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
  # The first v0.26 build shipped reading metadata.version "0.25.0", so a rule
  # keyed on that string would have selected the wrong wire format. The files
  # are now labelled correctly; the rule still reads only the instruction set.

  test "every committed IDL declares init_governance and carries its build label" do
    MATRIX.each_value do |path|
      absolute = Rails.root.join(path)
      assert RULE.declares_governance?(absolute), "#{path} must declare init_governance"
      assert_equal "0.26.0", JSON.parse(File.read(absolute)).dig("metadata", "version")
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
    assert_equal Rails.root.join(RULE.relative_idl_path(network: Solana::Config::NETWORK)), Solana::Config::IDL_PATH
    assert_equal RULE::VAULT_SHAPE, Solana::Config.vault_shape
    assert_equal RULE.declares_governance?(Solana::Config::IDL_PATH), Solana::Config.idl_declares_governance?
    assert_match(/IdlSelection\.assert_switch!\(ENV\)/, CONFIG_RB.read, "Config must apply the refusal at boot")
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
                 "selecting on the cluster here is a second copy of the rule")
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
                                      'puts Solana::IdlSelection.relative_idl_path(network: "mainnet-beta")',
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

  test "the CLI answers the same file the app would boot with" do
    MATRIX.each do |network, expected|
      [{}, { "SOLANA_VAULT_GOVERNANCE" => "on" }].each do |switch|
        out, err, status = cli({ "SOLANA_NETWORK" => network }.merge(switch).to_json)
        assert status.success?, "#{network} #{switch} must resolve: #{err}"
        assert_equal({ "network" => network, "vault_shape" => "v0.26", "idl_path" => expected }, fields(out))
      end
    end
  end

  test "the CLI refuses a target still set to the retired shape" do
    _, err, status = cli({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "off" }.to_json)
    refute status.success?
    assert_match(/code revert/, err)
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

    _, err, status = Open3.capture3(bare, RbConfig.ruby, SELECTION_RB.to_s, "--deploy-preflight",
                                    stdin_data: { "SOLANA_NETWORK" => "mainnet-beta",
                                                  "SOLANA_VAULT_GOVERNANCE" => "yeah" }.to_json,
                                    unsetenv_others: true)
    refute status.success?
    assert_match(/refusing to boot/, err, "the refusal is prose with em-dashes — it has to survive the write too")
  end

  # ── THE SHAPE GUARD, READ AHEAD OF THE PUSH ───────────────────────────────
  #
  # Solana::Config.verify_governance_alignment! refuses a boot on an IDL of the
  # wrong shape, and it sits OUTSIDE BYPASS_IDL_CHECK on purpose. Reading it
  # before the push turns a release-phase crash into a deploy that never starts.
  test "a swapped IDL file is refused before anything is pushed" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      # The live NAME carrying a body with no governance instruction — a bad
      # copy, a half-applied revert, or a hand-edited file all land here.
      File.write(File.join(root, "config", "turf_vault.mainnet.v026.idl.json"),
                 { instructions: [{ name: "settle_contest" }] }.to_json)

      RULE.stub(:repo_root, root) do
        error = assert_raises(RULE::UnreadableSwitchError) do
          RULE.deploy_preflight({ "SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "on" })
        end
        assert_match(/does not declare init_governance/, error.message)
        assert_match(/BYPASS_IDL_CHECK does not cover it/, error.message)
      end
    end
  end

  test "a missing IDL file is refused by name, not deployed around" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      RULE.stub(:repo_root, root) do
        error = assert_raises(RULE::UnknownNetworkError) { RULE.deploy_preflight({ "SOLANA_NETWORK" => "mainnet-beta" }) }
        assert_match(%r{config/turf_vault\.mainnet\.v026\.idl\.json is missing}, error.message)
      end
    end
  end
end
