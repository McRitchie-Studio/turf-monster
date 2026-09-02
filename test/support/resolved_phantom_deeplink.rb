# frozen_string_literal: true

# THE PHANTOM MOBILE DEEP LINK THAT ACTUALLY RENDERS, resolved rather than assumed.
#
# Sibling of ResolvedWalletPicker and ResolvedModalHost, for the same reason: a
# File.read of a fixed path answers a different question than the one it appears
# to ask. It reads whatever file it was pointed at, never the one Rails would
# render.
#
# TWO HALVES WERE ADOPTED, and they resolve through different mechanisms, so this
# module covers both:
#
#   the deep link  solana_studio/_phantom_deeplink — a PARTIAL, rendered by
#                  shared/_alpine_factories. It replaced a JAVASCRIPT MODULE
#                  (app/javascript/phantom_deeplink.js, loaded via the importmap),
#                  so there was never a competing view path — the fork's ghost is
#                  a file on disk and two loader lines, not a template. It sat at
#                  studio/solana/_phantom_deeplink in studio-engine until
#                  /tasks/turf-rides-gem-modals moved it to solana-studio; the
#                  engine kept its copy until wave 3 deleted it, and for that
#                  window BOTH paths resolved with only this lookup able to say
#                  which one the app rendered. studio-engine dropped
#                  studio/solana in 0.66.2 and has shipped no such directory
#                  since.
#   the callback   solana_sessions/phantom_callback — a full TEMPLATE, and this
#                  one WAS a shadow: the app's copy sat at the identical virtual
#                  path and won resolution outright, leaving the engine's inert.
#                  Deleting it is the whole of what hands the engine control.
#                  IT STAYS IN studio-engine — the gem move took the deep link
#                  only. The two are a matched signing pair (both read
#                  Studio.wallet_sign_in_statement, unparameterized), which is
#                  why the studio-engine floor survives this migration intact.
#
# DO NOT ASSERT THE IDENTIFIER CONTAINS "/gems/". That encodes how the engine
# HAPPENS to be installed here and can never pass in studio-engine's own
# consumer-CI lane, which bundles the engine as a path checkout — a consumer
# assertion of that shape red-sealed a gem publish on 2026-08-27
# (/tasks/fix-picker-gem-path-assertion). The honest, install-agnostic assertion
# is that neither half resolves inside this app's own app/views.
module ResolvedPhantomDeeplink
  APP_VIEWS = Rails.root.join("app/views").to_s

  # The deleted fork, and the path a re-fork would reappear at. Kept as constants
  # so the test asserting their absence and the mutation that puts them back name
  # the same thing.
  FORK_JS   = Rails.root.join("app/javascript/phantom_deeplink.js")
  FORK_VIEW = Rails.root.join("app/views/solana_sessions/phantom_callback.html.erb")

  module_function

  def lookup = ApplicationController.new.lookup_context

  def template  = lookup.find("phantom_deeplink", [ "solana_studio" ], true)
  def identifier = template.identifier
  def source     = template.source

  def callback_template  = lookup.find("phantom_callback", [ "solana_sessions" ], false)
  def callback_identifier = callback_template.identifier
  def callback_source     = callback_template.source

  # True when the shared path resolves to a file inside this app — i.e. someone
  # re-forked it as a shadow. Deliberately a prefix test on app/views.
  def shadowed_by_app?          = identifier.start_with?(APP_VIEWS)
  def callback_shadowed_by_app? = callback_identifier.start_with?(APP_VIEWS)

  # Shared source with ERB comments and JS line-comments removed.
  #
  # WHY: BOTH halves document themselves by name in prose that SHIPS TO THE PAGE.
  # The partial's script carries `// Phantom deep link protocol for mobile
  # browsers` and names encodeBase58, nacl and startPhantomDeepLink in running
  # comments; its ERB header names the function twice more. A bare-name assertion
  # is satisfied by the comment and stays green through a deletion of the code it
  # claims to cover — three times in three repos this month.
  #
  # The stripper is itself checked: see the "the stripper leaves the code behind"
  # test, which asserts it removed prose AND kept a body. A stripper that ate the
  # file would make every assertion below vacuously true.
  def code(text) = text.gsub(/<%#.*?%>/m, "").gsub(%r{^\s*//.*$}, "")

  def deeplink_code = code(source)
  def callback_code = code(callback_source)
end
