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
# caller cannot quietly go back to the global.
class ConfettiModuleAdoptionTest < ActiveSupport::TestCase
  SOLANA_UTILS = Rails.root.join("app/javascript/solana_utils.js")
  FACTORIES = Rails.root.join("app/views/shared/_alpine_factories.html.erb")

  def code(path)
    path.read.gsub(%r{/\*.*?\*/}m, "").lines.reject { |line| line.strip.start_with?("//") }.join
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
      source = code(Pathname(path))
      source.match?(/typeof confetti\b/) || source.match?(/window\.confetti\b/)
    end
    assert_empty offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
                 "import { confetti } from \"studio/studio_confetti\" (or import() it from a classic script)"
  end

  test "studio/studio_confetti is pinned in this app's import map" do
    assert Rails.application.importmap.packages.key?("studio/studio_confetti"),
           "studio-engine >= 0.115.1 pins studio/studio_confetti; the callers above need it"
  end
end
