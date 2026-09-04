# frozen_string_literal: true

require "test_helper"

# Every remote script the driver sends to a dyno, checked against the guard
# that governs them.
#
# This test exists because of a specific escape: a guard was added that refused
# shell-expandable source, and the create step's own heredoc carried the words
# "a $500 pool" in a prose comment. `bin/qa-contest-rehearsal create` raised
# before it ever contacted the dyno — on EVERY run — and CI stayed green 7/7,
# because nothing in the suite touched Driver at all. The unit tests covered the
# guard, and the guard was fine; what nobody checked was whether the scripts it
# guards could survive it.
#
# So this reads the driver's actual source and holds every heredoc to the rule.
class QaRehearsalRemoteScriptsTest < ActiveSupport::TestCase
  DRIVER = Rails.root.join("lib/turf_monster/qa_rehearsal/driver.rb")

  # Each `<<~RUBY … RUBY` block in the driver is a script that will be
  # re-parsed by a shell on the dyno.
  def remote_scripts
    DRIVER.read.scan(/<<~RUBY\)?\n(.*?)^\s*RUBY$/m).flatten
  end

  # A scan that matched nothing would pass every assertion below while
  # examining an empty list. Assert the input reached the scanner first — the
  # driver has one script per remote step, so a handful is the floor.
  test "the scanner actually finds the driver's remote scripts" do
    assert_operator remote_scripts.size, :>=, 7,
                    "expected several heredocs in #{DRIVER}, found #{remote_scripts.size} — " \
                    "the extraction pattern has drifted and this file is now checking nothing"
  end

  test "no remote script contains anything the dyno's shell would expand" do
    guard = TurfMonster::QaRehearsal::RemoteRunner::SHELL_EXPANDABLE

    offenders = remote_scripts.filter_map do |script|
      hit = script[guard]
      next unless hit

      line = script.lines.find { |l| l.match?(guard) }
      "#{hit.inspect} in: #{line.to_s.strip[0, 90]}"
    end

    assert_empty offenders,
                 "these would be eaten by the dyno's shell before Ruby ran:\n  " +
                 offenders.join("\n  ")
  end

  # The guard is only worth having if it still bites. If someone widens the
  # regex until it matches nothing, the test above passes vacuously.
  test "the guard still catches every shell construct it claims to" do
    guard = TurfMonster::QaRehearsal::RemoteRunner::SHELL_EXPANDABLE

    {
      "parameter"            => 'puts "$stdout"',
      "positional"           => "a $5 pool",
      "brace expansion"      => 'puts "${HOME}"',
      "command substitution" => 'puts "$(whoami)"',
      "backtick"             => 'puts "`whoami`"'
    }.each do |name, sample|
      assert_match guard, sample, "the guard no longer catches a #{name}"
    end

    refute_match guard, 'puts "500 dollars, plainly written"'
  end
end
