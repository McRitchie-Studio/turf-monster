# frozen_string_literal: true

# E2eRacePatterns — THE LINT THAT BANS THE TWO RACE SHAPES IN e2e/.
#
# WHY. Alex McRitchie, 2026-11-06: "Flaky is a terrible way to describe a system." Two
# spellings write a race into a browser spec by construction:
#
#   SLEEP  — `page.waitForTimeout(ms)`. A fixed sleep guesses how long the page needs.
#            Under load the guess is short and the spec goes red; idle, it is wasted
#            time. Wait on the state instead: `expect(locator)…`, `expect.poll`,
#            `page.waitForResponse`, or Playwright's clock for a timer.
#   BRANCH — `if (await x.isVisible())`, `x.isVisible().catch(() => false)`. A snapshot
#            of visibility taken once, at an instant the page does not promise. The
#            dialog it checks can open a frame later and swallow the next click
#            (build_funnel.spec.js, task deterministic-ci). Make the state
#            deterministic in the seed, then assert it.
#
# THE RATCHET. Files that held these before the lint keep a per-file ceiling in
# config/e2e_race_patterns.yml. A ceiling may only fall, and must equal the file's count
# (remove one, lower it in the same commit); a file absent from the list holds none.
# Guard: test/lib/e2e_race_patterns_test.rb.
module E2eRacePatterns
  PATTERNS = {
    "sleep" => /\bwaitForTimeout\s*\(/,
    "branch" => /\.(?:isVisible|isHidden)\([^)]*\)\s*\.catch\(|\bif\s*\(\s*!?\s*\(?\s*await\s+[^;{]*?\.(?:isVisible|isHidden)\(/
  }.freeze

  module_function

  # PURE. Source text → { "sleep" => n, "branch" => n }. Line comments are skipped, so a
  # comment that names the banned call does not count.
  def counts(source)
    code = source.to_s.each_line.reject { |l| l.lstrip.start_with?("//", "*") }.join
    PATTERNS.transform_values { |re| code.scan(re).size }
  end

  # { "e2e/x.spec.js" => { "sleep" => n, "branch" => n } } for every JS file under dir
  # holding at least one.
  def scan(root, dir: "e2e")
    Dir[File.join(root, dir, "**", "*.js")].sort.each_with_object({}) do |path, out|
      c = counts(File.read(path))
      out[path.delete_prefix("#{root}/")] = c if c.values.sum.positive?
    end
  end

  # PURE. actual scan vs ceilings → list of violations (strings).
  def violations(actual, ceilings, released: nil)
    out = []
    (actual.keys | ceilings.keys).sort.each do |file|
      PATTERNS.each_key do |kind|
        have = actual.dig(file, kind).to_i
        cap = ceilings.dig(file, kind).to_i
        if have > cap
          out << "#{file}: #{have} #{kind}(s), ceiling #{cap} — wait on the state instead (bin/lib/e2e_race_patterns.rb)"
        elsif have < cap
          out << "#{file}: #{have} #{kind}(s) but the ceiling says #{cap} — lower config/e2e_race_patterns.yml to #{have}"
        end
        next unless released

        was = released.dig(file, kind).to_i
        out << "#{file}: the #{kind} ceiling rose from #{was} to #{cap}; it may only fall" if cap > was
      end
    end
    out
  end
end
