# frozen_string_literal: true

# [unit] The e2e race-pattern lint (bin/lib/e2e_race_patterns.rb): no fixed sleep
# (`waitForTimeout`) and no one-time visibility branch (`if (await x.isVisible())`,
# `x.isVisible().catch(...)`) in e2e/ beyond the per-file ceilings in
# config/e2e_race_patterns.yml, which may only fall. Task deterministic-ci.
require "minitest/autorun"
require "open3"
require "yaml"
require_relative "../../bin/lib/e2e_race_patterns"

class E2eRacePatternsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONFIG = "config/e2e_race_patterns.yml"
  # The released ceiling, once there, bounds the working tree's: a PR that raises a
  # ceiling to green its own sleep goes red here.
  BASELINE_REF = "origin/release"

  def ceilings = YAML.safe_load_file(File.join(ROOT, CONFIG)) || {}

  def released
    out, status = Open3.capture2e("git", "-C", ROOT, "show", "#{BASELINE_REF}:#{CONFIG}")
    status.success? ? (YAML.safe_load(out) || {}) : nil
  end

  def test_e2e_holds_no_race_pattern_beyond_its_ceiling
    assert_empty E2eRacePatterns.violations(E2eRacePatterns.scan(ROOT), ceilings, released: released)
  end

  def test_the_seed_specs_hold_none
    # The specs whose reds seeded the lint (task deterministic-ci) were fixed at the
    # cause; they may not regain a sleep or a branch.
    %w[e2e/video_recast.spec.js e2e/alex_voice_chat.spec.js e2e/build_launch_refusal.spec.js].each do |file|
      assert_nil ceilings[file], "#{file} was fixed at its cause; it holds no ceiling"
    end
    assert_nil ceilings.dig("e2e/build_funnel.spec.js", "branch")
  end

  def test_counts_each_banned_spelling
    src = <<~JS
      await page.waitForTimeout(300);
      if (await dialog.isVisible().catch(() => false)) {}
      if (await open.isVisible()) {}
      if (!(await toast.isHidden())) {}
      // page.waitForTimeout(1) in a comment does not count
      await expect(dialog).toBeVisible();
      const shown = await dialog.isVisible();
    JS
    assert_equal({ "sleep" => 1, "branch" => 3 }, E2eRacePatterns.counts(src))
  end

  def test_a_new_sleep_a_stale_ceiling_and_a_raised_ceiling_are_each_red
    actual = { "e2e/a.spec.js" => { "sleep" => 2, "branch" => 0 }, "e2e/new.spec.js" => { "sleep" => 1, "branch" => 0 } }
    caps = { "e2e/a.spec.js" => { "sleep" => 3 } }
    found = E2eRacePatterns.violations(actual, caps, released: { "e2e/a.spec.js" => { "sleep" => 2 } })
    assert(found.any? { |v| v.include?("e2e/new.spec.js: 1 sleep(s), ceiling 0") })
    assert(found.any? { |v| v.include?("lower config/e2e_race_patterns.yml to 2") })
    assert(found.any? { |v| v.include?("rose from 2 to 3") })
  end
end
