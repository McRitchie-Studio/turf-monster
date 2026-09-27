require "json"
require "openssl"
require "yaml"

module Solana
  # IS THIS APP'S KEY THIS ENVIRONMENT'S SYSTEM WALLET?
  #
  # `SOLANA_ADMIN_KEY` is the server's own vault signer. turf-monster-qa and
  # turf-monster-mainnet were found carrying the SAME value (hash-compared
  # 2026-09-25), so anything running on the QA dyno could sign as production on
  # mainnet. This module states the rule that makes that visible: every
  # environment names its system wallet's PUBLIC key in config/solana_signers.yml,
  # and a loaded key must be its own environment's wallet and nobody else's.
  #
  # ── WHY NOT "QA DIFFERS FROM PROD" ───────────────────────────────────────
  #
  # That was turf-monster#624's shape, and it was closed for it. "Different" is
  # satisfied by a random key the vault does not recognise, which leaves QA
  # isolated and dead: every admin instruction fails Unauthorized. "Is this
  # environment's filed system wallet" is satisfied only by the key the
  # ceremony seated on chain.
  #
  # ── WARN BY DEFAULT ──────────────────────────────────────────────────────
  #
  # #624 also froze every production deploy until the rotation ran, because it
  # refused from the day it merged. This module reports in `warn` mode and
  # refuses only when `enforce` is switched on, in the yml or by
  # SIGNER_ISOLATION=enforce. Either source may ESCALATE; neither may relax the
  # other, so a stray `warn` on an app cannot undo a committed `enforce`.
  #
  # ── THE SECRET NEVER LEAVES `derive_pubkey` ──────────────────────────────
  #
  # The key is decoded, its public half derived, and the local dropped. No
  # verdict, report line, exception message or `inspect` carries it or any
  # fragment of it. Failures say WHAT failed, never the input that failed.
  #
  # ── THE SIGNER, NOT THE STRING ───────────────────────────────────────────
  #
  # solana-studio's `Keypair.from_bytes` signs with `bytes[0, 32]` and ignores
  # the rest, so two different base58 values can derive one signer. The
  # comparison is therefore on the derived public key, never on the string.
  # test/lib/signer_isolation_test.rb pins this derivation to the gem's.
  #
  # PLAIN RUBY ON PURPOSE, like lib/solana/idl_selection.rb: bin/deploy runs
  # this file directly with the target app's config on STDIN, because a deploy
  # machine cannot boot the app under a mainnet environment. No Rails, no
  # ActiveSupport, no gems: stdlib OpenSSL derives the Ed25519 public key.
  module SignerIsolation
    KEY_ENV_VAR = "SOLANA_ADMIN_KEY".freeze
    MODE_ENV_VAR = "SIGNER_ISOLATION".freeze
    MODES = %w[warn enforce].freeze
    DEFAULT_MODE = "warn".freeze

    # bin/deploy refuses on THIS exit status and nothing else. A guard that
    # crashed (a Ruby error, a missing file) exits 1 and is reported as a guard
    # that did not run, so a bug in the guard cannot freeze deploys while the
    # guard is only warning.
    REFUSED_EXIT = 3

    REGISTRY_PATH = File.expand_path("../../config/solana_signers.yml", __dir__)

    BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze

    # DER header of an Ed25519 PKCS#8 private key (RFC 8410), followed by the
    # 32-byte seed. The one stdlib route to an Ed25519 key from a raw seed.
    ED25519_PKCS8_PREFIX = ["302e020100300506032b657004220420"].pack("H*").freeze

    class RegistryError < StandardError; end
    class UnderivableKey < StandardError; end

    # A finding names a KIND and says it in words that carry public keys only.
    Finding = Struct.new(:kind, :message)

    # The system-wallet registry, config/solana_signers.yml.
    class Registry
      attr_reader :mode, :environments

      def self.load(path = REGISTRY_PATH)
        new(YAML.safe_load(File.read(path)) || {})
      rescue Errno::ENOENT
        raise RegistryError, "signer registry not found at #{path}"
      rescue Psych::Exception => e
        raise RegistryError, "signer registry is not valid YAML (#{e.class})"
      end

      def initialize(data)
        @mode = data.fetch("mode", DEFAULT_MODE).to_s
        raise RegistryError, "signer registry mode #{@mode.inspect} is not one of #{MODES.join(', ')}" unless MODES.include?(@mode)

        @environments = data.fetch("environments") { raise RegistryError, "signer registry names no environments" }
        raise RegistryError, "signer registry environments must be a map" unless @environments.is_a?(Hash)

        validate_wallets!
      end

      def names = environments.keys

      def system_wallet(name)
        entry(name)["system_wallet"]
      end

      # Every OTHER environment's filed wallet, as { name => pubkey }.
      def other_wallets(name)
        entry(name) # raises on an unknown name
        environments.each_with_object({}) do |(other, spec), out|
          next if other == name || spec["system_wallet"].nil?

          out[other] = spec["system_wallet"]
        end
      end

      # The environment a running app is, from its OWN facts: which cluster it
      # talks to, and whether it is deployed. Nil when nothing matches.
      def environment_for(network:, deployed:)
        match = environments.find do |_, spec|
          spec["network"] == network.to_s && spec["deployed"] == deployed
        end
        match&.first
      end

      def environment_for_app(app)
        environments.find { |_, spec| spec["heroku_app"] == app }&.first
      end

      private

      def entry(name)
        environments.fetch(name.to_s) do
          raise RegistryError, "signer registry has no environment #{name.inspect} (known: #{names.join(', ')})"
        end
      end

      # A registry that names one wallet for two environments cannot tell them
      # apart, which is the only thing it exists to do.
      def validate_wallets!
        filed = environments.transform_values { |spec| spec.is_a?(Hash) ? spec["system_wallet"] : :bad }
        bad = filed.select { |_, v| v == :bad }.keys
        raise RegistryError, "signer registry entries must be maps: #{bad.join(', ')}" if bad.any?

        filed.compact.each do |name, pubkey|
          next if SignerIsolation.valid_pubkey?(pubkey)

          raise RegistryError, "signer registry: #{name}.system_wallet is not a 32-byte base58 public key"
        end

        shared = filed.compact.group_by { |_, pubkey| pubkey }.select { |_, pairs| pairs.length > 1 }
        return if shared.empty?

        names = shared.values.flatten(1).map(&:first)
        raise RegistryError, "signer registry files one system wallet for several environments: #{names.join(', ')}"
      end
    end

    # One environment's answer. Holds public keys and words, nothing else.
    class Verdict
      attr_reader :environment, :pubkey, :expected, :findings, :mode, :notes

      def initialize(environment:, pubkey:, expected:, findings:, mode:, notes: [])
        @environment = environment
        @pubkey = pubkey
        @expected = expected
        @findings = findings
        @mode = mode
        @notes = notes
      end

      def ok? = findings.empty?
      def enforce? = mode == "enforce"
      def refuse? = enforce? && !ok?

      def report
        lines = []
        if ok?
          lines << "signer isolation (#{environment}): OK — this key IS #{environment}'s system wallet #{pubkey}"
        else
          verb = refuse? ? "REFUSED" : "WARNING"
          lines << "signer isolation (#{environment}): #{verb} [mode #{mode}]"
          findings.each { |f| lines << "  - #{f.message}" }
          lines << "  Runbook: docs/workflows/qa-signing-key-rotation.md" unless refuse?
          lines << "  Warn mode: nothing was blocked." unless enforce?
        end
        notes.each { |n| lines << "  note: #{n}" }
        lines.join("\n")
      end
    end

    module_function

    # Judge the key in `env` (anything answering [] — ENV, or a parsed
    # `heroku config --json` hash) against `environment`'s filed wallet.
    # `env` nil means the config could not be read at all.
    def check(env:, environment:, registry: Registry.load, mode_values: [])
      mode, notes = resolve_mode(registry.mode, mode_values + [env && env[MODE_ENV_VAR]])
      expected = registry.system_wallet(environment)
      others = registry.other_wallets(environment)

      findings = []
      pubkey = nil

      if env.nil?
        findings << Finding.new(:unreadable, "#{environment}'s config could not be read, so its key cannot be proven to be its own")
      else
        secret = env[KEY_ENV_VAR]
        if secret.nil? || secret.to_s.strip.empty?
          findings << Finding.new(:missing_key, "#{KEY_ENV_VAR} is absent or empty on #{environment}")
        else
          begin
            pubkey = derive_pubkey(secret)
          rescue UnderivableKey
            findings << Finding.new(:underivable, "#{KEY_ENV_VAR} on #{environment} does not derive a signer (not a base58 key of at least 32 bytes)")
          end
        end
      end

      if pubkey
        owner = others.find { |_, wallet| wallet == pubkey }&.first
        if owner
          findings << Finding.new(:foreign, "#{environment} holds #{owner}'s system wallet #{pubkey} — it can sign as #{owner}")
        end

        if expected.nil?
          findings << Finding.new(:unfiled, "no system wallet is filed for #{environment} in config/solana_signers.yml, " \
                                            "so its key #{pubkey} cannot be proven to be its own")
        elsif pubkey != expected
          findings << Finding.new(:mismatch, "#{environment}'s key is #{pubkey}, but its filed system wallet is #{expected}")
        end
      end

      Verdict.new(environment: environment, pubkey: pubkey, expected: expected,
                  findings: findings, mode: mode, notes: notes)
    end

    # Enforce wins over warn from any source. An unrecognised value is read as
    # enforce: someone meant to set the switch, and a typo must not quietly
    # mean "off" on the day they meant "on".
    def resolve_mode(registry_mode, values)
      notes = []
      enforce = registry_mode == "enforce"
      values.compact.each do |raw|
        value = raw.to_s.strip.downcase
        next if value.empty?

        if value == "enforce"
          enforce = true
        elsif value != "warn"
          enforce = true
          notes << "#{MODE_ENV_VAR}=#{raw.to_s.strip.inspect} is neither warn nor enforce; treated as enforce"
        end
      end
      [enforce ? "enforce" : "warn", notes]
    end

    # The public key `secret` signs as, base58. Raises UnderivableKey — with no
    # part of the input in its message — when it cannot produce a signer.
    def derive_pubkey(secret)
      bytes = decode_base58(secret.to_s.strip)
      raise UnderivableKey, "key decodes to fewer than 32 bytes" if bytes.bytesize < 32

      key = OpenSSL::PKey.read(ED25519_PKCS8_PREFIX + bytes.byteslice(0, 32))
      encode_base58(key.public_to_der.byteslice(-32, 32))
    rescue ArgumentError, OpenSSL::PKey::PKeyError
      raise UnderivableKey, "key is not base58 or not an Ed25519 seed"
    end

    def valid_pubkey?(value)
      value.is_a?(String) && decode_base58(value).bytesize == 32
    rescue ArgumentError
      false
    end

    def decode_base58(str)
      raise ArgumentError, "empty base58" if str.empty?

      int = 0
      str.each_char do |c|
        digit = BASE58_ALPHABET.index(c)
        raise ArgumentError, "invalid base58" if digit.nil? # never echo the character
        int = int * 58 + digit
      end
      hex = int.zero? ? "" : int.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      leading = str.each_char.take_while { |c| c == "1" }.length
      ("\x00" * leading).b + [hex].pack("H*")
    end

    def encode_base58(bytes)
      int = bytes.unpack1("H*").then { |h| h.empty? ? 0 : h.to_i(16) }
      out = +""
      while int.positive?
        int, rem = int.divmod(58)
        out.prepend(BASE58_ALPHABET[rem])
      end
      leading = bytes.each_byte.take_while(&:zero?).length
      ("1" * leading) + out
    end

    # ── CLI (bin/deploy) ────────────────────────────────────────────────────
    #
    #   heroku config --json --app <app> | ruby lib/solana/signer_isolation.rb --environment production
    #   ruby lib/solana/signer_isolation.rb --list-apps
    #
    # Reads the target app's config JSON on STDIN — never argv, which `ps`
    # shows to every user on the machine. An empty or unparseable STDIN is an
    # UNREADABLE config, which is a finding: absence is not isolation.
    # Prints the report; exits 0, or REFUSED_EXIT when enforce refuses.
    def cli(argv, stdin: $stdin, out: $stdout, env: ENV, registry_path: REGISTRY_PATH)
      # `--list-apps` prints "<heroku app> <environment>" per deployed app, so
      # bin/deploy loops over the registry instead of keeping its own list.
      # A broken registry exits 1 here (the guard did not run) rather than 0,
      # so the caller never reads an error sentence as an app list.
      if argv.include?("--list-apps")
        begin
          apps = Registry.load(registry_path).environments.select { |_, spec| spec["heroku_app"] }
        rescue RegistryError => e
          out.puts "signer isolation: the guard could not run — #{e.message}"
          return enforce_requested?(env) ? REFUSED_EXIT : 1
        end
        apps.each { |name, spec| out.puts "#{spec['heroku_app']} #{name}" }
        return 0
      end

      environment = argv.each_cons(2).find { |flag, _| flag == "--environment" }&.last
      if environment.nil? || environment.empty?
        out.puts "usage: <config json> | ruby lib/solana/signer_isolation.rb --environment <name>"
        return 2
      end

      registry = Registry.load(registry_path)
      verdict = check(env: parse_config(stdin.read), environment: environment,
                      registry: registry, mode_values: [env[MODE_ENV_VAR]])
      out.puts verdict.report
      verdict.refuse? ? REFUSED_EXIT : 0
    rescue RegistryError => e
      # A broken registry is the guard not running. Under enforce that refuses;
      # under warn it is reported and the deploy carries on.
      out.puts "signer isolation: the guard could not run — #{e.message}"
      enforce_requested?(env) ? REFUSED_EXIT : 0
    end

    # Enforce as far as it can be known WITHOUT the registry: the shell's own
    # switch. Used only when the registry itself is what failed.
    def enforce_requested?(env)
      resolve_mode(DEFAULT_MODE, [env[MODE_ENV_VAR]]).first == "enforce"
    end

    # JSON parse errors quote the input, and this input carries every secret
    # the app has. Rescue by class and say nothing about the bytes.
    def parse_config(raw)
      return nil if raw.nil? || raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end

exit(Solana::SignerIsolation.cli(ARGV)) if $PROGRAM_NAME == __FILE__
