require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "rake"
require Rails.root.join("lib/tasks/support/node_link_guard").to_s

# [unit] Turf on studio-engine's Node tooling package (lib/studio/node_tooling in
# the gem, engine 0.115.1; the hook maps digit-named pins such as base58 from
# 0.116.1): wave 6 of the UI consistency program.
#
# What adoption means here, each held below:
#   - the pins: Node 22 in .tool-versions, read by mise and by every CI
#     setup-node step; @playwright/test and axe-core at exactly versions.json
#     (`bin/rails studio:node:check` is the same check, run as a test);
#   - the link: `studio:node:link` after every `npm ci` in CI, never in a Heroku
#     build or release phase, and refused through a node_modules borrowed from
#     another checkout (TurfMonster::NodeLinkGuard);
#   - the shared Playwright base under playwright.config.js, checked as
#     Playwright receives it;
#   - the node:test importmap hook, mapped onto every pin config/importmap.rb
#     draws.
class NodeToolingAdoptionTest < ActiveSupport::TestCase
  WORKFLOW = Rails.root.join(".github/workflows/ci.yml")
  CONFIG = Rails.root.join("playwright.config.js")

  # ── the pins ──────────────────────────────────────────────────────────

  test "this app matches studio-engine's Node pins (studio:node:check)" do
    assert_empty Studio::NodeTooling.drift(Rails.root),
                 "run `bin/rails studio:node:check` and move the pins it names"
  end

  test "every CI setup-node step reads the Node pin from .tool-versions" do
    workflow = WORKFLOW.read
    steps = workflow.scan(/uses: actions\/setup-node@v\d+\n\s*with: \{([^}]*)\}/).flatten
    assert_operator steps.size, :>=, 3, "the test, playwright and e2e_declared_set jobs each set up Node"
    steps.each do |with|
      assert_equal "node-version-file: .tool-versions", with.strip,
                   "a setup-node step names its own Node version; read it from .tool-versions"
    end
    assert_no_match(/node-version:\s*\d/, workflow, "a hard-coded node-version drifts from the pin")
  end

  test "the test job sets up the pinned Node before the suite spawns node" do
    job = job_body("test")
    assert_operator job.index("actions/setup-node"), :<, job.index("bin/rails db:test:prepare test"),
                    "test/lib/javascript_unit_test.rb runs node; without setup-node it gets the image's Node"
  end

  # ── the link ──────────────────────────────────────────────────────────

  test "every CI job that runs npm ci links the package before Playwright loads the config" do
    jobs = WORKFLOW.read.scan(/^  ([a-z0-9_]+):\n/).flatten.select { |name| job_body(name).include?("npm ci") }
    assert_equal %w[playwright e2e_declared_set], jobs
    jobs.each do |name|
      body = job_body(name)
      link = body.index("bin/rails studio:node:link")
      assert link, "#{name} runs npm ci but never links studio-engine's Node tooling"
      assert_operator body.index("npm ci"), :<, link, "#{name}: npm ci deletes node_modules, so link after it"
      first_playwright = [body.index("npm test"), body.index("bin/e2e-lane-derive")].compact.min
      assert_operator link, :<, first_playwright, "#{name}: link before anything loads playwright.config.js"
      assert_match(/bundler-cache: true/, body, "#{name}: studio:node:link needs the bundle")
    end
  end

  test "the link never runs in a Heroku build or release phase" do
    assert_no_match(/studio:node/, Rails.root.join("Procfile").read)
    scripts = JSON.parse(Rails.root.join("package.json").read).fetch("scripts", {})
    lifecycle = scripts.slice("preinstall", "install", "postinstall", "prepare", "build",
                              "heroku-prebuild", "heroku-postbuild", "heroku-cleanup")
    assert_empty lifecycle, "the heroku/nodejs buildpack runs these at build time: #{lifecycle.keys.join(", ")}"
  end

  test "the link guard refuses to write through a borrowed node_modules" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      tooling = root.join("gem/node_tooling").tap(&:mkpath)
      other = root.join("gem/other_tooling").tap(&:mkpath)
      primary = root.join("primary/node_modules").tap(&:mkpath)
      desk = root.join("desk").tap(&:mkpath)

      own = root.join("own").tap(&:mkpath)
      own.join("node_modules").mkpath
      assert_nil TurfMonster::NodeLinkGuard.refusal(own, root: tooling), "a desk's own node_modules links freely"

      File.symlink(primary, desk.join("node_modules"))
      refusal = TurfMonster::NodeLinkGuard.refusal(desk, root: tooling)
      assert_match(/absent/, refusal, "no link yet: linking would CREATE the primary's")
      assert_match(/npm ci/, refusal)
      assert_match(/STUDIO_NODE_TOOLING=#{Regexp.escape(tooling.to_s)}/, refusal)

      File.symlink(other, primary.join(".studio-engine"))
      assert_match(/now #{Regexp.escape(other.to_s)}/, TurfMonster::NodeLinkGuard.refusal(desk, root: tooling),
                   "a different engine's link would be repointed")

      primary.join(".studio-engine").delete
      File.symlink(tooling, primary.join(".studio-engine"))
      assert_nil TurfMonster::NodeLinkGuard.refusal(desk, root: tooling), "already this gem: link! is a no-op"
    end
  end

  test "studio:node:link carries the guard as a prerequisite" do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    assert_includes Rake::Task["studio:node:link"].prerequisites, "turf:node:guard_shared_node_modules"
  end

  # ── the Playwright base ───────────────────────────────────────────────

  test "Playwright receives Turf's lane on the engine base" do
    config = resolved_config
    assert_equal "./e2e", config["testDir"]
    assert_equal 30_000, config["timeout"]
    assert_equal 1, config["workers"]
    assert_equal 0, config["retries"], "local runs surface flakes"
    assert_equal({ "reducedMotion" => "reduce" }, config.dig("use", "contextOptions"))
    assert_equal "http://127.0.0.1:3100", config.dig("use", "baseURL")
    assert_equal %w[chromium devnet], config["projects"].map { |p| p["name"] }

    server = config.fetch("webServer")
    assert_equal "http://127.0.0.1:3100/up", server["url"]
    assert_match(/bin\/rails server -p 3100 -e test\z/, server["command"])
    assert_operator server["timeout"], :>=, 120_000
    %w[PLAYWRIGHT_SEED ENABLE_WEB3_ONLY_ONBOARDING ENABLE_AGE_GATE ENABLE_COINFLOW ENABLE_AEROPAY ENABLE_FIAT_RAILS].each do |flag|
      assert_equal "true", server.dig("env", flag), "webServer.env names #{flag}"
    end

    ci = resolved_config("CI" => "1")
    assert_equal 2, ci["retries"]
    assert_equal true, ci["forbidOnly"]
    assert_equal false, ci.dig("webServer", "reuseExistingServer")
  end

  test "PW_BASE_URL (bin/e2e-parallel) gets no webServer, and E2E_PORT moves the default one" do
    external = resolved_config("PW_BASE_URL" => "http://127.0.0.1:3911")
    assert_nil external["webServer"], "bin/e2e-parallel brings up its own servers"
    assert_equal "http://127.0.0.1:3911", external.dig("use", "baseURL")

    moved = resolved_config("E2E_PORT" => "3192")
    assert_equal "http://127.0.0.1:3192/up", moved.dig("webServer", "url")
    assert_match(/-p 3192 -e test\z/, moved.dig("webServer", "command"))
  end

  # ── the node:test hook ────────────────────────────────────────────────

  # Pins whose NAME is a path the prefix hook maps to a DIFFERENT file than the
  # browser loads. Each is named with its reason; a new one fails below.
  DIVERGENT = {
    # config/importmap.rb overrides the engine's empty studio/host_fetchers with
    # Turf's own host_fetchers.js; the hook maps the studio/ prefix to the engine.
    "studio/host_fetchers" => "host_fetchers.js"
  }.freeze

  test "the node:test hook maps every path-named pin onto the file the browser loads" do
    assert_hook_maps_pins(hook_resolutions(Rails.application.importmap.packages.keys))
  end

  private

  # Every path-named pin resolves, under `resolved` (name => absolute path the
  # hook maps it to, nil when unmapped), to the file the browser loads.
  # A digit-named pin (base58) is held here too: the engine hook's top-level
  # gate takes /^[a-z0-9_]+$/ since studio-engine 0.116.1.
  def assert_hook_maps_pins(resolved)
    packages = Rails.application.importmap.packages
    checked = 0
    packages.each do |name, pin|
      file = Rails.application.assets.load_path.find(pin.path)&.path&.to_s
      next unless file

      if DIVERGENT.key?(name)
        assert_equal DIVERGENT[name], pin.path, "#{name} no longer pins #{DIVERGENT[name]}; drop it from DIVERGENT"
        next
      end
      next unless pin.path == "#{name}.js" # a `to:` alias ("canvas-confetti"); the prefix hook cannot map it

      assert_equal file, resolved[name], "node --test resolves #{name.inspect} to a different file than the import map"
      checked += 1
    end
    assert_operator checked, :>=, 140, "most of the #{packages.size} pins are path-named; the walk went blind"
  end

  # A job's text, from its key to the next top-level job.
  def job_body(name)
    workflow = WORKFLOW.read
    start = workflow.index(/^  #{name}:\n/)
    assert start, "no #{name} job in ci.yml"
    rest = workflow[(start + 1)..]
    stop = rest.index(/^  [a-z0-9_]+:\n/)
    stop ? rest[0...stop] : rest
  end

  # playwright.config.js as Playwright receives it. This job runs no `npm ci`,
  # so @playwright/test is stubbed with an identity defineConfig (Playwright's
  # own returns the object it is given) and the engine package is read from the
  # bundled gem.
  def resolved_config(env = {})
    script = <<~JS
      const Module = require("node:module");
      const load = Module._load;
      Module._load = function (request, ...rest) {
        if (request === "@playwright/test") return { defineConfig: (config) => config };
        return load.call(this, request, ...rest);
      };
      process.stdout.write(JSON.stringify(require(#{CONFIG.to_s.to_json})));
    JS
    clean = { "CI" => nil, "PW_BASE_URL" => nil, "BASE_URL" => nil, "E2E_PORT" => nil }
    out, err, status = Open3.capture3(clean.merge(NodeImportmap.env).merge(env), "node", "-e", script, chdir: Rails.root.to_s)
    assert status.success?, "node could not load playwright.config.js: #{err}"
    JSON.parse(out)
  end

  # name => absolute path the engine's hook maps it to (nil when unmapped),
  # with Turf's options (test/javascript/support/importmap.mjs).
  def hook_resolutions(names)
    script = <<~JS
      import { fileURLToPath, pathToFileURL } from "node:url";
      const [hooksPath, optionsPath, namesJson] = process.argv.slice(1);
      const hooks = await import(pathToFileURL(hooksPath).href);
      const { importmapHookOptions } = await import(pathToFileURL(optionsPath).href);
      hooks.initialize(importmapHookOptions());
      const out = {};
      for (const name of JSON.parse(namesJson)) {
        const { url } = await hooks.resolve(name, {}, async (specifier) => ({ url: specifier }));
        out[name] = url.startsWith("file:") ? fileURLToPath(url) : null;
      }
      process.stdout.write(JSON.stringify(out));
    JS
    hooks = Studio::NodeTooling.root.join("node_test/importmap_hooks.mjs").to_s
    options = Rails.root.join("test/javascript/support/importmap.mjs").to_s
    out, err, status = Open3.capture3(NodeImportmap.env, "node", "--input-type=module", "-e", script,
                                      hooks, options, names.to_json)
    assert status.success?, "node could not run the importmap hook: #{err}"
    JSON.parse(out)
  end
end
