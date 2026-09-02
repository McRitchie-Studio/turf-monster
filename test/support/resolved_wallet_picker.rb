# frozen_string_literal: true

# THE CONNECT-WALLET PICKER THAT ACTUALLY RENDERS, resolved rather than assumed.
#
# Sibling of ResolvedModalHost, and for the same reason: a File.read of a fixed
# path answers a different question than the one it appears to ask. It reads
# whatever file it was pointed at, never the one Rails would render — and a fork
# and an adopted engine partial produce near-identical markup, so a source read
# cannot tell them apart.
#
# THIS ONE WAS A PARALLEL COPY, NOT A SHADOW. The app's picker lived at
# modals/_wallet_connect and the shared one at studio/modals/_wallet_connect —
# DIFFERENT virtual paths, so Rails resolution never collapsed them and the app
# copy simply won at every callsite. Both questions therefore matter: the shared
# path must not resolve into this app (a future shadow), and the old app path
# must not resolve at all (the fork coming back).
#
# THE SHARED COPY MOVED AGAIN on 2026-09-01 (/tasks/turf-rides-gem-modals):
# studio-engine handed the picker to solana-studio, so the resolved prefix below
# is solana_studio/modals rather than studio/modals. For a window both gems
# shipped it, and only resolution could say which one this app rendered;
# /tasks/drop-engine-web3-modals then closed the window, and studio-engine 0.67.0
# ships no studio/modals/_wallet_connect and no studio/solana at all. Resolution
# is still the right instrument, for a reason the window merely made obvious: it
# is the only one that answers "what does THIS APP render", and the next
# competing copy will not announce itself either.
#
# DO NOT ASSERT THE IDENTIFIER CONTAINS "/gems/". That encodes how the engine
# HAPPENS to be installed here and can never pass in studio-engine's own
# consumer-CI lane, which bundles the engine as a path checkout — a consumer
# assertion of that shape red-sealed a gem publish on 2026-08-27
# (/tasks/fix-picker-gem-path-assertion). The honest, install-agnostic assertion
# is that the picker does NOT resolve inside this app's own app/views.
#
# BUT "NOT IN THIS APP" IS ONLY HALF THE QUESTION, and until 2026-09-01 it read
# as the whole of it BY ACCIDENT. The only other copy in the bundle was
# studio-engine's, at studio/modals/_wallet_connect — a DIFFERENT virtual path,
# which Rails resolution can never collapse into this one. So "not shadowed by
# this app" was equivalent to "served by solana-studio" purely because the two
# namespaces happened to be disjoint, and the same check passed against EITHER
# gem while both shipped the partial. It proved nothing about which one served.
# /tasks/drop-engine-web3-modals then deleted the engine copy, taking the
# accident with it and leaving the negative assertion standing on nothing.
#
# WHAT THE NEGATIVE FORM CANNOT SEE is a competing copy at THIS virtual path:
# studio-engine re-adding app/views/solana_studio/modals/_wallet_connect, a
# third engine shipping one, or an initializer prepending a view path that
# carries one. None of those is inside app/views, so shadowed_by_app? calls
# every one of them innocent. served_by_gem? below is what sees them.
#
# ASK THE LOADED GEM WHERE IT LIVES rather than pattern-matching the install
# layout. SolanaStudio::Engine.paths["app/views"] is literally the path set the
# gem contributes to this app's lookup, so it is correct for a rubygems install
# and for a path checkout alike — the install-agnostic form of the assertion the
# paragraph above forbids, and the same shape solana-studio's own
# test/web3_modals_test.rb uses from its side of the seam.
#
# MEASURED, not reasoned, on 2026-09-01: loading the gem from a PATH CHECKOUT
# (/Users/alex/projects/solana-studio ahead of the installed copy) moves
# Engine.root and the resolved identifier together — served_by_gem? stays TRUE
# while the identifier contains no "/gems/" at all. The two forms disagree in
# exactly the lane that red-sealed the publish, and this one is the survivor.
#
# WHICH COPY WINS IS DECIDED BY VIEW-PATH ORDER, and that order is incidental.
# Engines PREPEND their views, so the last railtie to initialize lands nearest
# the front; measured in this desk on 2026-09-01 the lookup reads
# app/views, solana-studio, studio-engine, turbo-rails, actiontext,
# actionmailbox — solana-studio ahead of studio-engine only because the Gemfile
# names studio-engine on an earlier line. Swap those two lines and a re-added
# engine copy wins the lookup silently. That is the whole reason to assert the
# origin positively instead of trusting the arrangement.
module ResolvedWalletPicker
  APP_VIEWS = Rails.root.join("app/views").to_s

  # The deleted fork, and the path a re-fork would reappear at. Kept as a
  # constant so the test asserting its absence and the mutation that puts it
  # back name the same thing.
  FORK_PATH = Rails.root.join("app/views/modals/_wallet_connect.html.erb")

  # The view root the GEM ITSELF names, not one derived from where gems happen
  # to be installed. Empty if solana-studio ever stops contributing app/views,
  # which makes served_by_gem? answer FALSE rather than pass vacuously.
  GEM_VIEWS = (
    if defined?(SolanaStudio::Engine)
      SolanaStudio::Engine.paths["app/views"].existent.map(&:to_s)
    else
      []
    end
  ).freeze

  # What anything serving THIS virtual path must look like on disk, in whatever
  # directory it sits: the trailing directories solana_studio/modals, and the
  # file _wallet_connect.<handler>.
  #
  # THE NAMESPACE HALF IS NOT DECORATION — measured, not reasoned. A basename
  # filter alone looks exact and is not: studio-engine 0.67.0 ships
  # app/views/style/modals/_wallet_connect.html.erb, a thin demo configuration of
  # the picker rendered by the living style guide. Same basename, different
  # virtual path, and it lives in the ENGINE — so a capture filtered on the name
  # alone would pick it up on any page that mounted the style guide and report
  # the picker as served from outside the gem. The guard would fail on a correct
  # bundle, which is the worst failure a guard has.
  PARTIAL_DIR      = "solana_studio/modals"
  PARTIAL_BASENAME = "_wallet_connect"

  module_function

  def template
    ApplicationController.new.lookup_context.find("wallet_connect", [ "solana_studio/modals" ], true)
  end

  def identifier
    template.identifier
  end

  def source
    template.source
  end

  # True when the GEM path resolves to a file inside this app — i.e. someone
  # re-forked it as a shadow this time. Deliberately a prefix test on app/views.
  def shadowed_by_app?
    identifier.start_with?(APP_VIEWS)
  end

  # True when `identifier` sits under a view root the GEM contributes — the
  # POSITIVE half of the question shadowed_by_app? answers negatively.
  #
  # THE SEPARATOR IS LOAD-BEARING. A bare start_with? on the root also accepts a
  # sibling directory whose name merely BEGINS with it — solana-studio-0.5.4
  # against solana-studio-0.5.40 — and version bumps make that neighbour real.
  def served_by_gem?(identifier = self.identifier)
    GEM_VIEWS.any? { |root| identifier.start_with?(root + File::SEPARATOR) }
  end

  # Every file that ACTUALLY SERVED this partial while the block ran, absolute,
  # in render order.
  #
  # WHY NOT JUST #identifier. A fresh lookup_context answers "what WOULD resolve
  # now", which is the right question for a static guard and the wrong one for a
  # page that has already been rendered: the controller's own view paths may have
  # been prepended to since, and a compiled template is served from cache without
  # being re-resolved. ActiveSupport's render_partial payload carries the
  # identifier of the template that was actually RUN, so this reports the file
  # the reader's browser got rather than the one a lookup predicts.
  #
  # AN EMPTY RESULT IS NOT A PASS. A block that renders no picker at all — a
  # redirect to /signin, a layout that dropped the modal id — yields [], and
  # every "all of these are under the gem" assertion over [] is vacuously true.
  # Callers MUST assert the count before asserting the contents.
  def render_origins
    origins = []
    handle = ActiveSupport::Notifications.subscribe("render_partial.action_view") do |*, payload|
      served = payload[:identifier].to_s
      origins << served if serves_this_partial?(served)
    end

    yield
    origins
  ensure
    ActiveSupport::Notifications.unsubscribe(handle) if handle
  end

  # True when `path` is a file that could serve solana_studio/modals/wallet_connect
  # — namespace AND name, never the name alone. See PARTIAL_DIR.
  def serves_this_partial?(path)
    File.dirname(path).end_with?("/#{PARTIAL_DIR}") &&
      File.basename(path).start_with?("#{PARTIAL_BASENAME}.")
  end

  # True when the OLD app path still resolves — the fork is back where it was.
  def app_path_resolves?
    ApplicationController.new.lookup_context.find("wallet_connect", [ "modals" ], true)
    true
  rescue ActionView::MissingTemplate
    false
  end

  # Gem source with JS line-comments and ERB comments removed.
  #
  # WHY: the picker documents its own hooks by name in prose that SHIPS TO THE
  # PAGE — the x-data attribute carries // comments naming canPick, onBack and
  # startPhantomDeepLink, and an ERB comment block names them again. A bare-name
  # assertion is satisfied by the comment and stays green through a deletion of
  # the code it claims to cover.
  def code
    source.gsub(/<%#.*?%>/m, "").gsub(%r{^\s*//.*$}, "")
  end
end
