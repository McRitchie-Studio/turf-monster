# frozen_string_literal: true

require "test_helper"

# [unit] The Devnet Nightly workflow never ran on schedule (161 of 162 runs
# skipped) and was deleted on 2026-10-24 (task turf-devnet-config-truth). The
# devnet signal is the per-release contest-rehearsal gauntlet against QA
# (docs/qa-contest-rehearsal.md). This repo keeps no archive, so the history
# stays where it helps, but every line that names the workflow must say it was
# deleted: a line that names it bare reads as a lane that runs.
class DevnetNightlyRetiredGuardTest < ActiveSupport::TestCase
  ROOTS = %w[docs app lib bin .github config test e2e].freeze
  SELF = File.expand_path(__FILE__)
  RETIRED = /devnet[\s_-]nightly|DEVNET_NIGHTLY_ENABLED/i
  SAYS_DELETED = /\bdeleted\b/i
  # The task that swept the references is named for the workflow.
  TASK_SLUG = "devnet-nightly-reference-sweep"

  def scanned_files
    roots = ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, "**", "*")) } + Dir.glob(Rails.root.join("*.md"))
    roots.select { |p| File.file?(p) }.reject { |p| File.expand_path(p) == SELF || p.include?("/node_modules/") }
  end

  def live_mention?(line)
    text = line.gsub(TASK_SLUG, "")
    text.match?(RETIRED) && !text.match?(SAYS_DELETED)
  end

  test "every line that names the deleted Devnet Nightly workflow says it was deleted" do
    files = scanned_files
    assert_operator files.size, :>=, 500, "the scan read too few files to be the real tree"

    found = files.flat_map do |path|
      text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
      text.each_line.with_index(1).filter_map do |line, n|
        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{n}" if live_mention?(line)
      end
    end
    assert_empty found, "these lines name the Devnet Nightly workflow as if it ran. Say it was deleted " \
                        "(2026-10-24), or name the devnet signal: the per-release contest-rehearsal"
  end

  test "the scan bites a bare mention and spares a deleted one and the task slug" do
    ["the Devnet Nightly workflow runs the @devnet specs", "see devnet-nightly.yml",
     "set vars.DEVNET_NIGHTLY_ENABLED"].each do |probe|
      assert live_mention?(probe), "the scan missed #{probe.inspect}"
    end
    refute live_mention?("Devnet Nightly was deleted on 2026-10-24")
    refute live_mention?("task #{TASK_SLUG} swept the references")
  end
end
