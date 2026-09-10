# frozen_string_literal: true

require "json"
require "fileutils"

module TurfMonster
  module QaRehearsal
    # The run's memory between steps.
    #
    # The whole point of splitting this into four watchable steps is that the
    # operator runs them separately, reads each one, and decides whether to go
    # on. That means step 2 cannot hold anything in memory from step 1 — so the
    # facts step 1 learned (which contest, which matchups, how many picks) are
    # written down where step 2 can read them.
    #
    # It also makes a failed step re-runnable without redoing the step before
    # it, which is what turns "the rehearsal broke" into "run step 3 again".
    class Manifest
      class MissingError < StandardError; end

      DEFAULT_DIR = "tmp/qa-rehearsal"
      CURRENT = "current.json"

      attr_reader :path

      def initialize(dir: DEFAULT_DIR, name: CURRENT)
        @path = File.join(dir, name)
      end

      def write(data)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(data.transform_keys(&:to_s)))
        data
      end

      def merge(data)
        write(read_or_empty.merge(data.transform_keys(&:to_s)))
      end

      def read
        unless File.exist?(path)
          raise MissingError,
                "no rehearsal in progress (#{path} missing) — run step 1 (create) first"
        end

        JSON.parse(File.read(path))
      end

      def read_or_empty
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
      end

      def exist?
        File.exist?(path)
      end

      def clear!
        FileUtils.rm_f(path)
      end
    end
  end
end
