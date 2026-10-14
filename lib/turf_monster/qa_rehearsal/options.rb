# frozen_string_literal: true

require "optparse"

module TurfMonster
  module QaRehearsal
    # The command line of bin/qa-contest-rehearsal, parsed where a test can
    # reach it.
    #
    # STEP 3 HAS THREE MODES, and the flags name them rather than overloading
    # one number:
    #
    #   play                 unattended (the gauntlet): every captured play is
    #                        re-laid through Goal.create!, back to back, then
    #                        the run checks the chain caught up
    #   play --pace 4        watched: the same replay, SECONDS apart, so a
    #                        person can follow the board. Fractions work (0.5)
    #   play --no-replay     poll only: the ESPN poller writes the week in one
    #                        burst and nothing is re-laid. A poller check, not
    #                        a rehearsal of the per-play chain
    #
    # `--pace 0` IS REFUSED. It used to be read with to_i, so `--pace 0.4`
    # became 0, and 0 silently meant "poll only": a run that looked fast had
    # skipped the per-play chain the gauntlet exists to exercise. A zero now
    # has to be spelled as the mode it means.
    module Options
      class Invalid < StandardError; end

      STEPS = %w[seed create enter play conclude close status].freeze

      PACE_ZERO = "--pace must be more than 0 seconds. `--pace 0` used to mean poll-only, which skips the " \
                  "per-play chain. For the unattended replay drop --pace; for poll-only say --no-replay."
      PACE_WITHOUT_REPLAY = "--pace paces the replay, and --no-replay skips it: pass one or the other."

      DEFAULTS = { cast: nil, cosign: :agent, reset: true, pace: nil, replay: true }.freeze

      module_function

      # @return [Array(String, Hash)] the step (nil when none was given) and the options
      # @raise [Invalid] with the sentence the operator reads
      def parse(argv)
        options = DEFAULTS.dup
        args = argv.dup
        parser(options).parse!(args)

        if options[:pace]
          raise Invalid, PACE_ZERO unless options[:pace].positive?
          raise Invalid, PACE_WITHOUT_REPLAY unless options[:replay]
        end

        [args.shift, options]
      rescue OptionParser::InvalidArgument, OptionParser::MissingArgument, OptionParser::InvalidOption => e
        raise Invalid, e.message
      end

      def parser(options = DEFAULTS.dup)
        OptionParser.new do |o|
          o.banner = "Usage: bin/qa-contest-rehearsal <#{STEPS.join('|')}> [options]"
          o.on("--cast LIST", "Comma-separated cast (default: mack,turf)") { |v| options[:cast] = v.split(",").map(&:strip) }
          o.on("--cosign MODE", "agent (default, devnet v0.26) or link (Phantom)") { |v| options[:cosign] = v.to_sym }
          o.on("--no-reset", "Step 3: do not clear existing scores first") { options[:reset] = false }
          o.on("--pace SECONDS", Float,
               "Step 3, watched: replay scoring plays this far apart (fractions work). " \
               "Omit it for the unattended replay") { |v| options[:pace] = v }
          o.on("--no-replay", "Step 3: poll only. Scores land in one burst; the per-play chain is skipped") do
            options[:replay] = false
          end
          o.on("-h", "--help") do
            puts o
            exit 0
          end
        end
      end
    end
  end
end
