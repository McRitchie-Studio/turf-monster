require "json"

module Solana
  # WHICH turf-vault IDL does a given environment speak to?
  #
  # ONE implementation, TWO callers, because the two answering that question
  # separately is a production outage:
  #
  #   * `Solana::Config` applies it to THIS process's ENV at boot. IDL_PATH,
  #     GOVERNANCE and the structural probe are all thin applications of what
  #     lives here.
  #   * `bin/deploy` applies it to the TARGET Heroku app's config vars, before
  #     it touches EXPECTED_IDL_HASH. It runs this file directly (see the CLI at
  #     the bottom) — no Rails boot, because a deploy machine cannot boot the
  #     app under the target's environment: SOLANA_NETWORK=mainnet-beta trips
  #     `config/initializers/solana_network_alignment.rb` (OPSEC-039) against
  #     the LOCAL RPC and refuses.
  #
  # THE BUG THAT PUT THE RULE HERE (make-deploy-governance-aware). The rule used
  # to live in Config with a hand-written bash MIRROR of it in bin/deploy,
  # carrying a comment that said so. `wire-rails-to-governance` then taught
  # Config to append `.v026` when the governance switch is on; the bash mirror
  # kept selecting on SOLANA_NETWORK alone. After the v0.26 ceremony the next
  # ordinary deploy would have hashed the v0.25 IDL, called it a bump, and
  # TIGHTENED `EXPECTED_IDL_HASH` onto a hash the running app does not read —
  # after which no dyno boots, because `verify_governance_alignment!` sits
  # outside `BYPASS_IDL_CHECK` by design. A mirror is only ever as good as the
  # last person who remembered it existed.
  #
  # PLAIN RUBY ON PURPOSE. No Rails, no ActiveSupport, no gems — `ruby
  # lib/solana/idl_selection.rb` has to work in a deploy shell in ~100ms. Keep
  # it that way: `.presence` and `blank?` do not exist here.
  module IdlSelection
    GOVERNANCE_ENV_VAR = "SOLANA_VAULT_GOVERNANCE".freeze
    GOVERNANCE_TRUE  = %w[on 1 true yes enabled].freeze
    GOVERNANCE_FALSE = %w[off 0 false no disabled].freeze

    NETWORK_ENV_VAR = "SOLANA_NETWORK".freeze
    MAINNET = "mainnet-beta".freeze

    # The discriminator is STRUCTURAL. `init_governance` exists only in v0.26+,
    # so its presence is a fact about the shape the file describes. It is not
    # `metadata.version`: turf-vault built v0.26 with `version = "0.25.0"` still
    # in Cargo.toml, so BOTH shapes report "0.25.0" and a version check returns
    # a plausible answer while selecting the wrong wire format. Filed as
    # cargo-version-lies-about-program; this code must not depend on it being
    # fixed.
    GOVERNANCE_INSTRUCTION = "init_governance".freeze

    # The switch is set to something that is neither on nor off.
    class UnreadableSwitchError < StandardError; end

    # The target names no cluster at all. Fatal rather than defaulted: on a
    # production app `Solana::Config::NETWORK` raises for exactly this, and a
    # deploy script that guesses here would pin a hash for a cluster nobody
    # chose. It is also what a FAILED `heroku config` read looks like.
    class UnknownNetworkError < StandardError; end

    module_function

    # Presence, then parse — in that order, because `ENV.fetch(k, default)`
    # fires only on ABSENCE and would read `SOLANA_VAULT_GOVERNANCE=` as "off".
    # That is the precise hole `empty-solana-network-fails-open` closed for
    # SOLANA_NETWORK, and a typo must not quietly mean "off" on the one day
    # someone meant to turn governance on.
    #
    # `env` is any object answering key?/[] — ENV in the app, a parsed
    # `heroku config --json` hash in bin/deploy, a plain Hash in tests. That
    # last one is the point: absent-vs-empty is directly exercisable without
    # mutating the process environment or re-loading a frozen constant.
    def governance?(env)
      return false unless env.key?(GOVERNANCE_ENV_VAR)

      parse_governance(env[GOVERNANCE_ENV_VAR])
    end

    def parse_governance(value)
      raw = value.to_s.strip.downcase
      return true if GOVERNANCE_TRUE.include?(raw)
      return false if GOVERNANCE_FALSE.include?(raw)

      raise UnreadableSwitchError, <<~MSG
        #{GOVERNANCE_ENV_VAR} is set to #{value.inspect} — refusing to boot.

        It selects which turf-vault instruction shape this app builds, and
        the two shapes are mutually unintelligible on-chain. An unreadable
        value must not resolve to a default, because the default would be
        silently wrong on exactly the day someone meant to change it.

        Accepted (case-insensitive): #{(GOVERNANCE_TRUE + GOVERNANCE_FALSE).join(" ")}
        Unset the variable entirely for the v0.25 (pre-governance) shape.
      MSG
    end

    # The cluster half of the selection. Anything that is not mainnet is a
    # devnet-family cluster (devnet, localnet) and takes the unprefixed files.
    def mainnet?(network)
      network.to_s == MAINNET
    end

    def network_from(env)
      raw = env[NETWORK_ENV_VAR].to_s.strip
      raise UnknownNetworkError, <<~MSG if raw.empty?
        #{NETWORK_ENV_VAR} is empty or unset on the target — refusing to choose an IDL.

        A production app raises on this at boot (OPSEC-012), so there is no
        deploy to make. An empty read also looks exactly like a `heroku config`
        call that failed, and guessing a cluster would pin EXPECTED_IDL_HASH for
        one the operator never chose.
      MSG

      raw
    end

    # Repo-relative, so the same string reads correctly in a bash `[ -f ]`, in a
    # Heroku slug, and in an error message. Four artifacts: two clusters x two
    # program versions.
    def idl_basename(network:, governance:)
      base = mainnet?(network) ? "turf_vault.mainnet" : "turf_vault"
      "#{base}#{governance ? ".v026" : ""}.idl.json"
    end

    def relative_idl_path(network:, governance:)
      File.join("config", idl_basename(network: network, governance: governance))
    end

    # The file the OTHER switch position would select on the same cluster. It is
    # not a curiosity: it is the artifact a `heroku config:unset
    # SOLANA_VAULT_GOVERNANCE` rollback boots against, so bin/deploy keeps its
    # hash in EXPECTED_IDL_HASH rather than tightening the rollback away.
    def sibling_relative_idl_path(network:, governance:)
      relative_idl_path(network: network, governance: !governance)
    end

    def vault_shape(governance)
      governance ? "v0.26" : "v0.25"
    end

    # `[]` when the file is missing or unparseable — the CALLERS own those
    # failures (Config#verify_idl! raises for the app, the CLI below refuses for
    # the deploy), and two errors for one cause buries the informative one.
    #
    # UTF-8 EXPLICITLY, not whatever the caller's locale says. The IDLs carry
    # non-ASCII in their doc strings, and a deploy shell with no LANG gives Ruby
    # a US-ASCII default_external — under which File.read tags those bytes
    # US-ASCII and JSON.parse dies with `"\xE2" on US-ASCII`, which reads as a
    # corrupt IDL rather than a missing environment variable. Rails sets UTF-8
    # for the app, so only the deploy path was ever exposed. Measured 2026-09-15:
    # `ruby -E US-ASCII` on the v0.26 IDL raises exactly that.
    def instruction_names(path)
      return [] unless File.exist?(path)

      JSON.parse(File.read(path, encoding: "UTF-8")).fetch("instructions", []).map { |i| i["name"] }
    rescue JSON::ParserError
      []
    end

    def declares_governance?(path)
      instruction_names(path).include?(GOVERNANCE_INSTRUCTION)
    end

    # The repository this file ships in, so the CLI resolves IDL files against
    # the checkout rather than the caller's cwd.
    def repo_root
      File.expand_path("../..", __dir__)
    end

    # Everything bin/deploy needs about the target, in one pass: the shape it
    # will boot in, the file it will hash, and the sibling whose hash keeps the
    # one-command rollback alive. Raises rather than returning a shrug.
    def deploy_preflight(env)
      network = network_from(env)
      governance = governance?(env)
      relative = relative_idl_path(network: network, governance: governance)
      absolute = File.join(repo_root, relative)

      unless File.exist?(absolute)
        raise UnknownNetworkError, "#{relative} is missing from this checkout (target: #{network}, " \
                                   "#{GOVERNANCE_ENV_VAR} #{governance ? "on" : "off"}) — re-pin per MAINNET_LAUNCH.md."
      end

      declares = declares_governance?(absolute)
      if declares != governance
        raise UnreadableSwitchError, <<~MSG
          The target's #{GOVERNANCE_ENV_VAR} and the IDL it selects disagree — refusing to deploy.

          #{GOVERNANCE_ENV_VAR}: #{governance ? "on (expecting the v0.26 governance shape)" : "unset/off (expecting the v0.25 shape)"}
          Selected IDL:            #{relative}
          That IDL declares #{GOVERNANCE_INSTRUCTION}: #{declares}

          This is Solana::Config.verify_governance_alignment! read ahead of the
          push. Deploying anyway means the release phase refuses to boot, and
          BYPASS_IDL_CHECK does not cover it — that hatch is for hash skew, not
          for a wrong shape.
        MSG
      end

      sibling = sibling_relative_idl_path(network: network, governance: governance)
      sibling = "" unless File.exist?(File.join(repo_root, sibling))

      {
        "network" => network,
        "governance" => governance ? "on" : "off",
        "vault_shape" => vault_shape(governance),
        "idl_path" => relative,
        "declares_governance" => declares.to_s,
        "sibling_idl_path" => sibling,
        "sibling_shape" => sibling.empty? ? "" : vault_shape(!governance)
      }
    end
  end
end

# ── CLI (bin/deploy's half of the contract) ──────────────────────────────────
#
#   heroku config --json --app <app> | ruby lib/solana/idl_selection.rb --deploy-preflight
#
# Reads the target's environment as JSON on STDIN — never argv, because that
# JSON carries every secret the app holds and argv is world-readable in `ps`.
# Prints `key=value` lines; exits non-zero with the refusal on stderr.
if __FILE__ == $PROGRAM_NAME
  unless ARGV == ["--deploy-preflight"]
    warn "usage: heroku config --json --app <app> | ruby #{$PROGRAM_NAME} --deploy-preflight"
    exit 64
  end

  # Same reason as instruction_names: a deploy shell may hand us a US-ASCII
  # locale, and every refusal below is written in prose with em-dashes in it.
  $stdout.set_encoding(Encoding::UTF_8)
  $stderr.set_encoding(Encoding::UTF_8)

  begin
    env = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
    raise ArgumentError, "expected a JSON object of config vars" unless env.is_a?(Hash)

    Solana::IdlSelection.deploy_preflight(env).each { |k, v| puts "#{k}=#{v}" }
  rescue JSON::ParserError
    warn "could not parse the target's config vars as JSON (did `heroku config --json` fail?)"
    exit 65
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
