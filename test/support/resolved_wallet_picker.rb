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
# is solana_studio/modals rather than studio/modals. studio-engine still SHIPS
# its copy until /tasks/drop-engine-web3-modals deletes it, which is exactly why
# this module resolves the path instead of reading a file: during that window
# BOTH paths exist and only resolution can say which one this app renders.
#
# DO NOT ASSERT THE IDENTIFIER CONTAINS "/gems/". That encodes how the engine
# HAPPENS to be installed here and can never pass in studio-engine's own
# consumer-CI lane, which bundles the engine as a path checkout — a consumer
# assertion of that shape red-sealed a gem publish on 2026-08-27
# (/tasks/fix-picker-gem-path-assertion). The honest, install-agnostic assertion
# is that the picker does NOT resolve inside this app's own app/views.
module ResolvedWalletPicker
  APP_VIEWS = Rails.root.join("app/views").to_s

  # The deleted fork, and the path a re-fork would reappear at. Kept as a
  # constant so the test asserting its absence and the mutation that puts it
  # back name the same thing.
  FORK_PATH = Rails.root.join("app/views/modals/_wallet_connect.html.erb")

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
