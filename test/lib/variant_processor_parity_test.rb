# frozen_string_literal: true

require "test_helper"
require "yaml"

# [unit] The app's image processor and CI's installed image stack must be the
# same one, in every lane that renders a variant.
#
# WHY THIS EXISTS. These two facts live in different files, are edited by
# different people for different reasons, and neither one fails when the other
# moves. config/application.rb pins :mini_magick because libvips is absent from
# every machine this app RUNS on — measured 2026-09-08 on turf-monster-mainnet
# (heroku-26), turf-monster-qa (heroku-24) and the dev Mac, all of which carry
# /usr/bin/magick and no vips. CI, meanwhile, installed libvips and NOT
# ImageMagick, which is the reverse stack.
#
# WHAT THAT COMBINATION COSTS. Not a red lane — a lane that cannot be red. Had
# the pin been left at the Rails 8.1 default of :vips, CI would have rendered
# every variant through a processor production does not have, gone green, and
# said nothing about the code that ships. It surfaced here only because the pin
# came first and CI answered `executable not found: "convert"`.
#
# ASSERTED AGAINST PARSED YAML, NOT THE FILE'S TEXT. The workflow's own comments
# say "imagemagick" several times, so a grep over the raw file passes on prose
# alone. Only a step's `run:` command installs anything.
class VariantProcessorParityTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/ci.yml")
  # Every CI job that renders an Active Storage variant: `test` runs the suite,
  # `playwright` boots the app and e2e/og_image.spec.js fetches a composed card.
  RENDERING_JOBS = %w[test playwright].freeze

  def run_commands(job)
    steps = YAML.safe_load_file(WORKFLOW, aliases: true).dig("jobs", job, "steps")
    assert steps.present?, "CI job #{job.inspect} has no steps — did the job get renamed?"
    steps.filter_map { |step| step["run"] }
  end

  test "the app renders variants with mini_magick" do
    # Rails 8.1 defaults this to :vips. The default is wrong for every machine
    # this app runs on, so it is pinned — and the pin is what the CI packages
    # below have to match.
    assert_equal :mini_magick, ActiveStorage.variant_processor
  end

  test "every CI job that renders a variant installs ImageMagick" do
    RENDERING_JOBS.each do |job|
      assert run_commands(job).any? { |cmd| cmd.match?(/\bimagemagick\b/) },
             "CI job #{job.inspect} renders Active Storage variants but installs no imagemagick — " \
             "variants there die with `executable not found: \"convert\"`"
    end
  end
end
