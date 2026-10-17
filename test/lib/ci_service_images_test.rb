# frozen_string_literal: true

# Guard: every container image a workflow pulls comes from the hub's GitHub
# Container Registry mirror, pinned to the major production runs, and logs in with
# the run's own token.
#
# A bare or docker.io image resolves to Docker Hub, which meters anonymous pulls
# per IP. Hosted runners share IPs, so the quota fails jobs at "Initialize
# containers" with `toomanyrequests`. ECR Public, the mirror that replaced it, is
# metered too: it answered `toomanyrequests: Data limit exceeded` and blocked the
# release twice on 2026-10-17. So the lanes pull from ghcr.io/mcritchie-studio,
# which the hub's .github/workflows/mirror-ci-images.yml fills from the official
# images (the hub moved its own lanes there on 2026-10-10). The packages are
# public; the login still takes the pull off any anonymous quota.
#
# Run directly:
#   ruby -Itest test/lib/ci_service_images_test.rb
require "minitest/autorun"
require "yaml"

class CiServiceImagesTest < Minitest::Test
  WORKFLOWS = Dir[File.expand_path("../../.github/workflows/*.{yml,yaml}", __dir__)].sort.freeze
  MIRROR = "ghcr.io/mcritchie-studio/"
  # Majors read from production: `heroku pg:info` and `heroku redis:info`.
  PINS = {
    "postgres" => "#{MIRROR}postgres:17",
    "redis" => "#{MIRROR}redis:8"
  }.freeze

  # The login every service and job container carries: the run's own token.
  CREDENTIALS = { "username" => "${{ github.actor }}", "password" => "${{ github.token }}" }.freeze

  # [where, name, image] for every image a workflow pulls: service containers,
  # job containers in scalar and mapping form, and docker:// steps.
  def self.images(path)
    file = File.basename(path)
    jobs = YAML.safe_load_file(path, aliases: true).fetch("jobs")
    jobs.flat_map do |job, spec|
      found = (spec["services"] || {}).map { |name, service| ["#{file} #{job}.services.#{name}", name, image_of(service)] }
      found << ["#{file} #{job}.container", nil, image_of(spec["container"])] if spec.key?("container")
      Array(spec["steps"]).each_with_index do |step, index|
        uses = step["uses"].to_s
        found << ["#{file} #{job}.steps[#{index}]", nil, uses.delete_prefix("docker://")] if uses.start_with?("docker://")
      end
      found
    end
  end

  # [where, credentials] for every service and job container (a docker:// step
  # takes no credentials block, and the guard above already refuses one off-mirror).
  def self.logins(path)
    file = File.basename(path)
    YAML.safe_load_file(path, aliases: true).fetch("jobs").flat_map do |job, spec|
      found = (spec["services"] || {}).map { |name, service| ["#{file} #{job}.services.#{name}", service.is_a?(Hash) ? service["credentials"] : nil] }
      found << ["#{file} #{job}.container", spec["container"].is_a?(Hash) ? spec["container"]["credentials"] : nil] if spec.key?("container")
      found
    end
  end

  def self.image_of(node) = node.is_a?(Hash) ? node["image"].to_s : node.to_s

  def self.all_images = WORKFLOWS.flat_map { |path| images(path) }

  def test_every_image_is_the_pinned_mirror_image
    self.class.all_images.each do |where, name, image|
      repository = image.delete_prefix(MIRROR).split(":").first
      expected = PINS[name] || PINS[repository]
      assert expected, "#{where} pulls #{image.inspect}: not a pinned image; add its mirror name and production major to PINS"
      assert_equal expected, image, "#{where} pulls #{image.inspect}: name the mirror image pinned by major"
    end
  end

  def test_every_container_logs_in_to_ghcr_with_the_run_token
    logins = WORKFLOWS.flat_map { |path| self.class.logins(path) }
    refute_empty logins, "no service containers found; the guard reads nothing"
    logins.each do |where, credentials|
      assert_equal CREDENTIALS, credentials, "#{where} pulls without the run's ghcr.io login"
    end
  end

  # A workflow that pulls from the mirror declares its token's scopes, so the pull
  # never rests on the org's default token setting.
  def test_every_workflow_that_pulls_declares_packages_read
    WORKFLOWS.each do |path|
      next if self.class.images(path).empty?

      permissions = YAML.safe_load_file(path, aliases: true)["permissions"]
      assert_equal({ "contents" => "read", "packages" => "read" }, permissions,
                   "#{File.basename(path)} pulls ghcr.io images; declare top-level `permissions: { contents: read, packages: read }`")
    end
  end

  def test_no_workflow_narrows_the_token_below_packages_read
    WORKFLOWS.each do |path|
      doc = YAML.safe_load_file(path, aliases: true)
      scopes = [doc["permissions"], *doc.fetch("jobs").values.map { |spec| spec["permissions"] }].compact
      scopes.each do |permissions|
        next if permissions.is_a?(String) && %w[read-all write-all].include?(permissions)

        assert permissions.is_a?(Hash) && %w[read write].include?(permissions["packages"]),
               "#{File.basename(path)} sets permissions #{permissions.inspect} without `packages: read`; the ghcr.io login would fail"
      end
    end
  end

  def test_every_pin_is_a_mirror_image_with_a_numeric_major
    PINS.each_value { |image| assert_match(%r{\A#{Regexp.escape(MIRROR)}[a-z0-9-]+:\d+\z}, image) }
  end

  def test_control_the_guard_reads_every_workflow_and_each_pinned_service
    refute_empty WORKFLOWS, "no workflow files found; the guard reads nothing"
    WORKFLOWS.each do |path|
      raw = File.read(path).scan(/^\s*(?:image|container):[ \t]*\S/).size
      next if raw.zero?

      assert_operator self.class.images(path).size, :>=, raw, "#{File.basename(path)}: fewer images parsed than image lines in the file"
    end
    pulled = self.class.all_images.map(&:last)
    PINS.each_value { |image| assert_includes pulled, image, "no workflow pulls #{image}; the service moved and this guard must follow" }
  end
end
