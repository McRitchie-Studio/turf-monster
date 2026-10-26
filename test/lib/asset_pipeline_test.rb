require "test_helper"
require "rake"

# Turf serves its assets through Propshaft (moved off Sprockets 2026-10-25,
# task turf-moves-to-propshaft; the recipe is rolio's docs/RUNBOOK.md, "Asset
# pipeline (Propshaft)"). This guard fails if Sprockets, or a piece of its
# configuration that Propshaft silently ignores, comes back.
#
# Why a guard and not just "the suite is green": every Sprockets-only knob is a
# NO-OP under Propshaft, not an error. A `//= link` manifest, a `*= require_tree`
# directive or `config.assets.precompile += …` boots fine and does nothing, so a
# stylesheet the directive used to pull in simply stops reaching the browser.
class AssetPipelineTest < ActiveSupport::TestCase
  ROOT = Rails.root

  test "the bundle carries propshaft and not sprockets" do
    gemfile = ROOT.join("Gemfile").read
    lock = ROOT.join("Gemfile.lock").read

    assert_match(/^gem "propshaft"/, gemfile)
    assert_match(/^    propshaft \(/, lock)
    refute_match(/^\s*gem "sprockets/, gemfile, "Gemfile names sprockets again")
    refute_match(/^\s+sprockets(-rails)? \(/, lock, "Gemfile.lock resolves sprockets again")
  end

  test "the running app's asset pipeline is propshaft" do
    assert_kind_of Propshaft::Assembly, Rails.application.assets
    refute defined?(::Sprockets), "Sprockets is loaded into the process"
  end

  test "no sprockets manifest or directive is left in app/assets" do
    refute ROOT.join("app/assets/config/manifest.js").exist?,
           "app/assets/config/manifest.js is Sprockets-only; Propshaft serves every file on the load path"

    directives = Dir[ROOT.join("app/assets/**/*.{css,js}")].select do |path|
      File.read(path).match?(%r{^\s*(\*=|//=)\s*(require|link)})
    end
    assert_empty directives.map { |p| Pathname(p).relative_path_from(ROOT).to_s },
                 "Sprockets directives are inert under Propshaft; link the file from the layout instead"
  end

  test "config sets no sprockets-only asset option" do
    sprockets_only = /config\.assets\.(precompile|compile|css_compressor|js_compressor|debug|digest|unknown_asset_fallback)\b/
    offenders = Dir[ROOT.join("config/**/*.rb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?("#")

        "#{Pathname(path).relative_path_from(ROOT)}:#{i + 1}" if line.match?(sprockets_only)
      end
    end
    assert_empty offenders, "Propshaft ignores these settings"
  end

  # studio-engine's shared head (layouts/studio/_head.html.erb) links
  # "tailwind" and "application" BY NAME, so the plain stylesheet must stay,
  # and it must resolve to Turf's own file, not the Tailwind source (which
  # has the same logical name and must stay off the load path).
  test "application.css is Turf's plain stylesheet and the Tailwind source is off the load path" do
    plain = ROOT.join("app/assets/stylesheets/application.css")
    assert plain.exist?, "the engine head links \"application\" by name; deleting this fails every render"

    resolved = Rails.application.assets.load_path.find("application.css")
    assert_equal plain.to_s, resolved.path.to_s

    tailwind_source = ROOT.join("app/assets/tailwind").to_s
    refute_includes Rails.application.config.assets.paths.map(&:to_s), tailwind_source,
                    "tailwindcss-rails keeps the Tailwind source off Propshaft's paths"
    assert Rails.application.assets.load_path.find("tailwind.css"),
           "the Tailwind build (app/assets/builds/tailwind.css) must be an asset"
  end

  # Propshaft writes no .gz (Sprockets did), and without one Rack::Deflater
  # compresses every stylesheet and script per request. The hook is what keeps
  # them precompressed (lib/precompressed_assets.rb).
  test "assets:precompile precompresses and assets:clean prunes" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("assets:precompress")

    assert_includes Rake::Task["assets:precompile"].actions.map { |a| a.source_location.first },
                    ROOT.join("lib/tasks/precompressed_assets.rake").to_s
    assert_includes Rake::Task["assets:clean"].actions.map { |a| a.source_location.first },
                    ROOT.join("lib/tasks/precompressed_assets.rake").to_s
  end
end
