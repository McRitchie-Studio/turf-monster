# frozen_string_literal: true

require "test_helper"
require "rake"
require "rails/test_unit/runner"
require "rails/commands/test/test_command"
require "minitest/mock"

# Guard for the BUILD MECHANISM that .github/workflows/ci.yml documents around its
# "Build Tailwind CSS for the suite" and "Run tests" steps.
#
# WHY A COMMENT NEEDED A TEST. That comment used to assert the opposite of the
# truth: that `bin/rails db:test:prepare test` does NOT fire Rails' `test:prepare`
# hook (the one tailwindcss-rails enhances with `tailwindcss:build`). It backed the
# assertion with a receipt for `bin/rails db:test:prepare` — the BARE form, a
# different command. It measured one cell and concluded about another, and because
# both cells share a prefix the mistake was invisible on the page. Grepping the
# sentence could never have caught it; only executing the mechanism can. So the
# mechanism is spelled out here as assertions, and the comment now points at this
# file instead of at a prose receipt.
#
# THE CHAIN, one assertion per link. `bin/rails db:test:prepare test`:
#   1. `db:test:prepare` is not a rails COMMAND, so the whole line routes through
#      RAKE and every token becomes a rake task. (Asserted in
#      test/lib/ci_workflow_triggers_test.rb, which owns the line's shape.)
#   2. rake's `test` task carries NO prerequisites — so the hook is NOT reached the
#      way a reader expects. This is the true half of the old comment, and the half
#      that made the false conclusion look sound.
#   3. Its BODY is `Rails::TestUnit::Runner.run_from_rake`, which is
#      `system("rails", "test", *argv)` — it SHELLS OUT to the argless `rails test`
#      COMMAND. That is the link the old comment missed.
#   4. `Rails::Command::TestCommand#perform` calls `run_prepare_task` — and so
#      invokes `test:prepare` — whenever no argument looks like a path or `-n`.
#   5. tailwindcss-rails enhances `test:prepare` (NOT `db:test:prepare`) with
#      `tailwindcss:build`.
# So the hook fires, the stylesheet is built, and the old comment was wrong.
#
# WHAT THIS FILE DOES NOT COVER, stated plainly rather than implied. It does not
# spawn `bin/rails db:test:prepare test` and watch the file appear — that is a
# recursive full-suite spawn, and no unit test should pay for one. The end-to-end
# observation is a CI receipt instead, quoted in ci.yml: on ubuntu-latest the
# stylesheet reappeared 7s into the run, while the suite was still booting. What is
# asserted here is every link that receipt depends on, so a gem upgrade that breaks
# the chain reddens here rather than silently deleting the hook and leaving the
# comment lying again.
#
# Run directly:
#   bin/rails test test/lib/tailwind_test_prepare_hook_test.rb
class TailwindTestPrepareHookTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tailwindcss:build")
  end

  # LINK 5 — the asymmetry that makes the two cells differ at all.
  #
  # tailwindcss-rails' build.rake picks ONE task to enhance, by an if/elsif chain:
  # `test:prepare`, else `spec:prepare`, else `db:test:prepare`. railties always
  # defines `test:prepare`, so the first branch always wins here and
  # `db:test:prepare` is never enhanced. That is the whole reason the bare
  # `bin/rails db:test:prepare` leaves the stylesheet absent while the line that
  # also names `test` does not.
  test "[component] tailwindcss:build hangs off test:prepare and NOT off db:test:prepare" do
    assert_includes Rake::Task["test:prepare"].prerequisites, "tailwindcss:build",
                    "tailwindcss-rails no longer enhances Rails' test:prepare hook, so the " \
                    "suite line no longer builds the stylesheet on its own. ci.yml's explicit " \
                    "`bin/rails tailwindcss:build` step is now the ONLY thing producing it."

    refute_includes Rake::Task["db:test:prepare"].prerequisites, "tailwindcss:build",
                    "db:test:prepare now builds the stylesheet too, so the bare form and the " \
                    "suite form no longer differ — ci.yml's comment describes an asymmetry " \
                    "that has stopped existing."
  end

  # LINKS 2 + 3 — the step the original comment reasoned past.
  #
  # Reading only the prerequisite list, rake's `test` task looks like a dead end:
  # it depends on nothing, so nothing invokes `test:prepare` through the graph.
  # True — and irrelevant, because the task's BODY shells out to the rails command
  # that does. Both halves are asserted together so the pair cannot drift apart.
  test "[component] rake's test task reaches the hook by SPAWNING the argless rails command" do
    assert_empty Rake::Task["test"].prerequisites,
                 "rake's `test` task grew a prerequisite. The mechanism ci.yml documents " \
                 "(no prerequisite, but a shell-out in the body) is out of date."

    spawned = nil
    Rails::TestUnit::Runner.stub(:system, ->(*args) { spawned = args; true }) do
      Rails::TestUnit::Runner.run_from_rake("test", [])
    end

    assert_equal %w[rails test], spawned,
                 "rake's `test` task no longer spawns an argless `rails test`. That spawn is " \
                 "the only route from the rake-routed CI line to Rails' test:prepare hook."
  end

  # LINK 4 — and the reason the explicit build step STAYS.
  #
  # TestCommand only runs the prepare task when nothing in argv looks like a path
  # or a `-n` filter. `run_from_rake` forwards `ENV["TEST"]` and `ENV["TESTOPTS"]`
  # into that argv, so adding either to the CI line silences the hook without
  # changing a visible word of the command. Measured on ubuntu-latest: with
  # `TEST=test/lib/ci_job_timeout_test.rb` set, the same line left the stylesheet
  # absent. The explicit build step is what survives that edit.
  test "[component] a path or -n argument suppresses the prepare task the hook rides on" do
    pattern = Rails::Command::TestCommand.const_get(:EXACT_TEST_ARGUMENT_PATTERN)

    refute [].any? { |arg| arg.match?(pattern) },
           "an argless `rails test` must reach run_prepare_task — that is what builds the CSS"

    assert ["test/lib/ci_job_timeout_test.rb"].any? { |arg| arg.match?(pattern) },
           "a path argument must suppress run_prepare_task; if it stopped doing so, ci.yml's " \
           "rationale for keeping the explicit build step needs rewriting"

    assert ["-n", "/some_test/"].any? { |arg| arg.match?(pattern) },
           "a -n filter must suppress run_prepare_task, for the same reason"
  end
end
