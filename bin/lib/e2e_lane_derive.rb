# frozen_string_literal: true

require "yaml"

# E2eLaneDerive — derive config/e2e_lane.yml's spec counter from the tree instead
# of incrementing it by hand.
#
# WHY THIS EXISTS. `total_specs` is a DERIVABLE number that was maintained by
# hand, and two branches that each add a spec both write the same new value for
# DIFFERENT files. Identical text merges with NO conflict, so the counter lands
# silently under-declared and the next PR pays for it. That happened FOUR TIMES
# in one day (wallet-session-signer-reflex vs adopt-birthday-age-gate-flow;
# make-logout-definitive; guard-debug-net-logging twice — the second time because
# a number that was CORRECT when the reviewer derived it went stale before the
# merge actually ran).
#
# WHAT THIS DOES NOT DO. It does not weaken the runtime gate. `bin/e2e-executed-
# set-check` still compares specs EXECUTED (from Playwright's own receipts)
# against the contract, which is the only question that catches a runtime skip, a
# widened --grep-invert, or a dropped shard. This file only keeps the DECLARED
# side of that comparison honest, and it keeps it as a PIN rather than deriving it
# at gate time on purpose: a derived-only bar would silently drop when specs are
# DELETED, which is exactly the coverage loss the pin is there to catch.
module E2eLaneDerive
  CONTRACT = "config/e2e_lane.yml"
  LIST_COMMAND = %w[npx playwright test --list].freeze

  # The SAME lister, narrowed to the excluded tag. `excluded` is as derivable as
  # `total_specs` is, and leaving it hand-declared was the one axis where --write
  # could write a confidently WRONG number that the new gate then certified GREEN:
  # add one @devnet spec and the tree total goes 203 -> 204 while TRUE excluded goes
  # 17 -> 18 and TRUE executed stays 182 — but a deriver trusting the old 17 writes
  # executed 183. e2e_declared_set passes; the lane then executes 182; and
  # e2e_executed_set fails 30-45 minutes later wearing its "specs LEFT the lane"
  # diagnosis, pointing the next builder at a widened --grep-invert that never
  # happened. Derived here, that case is caught before the push.
  #
  # allowed_skips stays HAND-DECLARED on purpose — it is a real judgment call about
  # which skips are tolerated, not a fact about the tree.
  EXCLUDED_LIST_COMMAND = %w[npx playwright test --list --grep @devnet].freeze

  # THE LISTER BINARY, RESOLVED AGAINST THE TREE BEING DERIVED.
  #
  # `npx playwright` is the documented invocation and stays the fallback, but it
  # can die SILENTLY. Measured 2026-09-15 on this machine: `npx playwright
  # --version` exits 194 printing nothing on stdout OR stderr, while
  # `./node_modules/.bin/playwright --version` answers "Version 1.58.2" and
  # exits 0. The failure is npx's own resolution step, not this repo's config —
  # so it is not worktree-specific, and a checkout with a working npx is
  # unaffected either way.
  #
  # THAT SILENCE IS THE WHOLE PROBLEM. This script fails closed, so an unusable
  # lister is correctly a hard stop — but the message it prints ("cannot derive")
  # names no cause, and the next person, holding a real spec count and a contract
  # that must change, is one step from incrementing the scalar by hand. That is
  # the single thing config/e2e_lane.yml's own history says never to do: three
  # branches have already written the same total for DIFFERENT specs, because the
  # scalar auto-merges and arithmetic cannot see a sibling's additions.
  #
  # So: prefer the binary that is actually installed in the tree, and keep npx for
  # a checkout that has no node_modules. This changes no counting and no verdict —
  # only which executable is asked the same question.
  #
  # IT IS NOT A SUBSTITUTE FOR AN INSTALL. A fresh worktree has no node_modules
  # at all, and the PRIMARY checkout's node_modules cannot be borrowed to cover
  # for it: it is a symlink pointing AT ITSELF, so every path through it fails
  # "Too many levels of symbolic links". The durable fix for a desk that needs
  # the lane is `npm ci` in that desk. This resolver only makes sure that once an
  # install EXISTS, a broken npx cannot hide it.
  def self.playwright_bin(root)
    local = File.join(root.to_s, "node_modules", ".bin", "playwright")
    File.executable?(local) ? [local] : %w[npx playwright]
  end

  def self.list_command(root)
    playwright_bin(root) + %w[test --list]
  end

  def self.excluded_list_command(root)
    playwright_bin(root) + %w[test --list --grep @devnet]
  end

  # Playwright's final line: "Total: 200 tests in 54 files".
  TOTAL_LINE = /^\s*Total:\s+(\d+)\s+tests?\s+in\s+(\d+)\s+files?/

  module_function

  def parse_total(output)
    match = output.to_s.lines.reverse.filter_map { |l| l.match(TOTAL_LINE) }.first
    return nil unless match

    { specs: Integer(match[1]), files: Integer(match[2]) }
  end

  # executed == total_specs − excluded − allowed_skips. Kept in one place so the
  # deriver and the gate cannot drift apart in their arithmetic.
  def expected_executed(total_specs, excluded, allowed_skips)
    total_specs - excluded - allowed_skips
  end

  # Rewrite ONLY the two derived scalars, in place, by line. A YAML round-trip
  # would reformat the file and discard its comments — and this file is mostly
  # comments, each one the record of a coverage decision.
  def rewrite(content, total_specs:, executed:, excluded: nil)
    out = content.sub(/^total_specs:[ \t]*\d+/, "total_specs: #{total_specs}")
    out = out.sub(/^excluded:[ \t]*\d+/, "excluded: #{excluded}") if excluded
    out.sub(/^executed:[ \t]*\d+/, "executed: #{executed}")
  end

  # `listed_excluded` is nil only when the caller could not run the exclusion
  # lister; the contract's value is then used, and the caller says so. Every live
  # path passes it.
  def derived_for(contract, listed_specs, listed_excluded = nil)
    excluded = listed_excluded || contract.fetch("excluded")
    allowed = contract.fetch("allowed_skips")
    { total_specs: listed_specs,
      excluded: excluded,
      executed: expected_executed(listed_specs, excluded, allowed) }
  end

  # [] when the file already agrees with the tree; otherwise the loud message.
  def disagreements(contract, derived)
    problems = []
    if contract.fetch("total_specs") != derived[:total_specs]
      problems << "total_specs: #{CONTRACT} says #{contract.fetch("total_specs")}, " \
                  "the tree has #{derived[:total_specs]}"
    end
    if derived[:excluded] && contract.fetch("excluded") != derived[:excluded]
      problems << "excluded: #{CONTRACT} says #{contract.fetch("excluded")}, " \
                  "the tree has #{derived[:excluded]} tagged specs"
    end
    if contract.fetch("executed") != derived[:executed]
      problems << "executed: #{CONTRACT} says #{contract.fetch("executed")}, " \
                  "the arithmetic gives #{derived[:executed]} " \
                  "(#{derived[:total_specs]} committed − #{derived[:excluded] || contract.fetch("excluded")} " \
                  "excluded − #{contract.fetch("allowed_skips")} allowed)"
    end
    problems
  end
end
