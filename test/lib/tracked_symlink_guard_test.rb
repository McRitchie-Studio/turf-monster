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

  # Reading the pattern proves what the file SAYS. This proves what git DOES
  # with it, against a real symlink at the real path — the one shape the old
  # pattern let through. Without this the test above is a string comparison
  # that could pass while the pattern still failed to cover a link.
  def test_git_actually_ignores_a_symlink_at_node_modules
    with_symlink_at_node_modules do
      out, _err, status = git("check-ignore", "-v", "node_modules")

      assert status.success?,
             "git does not ignore a SYMLINK at node_modules — a routine `git add -A` " \
             "would stage it, which is the exact defect this file guards"
      assert_match(/node_modules/, out)
    end
  end

  # The end of the causal chain, and the sharpest statement of the fix: with a
  # symlink sitting there, git must not offer it as something to add.
  def test_a_symlink_at_node_modules_is_not_offered_as_untracked
    with_symlink_at_node_modules do
      out, = git("status", "--porcelain", "--untracked-files=all")
      # `??` only: the question is whether git OFFERS the symlink as something
      # to add. Any other status (a staged deletion, say) is a different fact.
      listed = out.lines.map(&:strip).select { |l| l.start_with?("??") && l.include?("node_modules") }

      assert_empty listed,
                   "git status still offers node_modules: #{listed.join(', ')}. " \
                   "That is how it got committed — nobody typed the path, `git add -A` took it."
    end
  end

  private

  # NEVER SKIPS, and that is deliberate. The first draft of this helper stood
  # down whenever anything existed at the path — which meant that in the exact
  # buggy state it was written to catch (a symlink sitting there), both boundary
  # tests went SILENT. A skip is neither a pass nor a fail, so the guard was
  # blindest precisely when it mattered. Each case now has an answer:
  #
  #   * a SYMLINK here IS the defect — fail, and say what it points at;
  #   * a real installed DIRECTORY is the healthy state — leave it alone and ask
  #     git the same question against it, which is still meaningful because the
  #     pattern must cover a directory too;
  #   * nothing here — plant a probe link and clean it up.
  def with_symlink_at_node_modules
    path = File.join(ROOT, "node_modules")

    if File.symlink?(path)
      flunk "node_modules is a SYMLINK here (-> #{File.readlink(path)}). That is the " \
            "defect this file guards — a dependency tree is never a link in this repo."
    end

    return yield if File.directory?(path)

    File.symlink("/nonexistent/probe-target", path)
    begin
      yield
    ensure
      File.delete(path) if File.symlink?(path)
    end
  end
end
