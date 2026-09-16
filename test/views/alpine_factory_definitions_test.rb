# frozen_string_literal: true

require "test_helper"

# ONE definition per Alpine x-data factory — the guard, and the render that
# proves the surviving copy actually ships.
#
# WHAT WENT WRONG TWICE. This app defines its Alpine factories as inline
# `window.name = function` in an ERB partial, because importmap modules execute
# AFTER Alpine has walked x-data. Three factories ALSO had a twin under
# app/javascript/. A twin is not dead code: which copy answers depends on how
# the reader ARRIVED at the page. Measured in a browser 2026-09-16 with
# Alpine.$data(el) — never window.<name>, which is a different object and
# inverts the other way:
#
#   component          direct page.goto   Turbo client-side nav
#   entryTokenBadge    inline copy        MODULE copy
#   cardListFilter     inline copy        MODULE copy
#
# While the copies agree that split is invisible, which is what let seedsBar's
# two copies drift apart unnoticed until the inline one was a full cache
# reconciliation ahead of the module. contestLockPicker is the case where the
# same shape reached a user: its on-chain lock button was inert on every fresh
# page load, and the e2e spec stayed green because it read the global.
#
# WHY A SOURCE SCAN AND NOT ONLY A BROWSER SPEC. A browser can only see a split
# the two copies DISAGREE about. entryTokenBadge and cardListFilter were
# byte-identical the day their twins were deleted, so no rendered assertion
# could have bitten — the divergence arrives later, in the edit that touches one
# file. The scan bites at the moment the second definition appears, which is the
# only moment the cost is still zero.
class AlpineFactoryDefinitionsTest < ActionDispatch::IntegrationTest
  APP_ROOT = Rails.root

  # A FACTORY DEFINITION, and deliberately not every global assignment.
  #
  #   window.name = function ...     window.name = async function ...
  #   window.name = (args) => ...    window.name = someIdentifier;
  #   Alpine.data("name", ...)
  #
  # The last global form is how a module publishes a function it declared above
  # (`window.seedsBar = seedsBar;`). Literal assignments are excluded because
  # they are STATE SLOTS, not components: `window.tmOutstandingEntryPrepare =
  # null` in one file and `= { ptxSlug: ... }` in another is a deliberate
  # cross-file handoff, and flagging it would have taught the next reader to
  # silence this test rather than to read it. Same reason walletProvider is not
  # a finding: the layout assigns it an object LITERAL as a deliberate stub that
  # the module later upgrades, and its consumers read it at click time rather
  # than capturing it at bind time.
  FACTORY_GLOBAL = /^\s*window\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*
                    (?:async\s+)?
                    (?:function\b|\([^)]*\)\s*=>|(?!null|undefined|true|false)[A-Za-z_][A-Za-z0-9_]*\s*;)/x
  ALPINE_DATA = /Alpine\.data\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']/

  # Factories live in ERB (the inline definitions) or in importmap modules.
  SOURCES = ["app/views/**/*.erb", "app/javascript/**/*.js"].freeze

  def factory_definitions
    defs = Hash.new { |h, k| h[k] = {} }
    SOURCES.flat_map { |g| Dir.glob(APP_ROOT.join(g)) }.sort.each do |path|
      rel = Pathname.new(path).relative_path_from(APP_ROOT).to_s
      File.readlines(path).each_with_index do |line, idx|
        next if line =~ %r{^\s*(//|\*|\#)} # a comment that merely NAMES a factory
        [FACTORY_GLOBAL, ALPINE_DATA].each do |re|
          defs[Regexp.last_match(1)][rel] ||= idx + 1 if line =~ re
        end
      end
    end
    defs
  end

  test "[unit] no Alpine factory is defined in more than one file" do
    paired = factory_definitions.select { |_, files| files.size > 1 }

    detail = paired.sort.map do |name, files|
      "  #{name}\n" + files.sort.map { |f, ln| "      #{f}:#{ln}" }.join("\n")
    end.join("\n")

    assert_empty paired, <<~MSG
      #{paired.size} Alpine factory name(s) are defined in more than one file:

      #{detail}

      Collapse it to ONE definition — and keep the INLINE ERB copy, not the
      module. Only the inline copy can win a direct page load: importmap modules
      execute after Alpine has already processed x-data, so a module-only
      factory leaves the component unbound on a typed URL, a refresh, or an
      external link. See the header of app/views/shared/_alpine_factories.html.erb.
    MSG
  end

  # The scan above proves there is no SECOND definition. This proves the one
  # that survived is really on the page — the failure mode if someone "cleans
  # up" by deleting the inline copy and keeping a module, which the scan would
  # happily call resolved.
  test "[component] the surviving factory definitions ship in the rendered document" do
    log_in_as_onchain(users(:sam))
    get contests_path
    assert_response :success

    {
      "seedsBar" => "components/_seeds_bar",
      "entryTokenBadge" => "shared/_alpine_factories",
      "cardListFilter" => "shared/_alpine_factories"
    }.each do |factory, home|
      assert_includes response.body, "window.#{factory} = function",
                      "#{factory} is not defined inline in the rendered document — " \
                      "its definition should be the one in #{home}."
    end
  end

  # The reconciliation the deleted module twin had drifted behind. It is the one
  # behaviour difference the two seedsBar copies had, so it is the assertion that
  # would have caught the drift at the source rather than in a browser.
  test "[component] the seedsBar that ships carries the server-vs-cache reconciliation" do
    inline = File.read(APP_ROOT.join("app/views/components/_seeds_bar.html.erb"))

    assert_includes inline, "_serverSeedsTotal",
                    "the shipped seedsBar lost its server-total read"
    assert_includes inline, "cacheTotal",
                    "the shipped seedsBar lost its cache reconciliation in normalStart"
  end
end
