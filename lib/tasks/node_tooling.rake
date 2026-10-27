# frozen_string_literal: true

# studio-engine ships the Node tooling package (Studio::NodeTooling); its
# `studio:node:link` and `studio:node:check` are the engine's tasks. Turf adds
# one prerequisite: refuse to link through a node_modules borrowed from another
# checkout (TurfMonster::NodeLinkGuard says why).
#
# NEVER run studio:node:link in a Heroku build or release phase. The slug needs
# no Node tooling (no Playwright, no node:test), and the link would point at a
# build-time gem path. The Procfile `release:` line and package.json scripts are
# held to that by test/lib/node_tooling_adoption_test.rb.
# No :environment, like the engine task it guards, so the guard is required here.
# It lives under lib/tasks/, which autoload_lib ignores, so Zeitwerk never owns it.
require_relative "support/node_link_guard"

namespace :turf do
  namespace :node do
    task :guard_shared_node_modules do
      refusal = TurfMonster::NodeLinkGuard.refusal(Rails.root)
      abort("turf-monster: #{refusal}") if refusal
    end
  end
end

task "studio:node:link" => "turf:node:guard_shared_node_modules"
