# frozen_string_literal: true

# THE WEB3 STEP-UP CARD THAT ACTUALLY RENDERS, resolved rather than assumed.
#
# Sibling of ResolvedWalletPicker and ResolvedPhantomDeeplink, and it exists for
# a sharper reason than either: the test that needed it used to read
#
#   Studio::Engine.root.join("app/views/studio/modals/_web3_step_up.html.erb")
#
# — a FIXED PATH INTO ANOTHER GEM. That answers "what does studio-engine ship?",
# never "what does this app render?", and the two stopped being the same question
# on 2026-09-01 when /tasks/turf-rides-gem-modals moved the card to solana-studio
# (solana_studio/modals/_web3_step_up). studio-engine went on shipping its copy
# until /tasks/drop-engine-web3-modals deleted it, so for the length of that
# window the old path still EXISTED and still READ — the fixed-path guard would
# have gone on passing while inspecting a partial this app no longer renders, and
# would then have died with ENOENT at wave 3 rather than at the change that broke
# it. studio-engine dropped both the card and studio/solana in 0.66.2 and has
# shipped neither since.
#
# Resolution is the only thing that can tell the two apart while both exist.
#
# DO NOT ASSERT THE IDENTIFIER CONTAINS "/gems/". That encodes how the gem
# HAPPENS to be installed here and can never pass in a consumer-CI lane that
# bundles it as a path checkout — a consumer assertion of that shape red-sealed a
# gem publish on 2026-08-27 (/tasks/fix-picker-gem-path-assertion). The honest,
# install-agnostic assertion is that the card does NOT resolve inside this app's
# own app/views.
module ResolvedWeb3StepUp
  APP_VIEWS = Rails.root.join("app/views").to_s

  # The deleted fork, and the path a re-fork would reappear at. Kept as a
  # constant so the test asserting its absence and the mutation that puts it back
  # name the same thing.
  FORK_PATH = Rails.root.join("app/views/modals/_web3_step_up.html.erb")

  module_function

  def template = ApplicationController.new.lookup_context.find("web3_step_up", [ "solana_studio/modals" ], true)
  def identifier = template.identifier
  def source     = template.source

  # True when the GEM path resolves to a file inside this app — i.e. someone
  # re-forked it as a shadow. Deliberately a prefix test on app/views.
  def shadowed_by_app? = identifier.start_with?(APP_VIEWS)
end
