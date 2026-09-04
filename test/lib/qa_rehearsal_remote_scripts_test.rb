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
  #
  # `[^\n]*` after the opener, NOT `\)?`. The first version required the line to
  # end right after an optional close-paren, so it silently skipped
  # `remote.call(<<~RUBY).fetch("goals").positive?` — a real opener in this file.
  # Eight of nine scripts were scanned, and a planted `$stdout.flush` in the
  # ninth left this file GREEN. Match to end of line and the opener's tail
  # cannot hide a script.
  def remote_scripts
    DRIVER.read.scan(/<<~RUBY[^\n]*\n(.*?)^\s*RUBY$/m).flatten
  end

  # Every heredoc opener in the file, in ANY of Ruby's spellings — squiggly or
  # dash, quoted or bare: `<<~RUBY`, `<<-RUBY`, `<<RUBY`, `<<~'RUBY'`,
  # `<<~"RUBY"`.
  #
  # The previous version matched only `<<[~-]\w+`, so a `<<~'RUBY'` was
  # invisible to the counter AND to the scanner — and a planted `$500` inside
  # one passed all three tests. A coverage check that cannot see a script is
  # not coverage, it is decoration.
  ANY_HEREDOC_OPENER = /<<[-~]?(['"]?)\w+\1/
  EXPECTED_OPENER = "<<~RUBY"

  def heredoc_openers
    DRIVER.read.to_enum(:scan, ANY_HEREDOC_OPENER).map { Regexp.last_match(0) }
  end

  # A scan that matched nothing would pass every assertion below while
  # examining an empty list. Assert the input reached the scanner first — the
  # driver has one script per remote step, so a handful is the floor.
  # A FLOOR IS NOT COVERAGE. This was `>= 7`, and it passed at 8-of-9 while a
  # whole script went unexamined — the floor cannot tell "the driver has fewer
  # scripts" from "the scanner sees fewer scripts". Equality against the openers
  # can: every heredoc in the file must be one this test actually read.
  # RATHER THAN PARSE EVERY SPELLING, REFUSE THE ONES WE DO NOT READ.
  #
  # Chasing Ruby's heredoc grammar in a regex is how the last two versions of
  # this file were defeated. The driver only ever needs one form, so requiring
  # it turns "the scanner might not see this" into a failing test naming the
  # line. A new spelling is then a deliberate decision with a red test attached,
  # not a silent hole.
  test "every heredoc in the driver uses the one form the scanner reads" do
    exotic = heredoc_openers.reject { |opener| opener == EXPECTED_OPENER }

    assert_empty exotic,
                 "these heredoc openers are not #{EXPECTED_OPENER}: #{exotic.uniq.join(', ')}. " \
                 "The scanner below reads only #{EXPECTED_OPENER}, so anything else is a script " \
                 "no guard in this file examines. Use #{EXPECTED_OPENER}, or teach the scanner first."
  end

  test "the scanner reads EVERY heredoc in the driver, not merely several" do
    assert_operator heredoc_openers.size, :>=, 7,
                    "expected several heredocs in #{DRIVER}, found #{heredoc_openers.size} — " \
                    "either the driver changed shape or the opener pattern has drifted"

    assert_equal heredoc_openers.size, remote_scripts.size,
                 "#{heredoc_openers.size} heredoc(s) open in #{DRIVER} but the scanner read " \
                 "#{remote_scripts.size}. The unread one is not being checked by anything here."
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
