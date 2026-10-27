# frozen_string_literal: true

# Run `node` so an app module can import by its importmap name ("studio/studio_confetti",
# "turf/scoring", "wallet_signal"), through studio-engine's shared node:test hook
# (test/javascript/support/register.mjs).
#
# STUDIO_NODE_TOOLING points register.mjs at the engine package in the bundled gem,
# because CI's `test` job runs no `npm ci` and so has no node_modules link.
module NodeImportmap
  REGISTER = Rails.root.join("test/javascript/support/register.mjs").to_s

  module_function

  def env = { "STUDIO_NODE_TOOLING" => Studio::NodeTooling.root.to_s }

  def args = ["--import", REGISTER]
end
