# frozen_string_literal: true

require "test_helper"

# Dependency updates are reactive, not scheduled (Alex McRitchie's ruling,
# 2026-11-10, task ci-runs-reactive-and-once). A scheduled Dependabot config
# opened version-update PRs nobody had asked for, and every one of them spent a
# CI run. A bump now starts from the `dependency-update` SOP
# (mcritchie-studio/docs/agents/modules/dependency-update.md): a security
# advisory, a red bundler-audit, a builder who needs a newer gem, or drift
# reported at release.
#
# Dependabot SECURITY updates are a repository setting, not this file, so they
# do not need it. Bringing the file back is a deliberate act that deletes this test.
class ScheduledDependabotOffTest < ActiveSupport::TestCase
  test "[unit] no scheduled Dependabot version updates" do
    path = Rails.root.join(".github", "dependabot.yml")
    assert_not File.exist?(path),
      "#{path} exists. Scheduled version updates are off by ruling (task " \
      "ci-runs-reactive-and-once); run the dependency-update SOP instead, or delete " \
      "this test on purpose"
  end
end
