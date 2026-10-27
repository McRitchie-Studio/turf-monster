require "test_helper"

# [integration] Turf's Stimulus controllers (app/javascript/turf_stimulus.js),
# registered on the engine's application: what a page loads, what it preloads,
# that the hooks the views carry exist on the controllers they name, and that
# there is one application per page, not two.
class TurfStimulusTest < ActionDispatch::IntegrationTest
  include PageModuleGraph

  ENTRY = Rails.root.join("app/javascript/turf_stimulus.js")
  CONTROLLERS = Rails.root.join("app/javascript/controllers")
  VIEWS = Rails.root.join("app/views/**/*.erb")
  OWN = %r{\A(?:controllers|turf)/}

  # identifier => module specifier, for both ways a controller registers.
  def static_controllers = entry_registrations(ENTRY.read)

  def entry_registrations(source)
    imports = source.scan(/^import (\w+) from "(controllers\/\w+)"$/).to_h
    source.scan(/^application\.register\("([a-z-]+)", (\w+)\)$/).to_h { |name, constant| [ name, imports.fetch(constant) ] }
  end

  def lazy_controllers
    ENTRY.read.scan(/^  "([a-z-]+)": \(\) => import\("(controllers\/\w+)"\),?$/).to_h
  end

  # A controller a view registers from its own module tag: entry module => { identifier => specifier }.
  def page_tag_controllers
    { "dev_tools" => entry_registrations(Rails.root.join("app/javascript/dev_tools.js").read) }
  end

  def registered = static_controllers.merge(lazy_controllers, *page_tag_controllers.values)

  def controller_source(identifier) = Rails.root.join("app/javascript/#{registered.fetch(identifier)}.js").read

  def page
    log_in_as(users(:alex))
    get admin_hub_path
    assert_response :success
    response.body
  end

  def preloaded(html)
    urls = Nokogiri::HTML(html).css('link[rel="modulepreload"]').map { |link| link["href"] }
    page_importmap(html).select { |_name, url| urls.include?(url) }.keys
  end

  # Every module `specifier` imports, statically, at any depth.
  def graph_of(specifier, imports)
    seen = []
    queue = [ specifier ]
    until queue.empty?
      name = queue.shift
      next if seen.include?(name)

      seen << name
      url = imports[name]
      assert url, "#{name.inspect} is imported and not pinned"
      get url
      assert_response :success, "#{name} is pinned to #{url}, which this app does not serve"
      queue.concat(send(:static_imports, response.body))
    end
    seen
  end

  # The engine's application (studio/stimulus) and the identifiers it registers:
  # studio/application's every-page chrome, studio/stimulus' own, and its LAZY list.
  ENGINE_JS = Pathname(Gem.loaded_specs.fetch("studio-engine").full_gem_path).join("app/javascript/studio")

  def engine_identifiers
    sources = [ ENGINE_JS.join("stimulus.js").read, ENGINE_JS.join("application.js").read ]
    sources.flat_map { |source| source.scan(/application\.register\("([a-z-]+)"/).flatten + source.scan(/^  "([a-z-]+)": \(\) => import\(/).flatten }.uniq
  end

  # Every Turf JavaScript module, and every Ruby and ERB file that renders markup.
  def turf_js = Dir[Rails.root.join("app/javascript/**/*.js")].sort
  def markup_sources = Dir[Rails.root.join("app/{views,helpers,components,services}/**/*.{erb,rb}")].sort

  test "Turf starts no Stimulus application of its own: it registers on the engine's" do
    turf_js.each do |file|
      assert_no_match(/\bApplication\.start\b|new Application\b|import \{[^}]*\bApplication\b[^}]*\} from "@hotwired\/stimulus"/,
        File.read(file), "#{file} starts a second Stimulus application: register on studio/stimulus' instead")
    end
    entry = ENTRY.read
    assert_includes entry, %(import { application } from "studio/stimulus")
    assert_match(/^export \{ application \}$/, entry)
    assert_includes entry, %(attribute: "data-studio-controller"), "the lazy registry watches the engine's controller attribute"
    assert_match(/\bApplication\.start\(document\.documentElement, schema\)/, ENGINE_JS.join("stimulus.js").read,
      "the engine's studio/stimulus no longer starts the one application this file registers on")
  end

  test "no Turf identifier collides with an engine controller's" do
    engine = engine_identifiers
    assert_includes engine, "hold-button"
    assert_includes engine, "board"
    assert_empty registered.keys & engine, "one application now holds both: a shared identifier would replace the engine's controller"
  end

  # On the engine's schema, Stimulus reads data-studio-controller and
  # data-studio-action; a data-controller or data-action is inert markup, a
  # control that renders and never connects.
  test "no markup names a controller or action on Stimulus' default attributes" do
    markup_sources.each do |file|
      source = File.read(file)
      next if file.end_with?("app/services/laptop_live_snapshot.rb") # strips both vocabularies

      assert_no_match(/(?<![\w-])data-(?:controller|action)(?![\w-])/, source, "#{file}: use data-studio-controller / data-studio-action")
      assert_no_match(/data: \{[^}]*(?<![\w])(?:controller|action): /m, source, "#{file}: a data hash names controller:/action:, use studio_controller:/studio_action:")
    end
    turf_js.each do |file|
      assert_no_match(/(?<![\w-])data-(?:controller|action)(?![\w-])/, File.read(file), "#{file} selects on an attribute nothing carries")
    end
  end

  test "the registry is read, and every controller file is in it once" do
    assert_operator lazy_controllers.size, :>=, 8
    assert_equal({ "dev-score-tools" => "controllers/dev_score_tools_controller" }, page_tag_controllers.fetch("dev_tools"))
    assert_equal registered.size, static_controllers.size + lazy_controllers.size + page_tag_controllers.values.sum(&:size)

    files = CONTROLLERS.glob("*_controller.js").map { |file| "controllers/#{file.basename('.js')}" }
    assert_equal files.sort, registered.values.sort
  end

  test "a page runs turf_stimulus, and preloads exactly what it imports statically" do
    html = page
    loaded = page_modules(html)
    assert_includes loaded, "turf_stimulus"
    assert_includes loaded, "studio/lazy_controllers"

    own = loaded.grep(OWN)
    assert_equal static_controllers.values.sort, own.grep(/controllers/).sort
    assert_equal own.sort, preloaded(html).grep(OWN).sort
  end

  test "a lazy controller and its modules are pinned, served, and not preloaded" do
    html = page
    imports = page_importmap(html)
    every_page = page_modules(html)

    lazy_controllers.each_value do |specifier|
      graph = graph_of(specifier, imports)
      assert_empty graph.grep(OWN) & every_page, "#{specifier} is lazy, yet every page already imports part of it"
      assert_empty graph.grep(OWN) & preloaded(html)
    end
  end

  test "the static controllers are the public pages' controllers, and none is lazy" do
    marketing = %w[accordion auto-submit card-filter cost-calculator proof-of-reserves swatch-copy]
    entry = %w[desktop-only-notice email-change-notice frame-reload newsletter-state referral-share reveal
               reveal-follow-up session-wipe submit-busy usdc-balance withdraw-card]
    # Signing-page admin controls, static so an early press is never dropped.
    signing = %w[cosign-button vault-console]
    board = %w[arrival-scroll chat-reactions contest-chain contest-rail copy-link disclosure leaderboard leaderboard-poll
               row-link settled-filter tabs]
    assert_equal (marketing + entry + board + signing).sort, static_controllers.keys.sort
    assert_empty static_controllers.keys & lazy_controllers.keys
  end

  test "a signed-out public page preloads every static controller and the modules it imports" do
    get teams_path
    assert_response :success
    html = response.body
    imports = page_importmap(html)
    preloads = preloaded(html)

    static_controllers.each_value do |specifier|
      graph_of(specifier, imports).grep(OWN).each do |name|
        assert_includes preloads, name, "#{name} is imported by a static controller and not preloaded"
      end
    end
  end

  test "a page without the dev tools neither imports nor preloads them" do
    html = page
    assert_not_includes page_modules(html), "dev_tools"
    assert_empty preloaded(html) & [ "dev_tools", "controllers/dev_score_tools_controller", "turf/dev_score_tools" ]
  end

  test "every controller, action and target a view names exists" do
    named = 0
    Dir[VIEWS].sort.each do |file|
      source = File.read(file)
      view = Pathname(file).relative_path_from(Rails.root).to_s

      source.scan(/(?:data-studio-controller=|\bstudio_controller: )"([^"<]+)"/).flatten.flat_map(&:split).each do |identifier|
        assert_includes registered.keys + engine_identifiers, identifier, "#{view} names an unregistered controller"
        named += 1
      end

      source.scan(/(?:data-studio-action=|\bstudio_action: )"([^"<]+)"/).flatten.flat_map(&:split).each do |action|
        identifier, method = action.split("->").last.split("#")
        method = method&.split(":")&.first
        next unless method && registered.key?(identifier)

        assert_match(/^  (?:async )?#{method}\(/, controller_source(identifier), "#{view}: #{action} names a missing method")
      end

      registered.each_key do |identifier|
        attribute = /data-#{identifier}-target="([^"<]+)"|\b#{identifier.tr('-', '_')}_target: "([^"]+)"/
        source.scan(attribute).flatten.compact.flat_map(&:split).each do |target|
          targets = controller_source(identifier)[/static targets = \[(.*?)\]/m, 1].to_s.scan(/"(\w+)"/).flatten
          assert_includes targets, target, "#{view}: #{identifier} has no #{target} target"
        end
      end
    end
    assert_operator named, :>=, registered.size
  end

  test "a control whose state is in the markup resets before Turbo caches the page" do
    {
      "filter" => "reset", "show-more" => "collapse", "send-gate" => "reset",
      "dev-score-tools" => "reset", "scoring-filter" => "reset", "game-scorer" => "reset",
      "navbar-preview" => "reset", "accordion" => "collapse", "card-filter" => "reset",
      "cost-calculator" => "reset", "swatch-copy" => "reset",
      "email-change-notice" => "reset", "newsletter-state" => "reset", "referral-share" => "reset",
      "reveal" => "reset", "reveal-follow-up" => "reset", "submit-busy" => "reset", "withdraw-card" => "reset",
      "disclosure" => "reset", "copy-link" => "reset", "tabs" => "reset", "leaderboard" => "reset",
      "settled-filter" => "reset"
    }.each do |identifier, method|
      # The 300 characters after the attribute (or a helper's controller: key)
      # hold the rest of the opening tag. The root may name more than one
      # controller.
      roots = Dir[VIEWS].sort.flat_map do |file|
        File.read(file).scan(/(?:data-studio-controller="[^"]*(?<![\w-])|\bstudio_controller: ")#{identifier}(?![\w-])[^"]*".{0,300}/m)
      end
      assert_not_empty roots, "no view names #{identifier}"
      roots.each { |tag| assert_includes tag, "turbo:before-cache@document->#{identifier}##{method}" }
    end
  end
end
