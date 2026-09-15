# frozen_string_literal: true

# GUARD AGAINST COMMITTING A SYMLINK — and specifically against re-committing
# node_modules, which this repo did for two days without a single test going red.
#
# WHAT HAPPENED. da74fbc5 ("zap: re-measure the two line counts #690's merge
# moved") staged a `node_modules` SYMLINK (git mode 120000) whose content was the
# absolute path /Users/alex/projects/turf-monster/node_modules — the path of the
# symlink itself. It shipped to main and accepted, so every worktree desk git
# created afterwards checked out that self-referential link, and
# `require.resolve("playwright")` threw on all of them. The local e2e lane was
# dead on every desk for two days.
#
# WHY NOTHING CAUGHT IT. CI installs its own node_modules, so CI stayed green.
# The failure was local-only and looked exactly like a broken personal setup,
# which is why several builders worked around it individually instead of
# reporting a repo defect.
#
# IT WAS WORSE THAN A MISSING PACKAGE, and this is the part the workarounds
# missed. `npm exec` (so `npx`) walks every PARENT directory's node_modules/.bin
# to build the child's PATH. Worktree desks live UNDER the primary checkout, so
# that walk always reached the primary's own self-referential node_modules and
# spawn died with ELOOP (errno -62) — visible only in ~/.npm/_logs, because npx
# printed NOTHING and exited 194. So `npx playwright test --list` and
# bin/e2e-lane-derive failed on every desk INCLUDING desks that had installed
# their own node_modules correctly. No --reporter flag can work around an ELOOP
# at spawn; the advice in circulation to pass --reporter=json was treating the
# symptom. Measured 2026-09-15: with the primary's link moved aside and nothing
# else changed, bin/e2e-lane-derive went from "cannot derive" to GREEN (310
# specs in 74 files, 17 excluded, 289 executed).
#
# WHY .gitignore DID NOT STOP IT — the part worth reading twice. The file ALREADY
# said `node_modules/`, and that is precisely why it failed: a gitignore pattern
# with a TRAILING SLASH matches DIRECTORIES ONLY. A symlink is not a directory,
# so the pattern did not cover it and `git add -A` staged it without complaint.
# "Add node_modules to .gitignore" was therefore a no-op remedy; DROPPING THE
# SLASH is the fix. That distinction is invisible in a diff, so it is asserted
# here rather than left in a commit message.
#
# Run directly:
#   ruby -Itest test/lib/tracked_symlink_guard_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class TrackedSymlinkGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", ROOT, *args)
    [out, err, status]
  end

  # --- The index ------------------------------------------------------

  # The general rule, not just the one path that bit us. A tracked symlink
  # stores whatever string it points at; when that string is an absolute path
  # it is meaningless on any machine but the one that committed it.
  def test_no_tracked_path_is_a_symlink
    out, = git("ls-files", "-s")
    links = out.lines.select { |l| l.start_with?("120000") }.map { |l| l.split("\t", 2).last.strip }

    assert_empty links,
                 "these paths are committed as symlinks (mode 120000): #{links.join(', ')}. " \
                 "A symlink's content is a PATH, so committing one either breaks on another " \
                 "machine or points somewhere unintended on this one."
  end

  def test_node_modules_is_not_tracked
    out, = git("ls-files", "--", "node_modules")

    assert_empty out.strip,
                 "node_modules is in the index again — a dependency tree (or a link to one) " \
                 "is never committed here; CI and every desk install their own."
  end

  # The acceptance criterion in its own right: nothing committed should name a
  # path that exists on one laptop. Scoped to tracked TEXT, which is where such
  # a path can hide without being obvious.
  def test_no_tracked_file_content_is_an_absolute_machine_path
    out, = git("grep", "-I", "-l", "-e", "/Users/alex/projects", "--", ".",
               ":(exclude)docs/agents", ":(exclude)*.md", ":(exclude)test/lib/tracked_symlink_guard_test.rb")
    offenders = out.lines.map(&:strip).reject(&:empty?)

    assert_empty offenders,
                 "these tracked files embed an absolute path from one machine: " \
                 "#{offenders.join(', ')}"
  end

  # --- The ignore pattern ---------------------------------------------

  # THE MECHANISM, asserted directly. The text of the pattern is the whole
  # difference between a guard and a no-op.
  def test_the_node_modules_ignore_pattern_carries_no_trailing_slash
    patterns = File.readlines(File.join(ROOT, ".gitignore"), chomp: true)
                   .reject { |l| l.strip.start_with?("#") }
                   .select { |l| l.strip.delete_suffix("/") == "node_modules" }

    refute_empty patterns, ".gitignore no longer ignores node_modules at all"
    refute_includes patterns, "node_modules/",
                    "the trailing slash is back. It restricts the pattern to DIRECTORIES, " \
                    "which is exactly how a node_modules SYMLINK was staged into da74fbc5."
  end

  # --- The boundary (integration): ask git, do not infer ---------------

  # Reading the pattern proves what the file SAYS; this proves what git DOES
  # with it. `git check-ignore` answers from the PATHNAME, so it can be asked
  # about this repo without creating anything — and the trailing-slash
  # distinction survives that, which is the whole question here.
  def test_git_ignores_node_modules_in_this_repo
    _out, _err, status = git("check-ignore", "-q", "node_modules")

    assert status.success?,
           "git does not ignore node_modules in this repo — a routine `git add -A` " \
           "would stage whatever sits there, which is the defect this file guards"
  end

  # THE SHAPE THE OLD PATTERN LET THROUGH, proven against a real symlink on
  # disk — in a THROWAWAY repo seeded with this repo's own .gitignore.
  #
  # HERMETIC ON PURPOSE. The first version planted the probe at THIS repo's
  # root. It passed locally and failed in CI, because `bin/rails test` forks
  # parallel workers that share one checkout: one worker's probe became another
  # worker's "node_modules is a SYMLINK here" failure. A guard that mutates
  # shared state to make its point will eventually fail someone else's run.
  def test_git_ignores_a_symlink_at_node_modules
    in_probe_repo do |dir|
      File.symlink("/nonexistent/probe-target", File.join(dir, "node_modules"))

      _out, _err, status = probe_git(dir, "check-ignore", "-q", "node_modules")
      assert status.success?,
             "this repo's .gitignore does not cover a SYMLINK at node_modules. A " \
             "pattern ending in `/` matches directories only — that is how the " \
             "self-referential link reached main in da74fbc5."

      # The end of the causal chain: git must not offer it as something to add,
      # because nobody typed the path — `git add -A` took it.
      out, = probe_git(dir, "status", "--porcelain", "--untracked-files=all")
      listed = out.lines.map(&:strip).select { |l| l.include?("node_modules") }
      assert_empty listed, "git still offers node_modules as untracked: #{listed.join(', ')}"
    end
  end

  private

  # A throwaway git repo carrying THIS repo's real .gitignore. Seeding it from
  # the actual file is what keeps the probe honest: it asks git about the
  # pattern this repo ships, not about a copy written into the test.
  def in_probe_repo
    Dir.mktmpdir("node-modules-ignore-probe") do |dir|
      probe_git(dir, "init", "-q", ".")
      FileUtils.cp(File.join(ROOT, ".gitignore"), File.join(dir, ".gitignore"))
      yield dir
    end
  end

  def probe_git(dir, *args)
    Open3.capture3("git", "-C", dir, *args)
  end
end
