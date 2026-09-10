# frozen_string_literal: true

# THE MODAL HOST THAT ACTUALLY RENDERS, resolved rather than assumed.
#
# studio-engine is a NON-ISOLATED Rails engine, so an app view at the SAME
# virtual path shadows the engine's. This app carried exactly that shadow at
# app/views/studio/modals/_host.html.erb until 2026-08-28 (defork-turf-modal-host),
# and it is why several tests could read a hardcoded app path and look correct.
#
# THE BUG THAT SHAPE HIDES. A test that File.reads a fixed path answers a
# different question than the one it appears to ask: it reads whatever file it
# was pointed at, never the one Rails would render. Both a fork and an adopted
# engine partial produce the same markup, so a source read cannot tell them
# apart — which is what let the duplication survive as long as it did.
#
# ASK THE RESOLVER INSTEAD. lookup_context.find is the same lookup a render
# performs, so its identifier is the file the page actually gets, in whatever
# order the view paths happen to be stacked.
#
# DO NOT ASSERT THE IDENTIFIER CONTAINS "/gems/". That encodes how the engine
# HAPPENS to be installed here, and it can never pass in studio-engine's own
# consumer-CI lane, which bundles the engine as a path checkout — a consumer
# assertion of that shape red-sealed a gem publish on 2026-08-27
# (/tasks/fix-picker-gem-path-assertion). The honest, install-agnostic
# assertion is that the host does NOT resolve inside this app's own app/views.
module ResolvedModalHost
  APP_VIEWS = Rails.root.join("app/views").to_s

  # The path this app WOULD shadow the engine at. Kept as a constant so the
  # tests that assert its absence, and the mutation that puts it back, name the
  # same thing.
  SHADOW_PATH = Rails.root.join("app/views/studio/modals/_host.html.erb")

  module_function

  def template
    ApplicationController.new.lookup_context.find("host", [ "studio/modals" ], true)
  end

  def identifier
    template.identifier
  end

  def source
    template.source
  end

  # True when the render resolves to a file inside this app — i.e. the shadow is
  # back. Deliberately a prefix test on app/views and nothing else.
  def shadowed_by_app?
    identifier.start_with?(APP_VIEWS)
  end
end
