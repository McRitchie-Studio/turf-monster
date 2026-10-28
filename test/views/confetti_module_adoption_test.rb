require "test_helper"

# [unit] Turf's celebrations reach canvas-confetti through studio-engine's
# studio/studio_confetti module (engine 0.115.1), never the deprecated
# window.confetti global the library defines.
#
# Two kinds of caller, two spellings. solana_utils.js is an importmap module and
# imports the module statically, by its importmap name. shared/_alpine_factories
# is a classic inline script (its globals must exist before Alpine starts), which
# cannot import statically, so it uses import() through the same map. Neither is
# a URL-loaded module tag, where a bare specifier would resolve before the map
# exists (the lesson of confetti-resolves-on-hub).
#
# The behaviour is held elsewhere: test/javascript/solana_utils_confetti.test.mjs
# runs the badge burst through the module, and e2e/confetti_module.spec.js fires
# all three celebrations in a page. This file holds the spelling, so a new
# caller cannot quietly go back to the global under any of its names:
# GLOBAL_READ bans typeof confetti and window / globalThis / self .confetti by
# dot, optional chain or bracket, with comments stripped first.
class ConfettiModuleAdoptionTest < ActiveSupport::TestCase
  SOLANA_UTILS = Rails.root.join("app/javascript/solana_utils.js")
  FACTORIES = Rails.root.join("app/views/shared/_alpine_factories.html.erb")

  # Every spelling that reads the global: the typeof guard, and the global
  # object under each of its names (window, globalThis, self), by dot, by
  # optional chain, or by bracket with any quote. Anchored with \b so a
  # property of something else ($store.solanaModal.confetti, myself.confetti)
  # and a longer name (window.confettiBurst) stay legal.
  GLOBAL_READ = /
    \btypeof\s*\(?\s*confetti\b
    | \b(?:window|globalThis|self)\s*\??\.\s*confetti\b
    | \b(?:window|globalThis|self)\s*(?:\?\.)?\s*\[\s*(["'`])confetti\1\s*\]
  /x

  # Source with its comments removed, so a comment that names the global (this
  # repo's comments do, to say why it is gone) neither trips the ban nor, being
  # removed whole, hides code. Block comments, HTML comments, whole-line //
  # comments, and a trailing // comment after code; the trailing form needs
  # whitespace before the slashes so a URL's "https://" is left alone.
  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/}m, "").gsub(/<!--.*?-->/m, "").lines
        .reject { |line| line.strip.start_with?("//") }
        .map { |line| line.sub(%r{(?<=\s)//.*$}, "") }
        .join
  end

  def code(path)
    strip_comments(path.read)
  end

  def global_read?(text)
    strip_comments(text).match?(GLOBAL_READ)
  end

  test "solana_utils imports confetti from studio/studio_confetti" do
    assert_match(/^import \{ confetti \} from "studio\/studio_confetti";$/, code(SOLANA_UTILS))
  end

  test "the inline factories reach the module with import(), through the map" do
    assert_match(/import\("studio\/studio_confetti"\)/, code(FACTORIES))
  end

  test "no Turf caller reads canvas-confetti's global" do
    files = Dir[Rails.root.join("app/javascript/**/*.js")] + Dir[Rails.root.join("app/views/**/*.erb")]
    offenders = files.select do |path|
      global_read?(Pathname(path).read)
    end
    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
                 "import { confetti } from \"studio/studio_confetti\" (or import() it from a classic script)"
  end

  # The ban is only as good as its pattern, so the pattern is held on fixtures:
  # each alias of the global must trip it, and the module spellings, a
  # same-named property of something else and a commented-out alias must not.
  ALIASES = [
    "if (typeof confetti === 'function') confetti({});",
    "if (typeof(confetti) !== 'undefined') go();",
    "window.confetti({ particleCount: 90 });",
    "window?.confetti?.({});",
    "globalThis.confetti({ particleCount: 90 });",
    "self.confetti({ particleCount: 90 });",
    'window["confetti"]({ particleCount: 90 });',
    "window['confetti']({ particleCount: 90 });",
    "globalThis['confetti']({});",
    "self[`confetti`]({});",
    "window?.['confetti']?.({});",
    "var fire = window . confetti;",
    "const ok = 1; window.confetti({}); // fire it"
  ].freeze

  LEGAL = [
    'import { confetti } from "studio/studio_confetti";',
    'import("studio/studio_confetti").then(function (m) { m.confetti({}); });',
    "confetti({ particleCount: 90 });",
    "if (val === 'success' && $store.solanaModal.confetti) go();",
    "var myself = {}; myself.confetti = 1;",
    "window.confettiBurst = function () {};",
    "window.studio_confetti = 1;",
    "// window.confetti is the deprecated global",
    "  // the old self.confetti / globalThis.confetti spellings",
    "/* window['confetti'] used to be read here */",
    "<!-- typeof confetti guard removed -->",
    "go(); // no window.confetti here any more",
    'var url = "https://cdn.example/confetti.js"; window.confettiZone = 1;'
  ].freeze

  ALIASES.each do |source|
    test "the ban catches #{source}" do
      assert global_read?(source), "expected the ban to flag: #{source}"
    end
  end

  LEGAL.each do |source|
    test "the ban allows #{source}" do
      refute global_read?(source), "expected the ban to allow: #{source}"
    end
  end

  test "studio/studio_confetti is pinned in this app's import map" do
    assert Rails.application.importmap.packages.key?("studio/studio_confetti"),
           "studio-engine >= 0.115.1 pins studio/studio_confetti; the callers above need it"
  end
end
