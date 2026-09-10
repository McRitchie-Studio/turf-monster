# frozen_string_literal: true

require "digest"
require "json"
require "open3"

module TurfMonster
  # Refuses to let a production deploy proceed while the QA app and the
  # production app share a server signing key.
  #
  # WHY THIS EXISTS. `SOLANA_ADMIN_KEY` holds the Alex Bot keypair — the
  # server's own signer, 1-of-3 on the vault multisig and the fee payer /
  # contest creator on every on-chain write. On 2026-09-08 it was measured
  # BYTE-IDENTICAL on `turf-monster-mainnet` and `turf-monster-qa` (len 88,
  # matching SHA-256). QA was signing as production: a rehearsal, a seed task,
  # or a stray `bin/rails` console on the QA dyno could put a real signature on
  # a real mainnet transaction. `QaRehearsal::NetworkGuard` already refuses to
  # drive the wrong CLUSTER; nothing refused the shared KEY.
  #
  # WHERE IT CAN RUN — read this before moving it. The comparison needs BOTH
  # apps' config at once, so only one context can host it:
  #
  #   | Home                        | Sees both? | Runs when                  |
  #   |-----------------------------|------------|----------------------------|
  #   | CI (GitHub Actions)         | NO         | never — CI holds no Heroku |
  #   |                             |            | auth and neither secret    |
  #   | A dyno (`solana:preflight`) | NO         | a dyno sees only its OWN   |
  #   |                             |            | ENV, never its sibling's   |
  #   | `bin/deploy` pre-flight     | YES        | every turf-monster prod    |
  #   |                             |            | deploy, on the operator's  |
  #   |                             |            | Heroku-authed machine      |
  #
  # So the guard lives in `bin/deploy`'s pre-flight, beside the existing
  # `EXPECTED_IDL_HASH` / `SKIP_IDL_VERIFICATION` / `STRIPE_SECRET_KEY` checks
  # that already read the live app the same way. CI executes the LOGIC in this
  # file (see test/lib/signing_key_isolation_test.rb) but never the comparison
  # against real values — it cannot, and no doc should claim otherwise.
  #
  # HOW IT READS. Via `heroku config --json`, never `heroku config:get`.
  # `config:get` prints a bare newline for an ABSENT key and for a
  # PRESENT-BUT-EMPTY one and exits 0 either way, so it also cannot be told
  # apart from an unauthenticated read — three states collapsed into one blank
  # line. docs/SOLANA.md ("Check it by KEY PRESENCE") bans it for that reason.
  # The JSON payload answers presence and value together, and a failed read
  # fails the COMMAND rather than returning a plausible blank.
  #
  # ABSENCE IS NOT ISOLATION. A missing, empty, or unreadable value on either
  # side yields :indeterminate, which is a FAILURE. Two blanks compare EQUAL
  # and two unknowns compare UNEQUAL, so either naive comparison would answer
  # confidently and wrongly; refusing is the only honest verdict. This matches
  # `bin/deploy`'s existing fail-closed contract (a missing EXPECTED_IDL_HASH
  # aborts too), and `--skip-checks` remains the documented escape.
  #
  # NOTHING HERE EVER HOLDS THE SECRET. Reading digests the value in its
  # constructor and discards the plaintext, so no accessor, `inspect`, report
  # line, or backtrace can publish it. Comparison is on the digests.
  class SigningKeyIsolation
    VARIABLE = "SOLANA_ADMIN_KEY"
    PRODUCTION_APP = "turf-monster-mainnet"
    QA_APP = "turf-monster-qa"

    # Enough to distinguish two keys in a transcript, short enough to be a poor
    # confirmation oracle. The same form both prior measurements were reported in.
    DIGEST_PREFIX_LENGTH = 12

    # One environment's answer, with the plaintext already thrown away.
    #
    # States:
    #   :present    — the key exists and has a non-blank value
    #   :empty      — the key exists and its value is blank
    #   :missing    — the key does not exist on that app
    #   :unreadable — the read itself failed (not logged in, no such app,
    #                 network error, non-JSON response)
    class Reading
      READABLE_STATES = %i[present empty missing].freeze

      attr_reader :app, :state, :digest, :length, :reason

      class << self
        # @param present [Boolean] whether the app's config carries the key AT ALL
        # @param raw [String, nil] the value, used only to derive digest + length
        def for(app:, present:, raw: nil)
          return new(app: app, state: :missing) unless present

          normalized = raw.to_s.strip
          return new(app: app, state: :empty) if normalized.empty?

          new(app: app, state: :present, normalized: normalized)
        end

        def unreadable(app:, reason:)
          new(app: app, state: :unreadable, reason: reason)
        end
      end

      def initialize(app:, state:, normalized: nil, reason: nil)
        @app = app.to_s
        @state = state
        @reason = reason
        # Digest here and keep nothing else. `normalized` is a local that goes
        # out of scope with the constructor; it is never assigned to an ivar.
        if normalized
          @digest = Digest::SHA256.hexdigest(normalized)
          @length = normalized.length
        end
        freeze
      end

      def present? = state == :present

      # True when the READ succeeded, whatever it found. Separates "the key is
      # not there" from "we could not look".
      def readable? = READABLE_STATES.include?(state)

      def digest_prefix
        digest&.slice(0, DIGEST_PREFIX_LENGTH)
      end

      # What the operator is shown. Never the value.
      def describe
        case state
        when :present    then "len=#{length} sha256[0,#{DIGEST_PREFIX_LENGTH}]=#{digest_prefix}"
        when :empty      then "key present, value EMPTY"
        when :missing    then "key ABSENT from this app's config"
        when :unreadable then "UNREADABLE — #{reason}"
        end
      end

      # Belt and braces: even a stray `p reading` in a future debugging session
      # cannot print a digest-of-a-secret alongside an app name by accident.
      def inspect = "#<#{self.class.name} app=#{app.inspect} state=#{state.inspect}>"
      alias_method :to_s, :inspect
    end

    attr_reader :production, :qa, :variable

    # @param production [Reading]
    # @param qa [Reading]
    def initialize(production:, qa:, variable: VARIABLE)
      @production = production
      @qa = qa
      @variable = variable
    end

    # Build both readings from a reader object responding to
    # #read(app:, variable:) -> Reading. Injectable so every branch is testable
    # without a network call (the shape QaRehearsal::NetworkGuard established).
    def self.probe(reader: HerokuReader.new, variable: VARIABLE,
                   production_app: PRODUCTION_APP, qa_app: QA_APP)
      new(
        production: reader.read(app: production_app, variable: variable),
        qa: reader.read(app: qa_app, variable: variable),
        variable: variable
      )
    end

    # :shared | :isolated | :indeterminate
    def verdict
      return :indeterminate unless production.present? && qa.present?

      production.digest == qa.digest ? :shared : :isolated
    end

    # The ONLY passing verdict. Absence never reads as distinctness.
    def ok? = verdict == :isolated

    def shared? = verdict == :shared

    def indeterminate? = verdict == :indeterminate

    def report
      lines = [
        "=== Signing key isolation (#{variable}) ===",
        "  production  #{production.app.ljust(22)} #{production.describe}",
        "  qa          #{qa.app.ljust(22)} #{qa.describe}",
        ""
      ]
      lines.concat(verdict_lines)
      lines.join("\n")
    end

    private

    def verdict_lines
      case verdict
      when :isolated
        ["  OK — #{qa.app} signs with its own key."]
      when :shared
        [
          "  FAIL — SHARED SIGNING KEY.",
          "  #{qa.app} holds the SAME #{variable} as #{production.app}, so QA",
          "  signs as production: anything that runs there can put a real",
          "  signature on a real mainnet transaction.",
          "  Fix: give QA its own keypair, then rotate. Do NOT reuse production's."
        ]
      else
        ["  FAIL — INDETERMINATE. Could not prove the two environments differ."] +
          indeterminate_reasons +
          [
            "  An absent, empty, or unreadable value is NOT evidence of isolation:",
            "  two blanks compare equal and two unknowns compare unequal, so either",
            "  answer would be a guess. Confirm with `heroku auth:whoami`, then",
            "  `heroku config --json --app <app> | jq 'has(\"#{variable}\")'`."
          ]
      end
    end

    def indeterminate_reasons
      [production, qa].reject(&:present?).map do |reading|
        "  · #{reading.app}: #{reading.describe}"
      end
    end

    # Turns one Heroku app into one Reading.
    #
    # It asks for the whole config because that is the only payload that answers
    # PRESENCE, but it extracts a single key and returns a Reading — the blob,
    # which holds every other secret the app has, never leaves this method and is
    # never placed in an error message. A parse failure reports the exception
    # CLASS only, for exactly that reason.
    class HerokuReader
      def initialize(runner: nil)
        @runner = runner || method(:heroku_config_json)
      end

      def read(app:, variable:)
        stdout, status = @runner.call(app)

        unless status
          return Reading.unreadable(app: app, reason: "`heroku config --json --app #{app}` failed")
        end

        begin
          config = JSON.parse(stdout.to_s)
        rescue JSON::ParserError => e
          # Deliberately NOT interpolating the body: on a partial read it may
          # still contain config values.
          return Reading.unreadable(app: app, reason: "config payload was not JSON (#{e.class})")
        end

        unless config.is_a?(Hash)
          return Reading.unreadable(app: app, reason: "config payload was not a JSON object")
        end

        Reading.for(app: app, present: config.key?(variable), raw: config[variable])
      end

      private

      def heroku_config_json(app)
        out, _err, status = Open3.capture3("heroku", "config", "--json", "--app", app)
        [out, status.success?]
      end
    end
  end
end
