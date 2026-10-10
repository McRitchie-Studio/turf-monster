# frozen_string_literal: true

# Guard: every container image a workflow pulls comes from the ECR Public mirror,
# pinned to the major production runs.
#
# A bare or docker.io image resolves to Docker Hub, which meters anonymous pulls
# per IP. Hosted runners share IPs, so the quota fails jobs at "Initialize
# containers" with `toomanyrequests`. The mirror needs no credential. It is not
# unmetered: it throttles a burst by rate (`toomanyrequests: Rate exceeded`), and
# the runner's own pull retry absorbed one six seconds later on this guard's first
# run (38020971746, job `test`).
#
# Run directly:
#   ruby -Itest test/lib/ci_service_images_test.rb
require "minitest/autorun"
require "yaml"

class CiServiceImagesTest < Minitest::Test
  WORKFLOWS = Dir[File.expand_path("../../.github/workflows/*.{yml,yaml}", __dir__)].sort.freeze
  MIRROR = "public.ecr.aws/docker/library/"
  # Majors read from production: `heroku pg:info` and `heroku redis:info`.
  PINS = {
    "postgres" => "#{MIRROR}postgres:17",
    "redis" => "#{MIRROR}redis:8"
  }.freeze

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
