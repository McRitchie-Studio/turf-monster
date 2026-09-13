# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# THE READ FORM IS LOAD-BEARING, AND NOTHING PINNED IT (mutant M10,
# /tasks/pin-config-read-form). Carl swapped the reader to `heroku config:get`
# during review of PR #624 and the whole suite stayed green.
#
# `config --json` answers PRESENCE and VALUE together, and FAILS the command when
# the read is unauthorised. `config:get` prints a bare newline and exits 0 for an
# ABSENT key, a PRESENT-BUT-EMPTY one, and an UNAUTHENTICATED read alike — three
# states flattened into one blank. docs/SOLANA.md bans it for that reason, and the
# guard's correctness rests on telling them apart: two blanks compare EQUAL and two
# unknowns compare UNEQUAL, so either naive comparison answers confidently and
# wrongly.
#
# PINNED BY BEHAVIOUR, NOT BY A GREP. A test that greps the source for
# "config --json" passes on any string that merely contains it. These tests drive
# the DEFAULT reader — the one that really shells out, which is the code M10
# mutates — against a stub `heroku` that answers BOTH forms the way the real CLI
# does. A reader that cannot separate the three states then fails here.
#
# The sibling file (signing_key_isolation_test.rb) drives the verdict engine
# through an injected `runner:`, which by construction never exercises the argv.
# That is why it could not catch this, and why this file does not replace it.
class SigningKeyIsolationReadFormTest < ActiveSupport::TestCase
  Guard = TurfMonster::SigningKeyIsolation
  VARIABLE = Guard::VARIABLE

  # `state` shapes only the `config --json` answer. `config:get` is a bare newline
  # and exit 0 in EVERY state — faithful to the real CLI, so a mutant that switches
  # form is handed exactly what Heroku would hand it, not a rigged refusal.
  def with_stub_heroku(state)
    Dir.mktmpdir do |dir|
      script = File.join(dir, "heroku")
      File.write(script, <<~SH)
        #!/bin/sh
        case "$1" in
          config:get) printf '\\n' ; exit 0 ;;
        esac
        if [ "$1" != "config" ] || [ "$2" != "--json" ]; then
          echo "stub heroku: unexpected invocation: $*" >&2 ; exit 64
        fi
        case "#{state}" in
          absent)  printf '{}' ; exit 0 ;;
          empty)   printf '{"#{VARIABLE}":""}' ; exit 0 ;;
          unauth)  echo "Error: not logged in" >&2 ; exit 100 ;;
          nothing) exit 0 ;;
        esac
      SH
      File.chmod(0o755, script)
      original = ENV["PATH"]
      ENV["PATH"] = "#{dir}#{File::PATH_SEPARATOR}#{original}"
      begin
        yield Guard.probe # the DEFAULT HerokuReader: the argv M10 mutates
      ensure
        ENV["PATH"] = original
      end
    end
  end

  def states(probe) = [probe.production.state, probe.qa.state]

  test "[unit] an absent key reads as MISSING on both apps and refuses" do
    with_stub_heroku("absent") do |probe|
      assert_equal %i[missing missing], states(probe)
      assert_equal :indeterminate, probe.verdict, "absence is never isolation"
    end
  end

  test "[unit] a present-but-EMPTY key is told apart from an absent one" do
    with_stub_heroku("empty") do |probe|
      assert_equal %i[empty empty], states(probe),
                   "the key IS present with an empty value — `config:get` cannot say this"
      assert_equal :indeterminate, probe.verdict, "two blanks compare EQUAL; refusing is the honest answer"
    end
  end

  test "[unit] an unauthenticated read FAILS the command rather than returning a blank" do
    with_stub_heroku("unauth") do |probe|
      assert_equal %i[unreadable unreadable], states(probe),
                   "`config --json` exits non-zero when it cannot read; a blank would be indistinguishable"
      assert_equal :indeterminate, probe.verdict
      refute probe.production.readable?, "an unauthorised read must not count as a successful look"
    end
  end

  # THE ASSERTION THAT KILLS M10. Whatever the verdict, the three states must remain
  # THREE. A `config:get` reader collapses them into one blank and this goes red.
  test "[unit] the three blank-looking states stay distinguishable" do
    seen = %w[absent empty unauth].map do |state|
      with_stub_heroku(state) { |probe| probe.production.state }
    end

    assert_equal %i[missing empty unreadable], seen,
                 "the read form collapsed distinct states — `heroku config:get` prints a bare newline and " \
                 "exits 0 for all three, which is why docs/SOLANA.md bans it here"
    assert_equal 3, seen.uniq.size
  end

  # NON-VACUITY. A stub that answers NOTHING AT ALL (exit 0, no output) must not be
  # read as an absent key: without this, a harness whose payloads never reached the
  # reader could still satisfy every assertion above.
  test "[control] a stub that returns nothing reads as UNREADABLE, never as absent" do
    with_stub_heroku("nothing") do |probe|
      assert_equal :unreadable, probe.production.state,
                   "an empty payload is a failed read, not a key that is absent"
      refute_equal :missing, probe.production.state
      assert_equal :indeterminate, probe.verdict
    end
  end
end
