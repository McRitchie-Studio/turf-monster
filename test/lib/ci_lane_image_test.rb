# frozen_string_literal: true

# Guard: NO CI STEP FETCHES FROM AN APT MIRROR. The jobs that need system packages
# (`test`, `playwright`) run inside the lane image, ghcr.io/mcritchie-studio/ci-rails:24.04
# (the hub's .github/ci-image/Dockerfile, built weekly by its mirror-ci-images.yml), as
# the hub's and the engine's lanes do. The apt mirror stall was the top red-then-green
# cause across the fleet (refactor-review-2026-11-06, lane-health 2f), and a red that a
# re-run turns green is a defect with a cause, not a retry (Alex McRitchie, 2026-11-06).
# Ported from mcritchie-studio's test/lib/ci_lane_image_test.rb (task deterministic-ci);
# Turf's half is turf-deterministic-ci. It replaced ci_apt_step_timeout_test.rb, whose
# apt-retry script no step calls any more.
require "minitest/autorun"
require "yaml"

class CiLaneImageTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOWS = Dir[File.join(ROOT, ".github/workflows/*.yml")].sort
  CI = File.join(ROOT, ".github/workflows/ci.yml")
  LANE_IMAGE = "ghcr.io/mcritchie-studio/ci-rails:24.04"
  IMAGE_LANES = %w[test playwright].freeze

  # A step that can fetch from apt: a direct apt/apt-get install or update (continuation
  # lines joined), apt-retry, and `playwright install --with-deps`, which runs apt-get.
  def self.apt_fetch?(run)
    r = run.to_s.gsub(/\\\n\s*/, " ")
    r.include?("--with-deps") || r.include?("apt-retry") ||
      r.match?(/\bapt(?:-get)?\b[^\n]*\b(?:install|update|upgrade|dist-upgrade)\b/)
  end

  def jobs(path) = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}

  def test_no_workflow_step_fetches_from_apt
    refute_empty WORKFLOWS
    offenders = WORKFLOWS.flat_map do |path|
      jobs(path).flat_map do |name, job|
        Array(job["steps"]).select { |step| self.class.apt_fetch?(step["run"]) }
                           .map { |step| "#{File.basename(path)} #{name}: #{step['name'] || step['run'].to_s[0, 60]}" }
      end
    end
    assert_empty offenders, "these steps fetch from an apt mirror; the package belongs in the hub's lane image"
  end

  def test_the_package_lanes_run_in_the_lane_image
    all = jobs(CI)
    IMAGE_LANES.each do |lane|
      container = all.fetch(lane).fetch("container") { flunk "#{lane} runs on the bare runner" }
      assert_equal LANE_IMAGE, container["image"], "#{lane} must run in the lane image"
      assert_equal "${{ github.token }}", container.dig("credentials", "password"), "#{lane} pulls ghcr.io with the run token"
      %w[--init --shm-size=2g --user\ 1001].each do |opt|
        assert_includes container["options"].to_s, opt, "#{lane} runs as close to the VM as a container gets"
      end
    end
  end

  def test_the_token_can_pull_the_image_and_nothing_more
    perms = (YAML.load_file(CI, aliases: true) || {})["permissions"]
    assert_equal({ "contents" => "read", "packages" => "read" }, perms)
  end

  # Inside a container job a service is reached by its label, and the
  # `github.workspace` expression names the HOST path, which the container cannot see.
  def test_container_lanes_reach_services_by_label_and_use_workspace_relative_paths
    IMAGE_LANES.each do |lane|
      text = jobs(CI).fetch(lane).to_yaml
      refute_match %r{@localhost|//localhost}, text, lane
      refute_includes text, "${{ github.workspace }}", lane
      assert_includes text, "postgres://postgres:postgres@postgres:5432", lane
    end
  end

  # The packages these lanes fetched with apt before the move are the image's job now.
  # A step proves the two the app cannot run without, before any test meets their absence.
  def test_each_lane_confirms_the_image_processors_before_it_runs
    IMAGE_LANES.each do |lane|
      runs = Array(jobs(CI).fetch(lane)["steps"]).map { |s| s["run"].to_s }
      assert(runs.any? { |r| r.include?("convert -version") && r.include?("libvips") },
             "#{lane} must confirm ImageMagick and libvips are in the image")
    end
  end

  def test_the_classifier_sees_each_apt_spelling
    assert self.class.apt_fetch?("sudo apt-get update")
    assert self.class.apt_fetch?("sudo apt-get install \\\n  -y ffmpeg")
    assert self.class.apt_fetch?("npx playwright install --with-deps chromium")
    assert self.class.apt_fetch?(".github/scripts/apt-retry imagemagick")
    refute self.class.apt_fetch?("npx playwright install chromium")
    refute self.class.apt_fetch?("dpkg-query -W libvips")
  end
end
