require "test_helper"

# Contract for the ORDER of this app's resolved view paths.
#
# MEASURED on 2026-09-01, with studio-engine 0.67.0 and solana-studio 0.5.4.
# A DATED SNAPSHOT, not a claim about the current resolve: the versions below
# are what was observed that day. The ORDER is the contract and does not depend
# on them, which is why a bump does not invalidate this note.
#
#
#   0. <app>/app/views
#   1. solana-studio-0.5.4/app/views
#   2. studio-engine-0.67.0/app/views
#   3. turbo-rails / 4. actiontext / 5. actionmailbox
#
# WHY solana-studio LEADS studio-engine, which is the whole reason this file
# exists: nothing chose it. A Rails::Engine PREPENDS its app/views in its
# :add_view_paths initializer, engine initializers run in railtie load order,
# and railtie load order follows Bundler.require — i.e. GEMFILE LINE ORDER. So
# the engine named on the LATER Gemfile line initializes LAST and therefore
# lands NEAREST THE FRONT. `gem "studio-engine"` sits above `gem
# "solana-studio"` in the Gemfile, and that single fact is what puts the gem in
# front of the engine.
#
# THE SWAP WAS RUN, not reasoned about. Moving the `gem "solana-studio"` line
# above `gem "studio-engine"` and re-measuring produced app/views,
# studio-engine, solana-studio — positions 1 and 2 exchanged. The app booted
# normally and NOTHING RAISED. That silence is the failure mode: a Gemfile
# tidy-up is a resolution change here, and it looks like nothing.
#
# WHY IT IS COSMETIC TODAY, AND EXACTLY WHEN IT STOPS BEING. Order only decides
# anything where two view paths ship the SAME virtual path. Measured on the
# same date, solana-studio's 6 views and studio-engine's 171 share NONE:
# solana-studio keeps everything under the `solana_studio/` prefix and the
# engine ships nothing there. That prefix discipline — not the Gemfile — is
# what actually makes resolution unambiguous right now. The order is the
# FALLBACK, and it is the fallback that a re-added engine copy would land on:
# the moment either side ships a path the other already has, the Gemfile line
# order silently picks the winner. Both facts are asserted below, because the
# invariant is only safe while BOTH hold.
#
# DO NOT ASSERT ON "/gems/". A path checkout of either gem contains no `/gems/`
# segment, so that form cannot pass in a consumer-CI lane that bundles the gem
# from a path — a consumer assertion of exactly that shape red-sealed a gem
# publish on 2026-08-27 (/tasks/fix-picker-gem-path-assertion). Every position
# below is found by asking the engine for its OWN root.
#
# NAMESPACE, NOT BASENAME. studio-engine ships
# style/modals/_wallet_connect.html.erb — the 0.66.2 drop took the studio/solana
# and studio/modals namespaces only, never style/modals — and solana-studio ships
# solana_studio/modals/_wallet_connect.html.erb — the same basename at
# different virtual paths, which Rails never collapses. A basename comparison
# reports that CORRECT bundle as a collision, which is the worst thing a guard
# can do. The comparison below is on the full namespaced path, and the control
# at the bottom pins that granularity.
class ViewPathOrderContractTest < ActiveSupport::TestCase
  # Install-agnostic: the engine reports its own views directory, so this works
  # whether the gem is installed, vendored, or bundled from a path checkout.
  SOLANA_STUDIO_VIEWS = SolanaStudio::Engine.paths["app/views"].existent.freeze
  STUDIO_ENGINE_VIEWS = Studio::Engine.paths["app/views"].existent.freeze
  APP_VIEWS           = Rails.root.join("app/views").to_s.freeze

  # Every file under a views directory, as the path Rails resolves it BY — the
  # namespaced relative path (`solana_studio/modals/_wallet_connect.html.erb`),
  # never the basename.
  def self.virtual_paths(dir)
    Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }
       .map { |f| f.delete_prefix("#{dir}/") }
       .to_set
  end

  def resolved_view_paths
    ApplicationController.view_paths.map(&:to_s)
  end

  def position_of(dir)
    resolved_view_paths.index(dir)
  end

  def virtual_paths(dir)
    self.class.virtual_paths(dir)
  end

  test "this app's own app/views leads every gem view path" do
    assert_equal 0, position_of(APP_VIEWS),
                 "this app's app/views is at position #{position_of(APP_VIEWS).inspect} rather " \
                 "than the front of #{resolved_view_paths.inspect} — this app deliberately " \
                 "overrides studio-engine views at the SAME virtual path " \
                 "(#{(virtual_paths(APP_VIEWS) & virtual_paths(STUDIO_ENGINE_VIEWS)).to_a.sort.join(', ')}), " \
                 "and every one of those now renders the ENGINE copy instead, silently"
  end

  test "solana-studio's views resolve ahead of studio-engine's" do
    solana = SOLANA_STUDIO_VIEWS.first
    engine = STUDIO_ENGINE_VIEWS.first

    # Asserted rather than assumed: if either gem dropped out of the view path
    # entirely, the comparison below would be comparing nil and this file would
    # stop meaning anything.
    assert solana, "solana-studio contributes no app/views at all"
    assert engine, "studio-engine contributes no app/views at all"
    assert position_of(solana), "solana-studio's app/views is not in the resolved view path"
    assert position_of(engine), "studio-engine's app/views is not in the resolved view path"

    assert_operator position_of(solana), :<, position_of(engine),
                    "studio-engine's views now resolve AHEAD of solana-studio's. Nothing raises " \
                    "when this flips, so the only signal is this test. THE CAUSE IS ALMOST " \
                    "CERTAINLY GEMFILE LINE ORDER: engines prepend their view paths in railtie " \
                    "load order, which follows Bundler.require, so the gem on the LATER Gemfile " \
                    "line ends up FIRST. Restore by keeping `gem \"studio-engine\"` ABOVE " \
                    "`gem \"solana-studio\"` in the Gemfile. If the reorder was deliberate, read " \
                    "the disjointness test below before accepting it — the two only stay " \
                    "interchangeable while the gems share no virtual path."
  end

  test "solana-studio and studio-engine ship no view at the same virtual path" do
    collisions = virtual_paths(SOLANA_STUDIO_VIEWS.first) & virtual_paths(STUDIO_ENGINE_VIEWS.first)

    assert_empty collisions,
                 "solana-studio and studio-engine now BOTH ship #{collisions.to_a.sort.join(', ')}. " \
                 "Rails resolves that by view-path order alone, so whichever gem happens to sit " \
                 "on the later Gemfile line wins and the other copy becomes unreachable — with " \
                 "no error anywhere. Until now the two were disjoint (solana-studio owns the " \
                 "`solana_studio/` prefix and the engine ships nothing there), which is what made " \
                 "the ordering above cosmetic. It is not cosmetic any more: decide which gem owns " \
                 "this path and delete the other copy, rather than leaving the Gemfile to choose."
  end

  # THE CONTROL, and it carries real content rather than decoration.
  #
  # Two ways the three assertions above could pass while proving nothing: the
  # intersection logic could be wrong, or the globs could be reading an empty
  # directory (a moved gem root, a bad delete_prefix) so that every set is
  # empty and every comparison is vacuously true. This asks both.
  test "the collision probe can say yes, and says it on namespace rather than basename" do
    # 1. It reads real directories. Both gems must actually ship views, or the
    #    disjointness above is a comparison of two empty sets.
    assert_not_empty virtual_paths(SOLANA_STUDIO_VIEWS.first),
                     "solana-studio's views directory globbed EMPTY, so the disjointness " \
                     "assertion compared nothing against nothing and proves nothing"
    assert_not_empty virtual_paths(STUDIO_ENGINE_VIEWS.first),
                     "studio-engine's views directory globbed EMPTY, so the disjointness " \
                     "assertion compared nothing against nothing and proves nothing"

    # 2. It detects a REAL collision when one exists. This app deliberately
    #    overrides studio-engine views at identical virtual paths, so the same
    #    set-intersection used above must find them. If this ever empties, the
    #    control has lost its subject and needs a new one — it has not gone
    #    stale, it has stopped being a control.
    assert_not_empty virtual_paths(APP_VIEWS) & virtual_paths(STUDIO_ENGINE_VIEWS.first),
                     "this app no longer overrides ANY studio-engine view at the same virtual " \
                     "path, so the intersection above has never been shown to detect a collision"

    # 3. It compares namespaces, not basenames. Synthetic on purpose: the real
    #    near-miss (style/modals/_wallet_connect vs
    #    solana_studio/modals/_wallet_connect in the versions bundled today)
    #    would make this brittle against an unrelated engine bump, and the
    #    property being pinned is the comparison's GRANULARITY, which does not
    #    depend on what either gem currently ships.
    same_name_different_namespace =
      Set["style/modals/_wallet_connect.html.erb"] & Set["solana_studio/modals/_wallet_connect.html.erb"]
    assert_empty same_name_different_namespace,
                 "the comparison collapsed two DIFFERENT virtual paths that merely share a " \
                 "basename — a basename-granularity probe reports a correct bundle as broken"

    truly_same_path =
      Set["solana_studio/modals/_wallet_connect.html.erb"] & Set["solana_studio/modals/_wallet_connect.html.erb"]
    assert_not_empty truly_same_path,
                     "the comparison failed to match two identical virtual paths, so it cannot " \
                     "detect the collision this file exists to catch"
  end
end
