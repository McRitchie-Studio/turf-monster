require "test_helper"

# [integration] Turf's Stimulus application (app/javascript/turf_stimulus.js):
# what a page loads, what it preloads, and that the hooks the views carry exist
# on the controllers they name.
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

      source.scan(/data-controller="([^"<]+)"/).flatten.flat_map(&:split).each do |identifier|
        assert_includes registered.keys, identifier, "#{view} names an unregistered controller"
        named += 1
      end

      source.scan(/(?:data-action=|\baction: )"([^"<]+)"/).flatten.flat_map(&:split).each do |action|
        identifier, method = action.split("->").last.split("#")
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
      "dev-score-tools" => "reset", "scoring-filter" => "reset", "game-scorer" => "reset"
    }.each do |identifier, method|
      # The 300 characters after the attribute hold the rest of the opening tag.
      roots = Dir[VIEWS].sort.flat_map { |file| File.read(file).scan(/data-controller="#{identifier}".{0,300}/m) }
      assert_not_empty roots, "no view names #{identifier}"
      roots.each { |tag| assert_includes tag, "turbo:before-cache@document->#{identifier}##{method}" }
    end
  end
end
