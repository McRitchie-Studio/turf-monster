# frozen_string_literal: true

require "json"
require "open3"

module TurfMonster
  module QaRehearsal
    # Runs a snippet of Ruby on the QA dyno and reads one JSON answer back.
    #
    # Four of the five steps need something only the server can do — mint the
    # devnet mint it holds authority over, create the contest through the
    # after_create callback, drive the ESPN poller, grade. Those cannot be
    # HTTP calls because no endpoint exposes them, so this is the seam.
    #
    # The contract is a single marker line. A `heroku run` transcript is full of
    # noise the driver did not ask for — dyno lifecycle chatter, a deprecation
    # warning, three AWS instance-profile errors that are not errors here — and
    # parsing "the last line" or "anything that looks like JSON" picks up
    # whichever of those happens to sort last. Printing one prefixed line and
    # grepping for exactly that prefix is the whole reason this reads reliably.
    class RemoteRunner
      class RemoteError < StandardError; end

      MARKER = "QA_REHEARSAL_JSON"

      attr_reader :app

      # @param executor [#call] receives the argv array, returns [out, err, status].
      #   Injectable so the marker discipline and the error reporting can be
      #   tested without a dyno.
      def initialize(app:, verbose: false, executor: nil)
        @app = app
        @verbose = verbose
        @executor = executor || method(:shell_out)
      end

      # @param source [String] Ruby evaluated on the dyno. It is expected to
      #   call `emit(hash)` exactly once — the helper is prepended below so
      #   every caller marks its answer the same way.
      # @return [Hash] whatever the snippet emitted
      def call(source)
        script = <<~RUBY_SOURCE
          def emit(payload)
            puts "#{MARKER} " + payload.to_json
          end
          #{source}
        RUBY_SOURCE

        out, err, status = @executor.call(
          ["heroku", "run", "--app", app, "--no-tty", "--", "bin/rails", "runner", script]
        )

        warn(out) if @verbose

        line = out.lines.find { |l| l.start_with?(MARKER) }
        unless line
          raise RemoteError,
                "no #{MARKER} line came back from #{app}. exit=#{status&.exitstatus}\n" \
                "#{tail([err, out].compact.join("\n"))}"
        end

        JSON.parse(line.sub(MARKER, "").strip)
      rescue JSON::ParserError => e
        raise RemoteError, "#{app} emitted an unparseable answer: #{e.message}"
      end

      private

      def shell_out(argv)
        Open3.capture3(*argv)
      end

      # `heroku run` ECHOES the whole script back on stderr before running it, so
      # a naive tail of stderr shows the tail of your own script and hides the
      # exception underneath. Everything after the last dyno-ready marker is the
      # part the remote process actually said.
      DYNO_READY = /\.\.\. up, run\.\S+/

      def tail(text, lines: 20)
        body = text.to_s
        if (marker = body.rindex(DYNO_READY))
          after = body[marker..].split("\n", 2)[1].to_s
          body = after unless after.strip.empty?
        end
        body.lines.reject { |l| l.strip.empty? }.last(lines).join
      end
    end
  end
end
