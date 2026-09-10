# The host URL helpers use when there is NO REQUEST to read one from — Turbo
# Stream broadcasts, background jobs, and anything else that renders through
# ApplicationController.render.
#
# Without this the route set falls back to ActionDispatch::Routing::RouteSet
# #default_env, which hard-codes host "example.org" and does not raise. That
# shipped https://example.org/rails/active_storage/blobs/redirect/... to real
# browsers for the contest live page's chat and leaderboard avatars, caught in a
# production LogRocket capture on 2026-09-07 (/tasks/blob-url-uses-example-org).
# The full mechanism is documented on TurfMonster::HostConfig#route_url_options.
#
# An initializer rather than three environment files: the derivation is one
# unit-tested method, so no environment can silently drift off it.
#
# This does NOT override a live request's host. RouteSet#url_for merges these
# UNDER the options its caller passes, and a controller's url_options already
# carry request.host — pinned by
# test/integration/request_host_wins_over_route_defaults_test.rb.
#
# Required explicitly, exactly as config/environments/production.rb does: the
# main autoloader is set up in Rails' Finisher, which runs AFTER
# load_config_initializers, so TurfMonster::HostConfig is not autoloadable here.
require Rails.root.join("lib/turf_monster/host_config").to_s

Rails.application.routes.default_url_options =
  TurfMonster::HostConfig.route_url_options(
    env:      Rails.env,
    app_host: ENV["APP_HOST"],
    app_port: ENV["APP_PORT"]
  )
