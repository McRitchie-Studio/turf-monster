# The agent API's routes (docs/AGENT_API.md), drawn inside
# `namespace :api { namespace :v1 }` in config/routes.rb.
#
# They live here, not inline, because docs/workflows cites config/routes.rb by
# line number and test/docs/workflow_citation_docs_test.rb holds those
# citations: a route added inline re-pins every citation below it. Add a new
# API route to this file and nothing moves.
#
# `format: false` on each: a trailing ".html" is a 404, not a second spelling of
# the same endpoint. Contests and entries are addressed by slug.
get "me", to: "me#show", format: false

get "contests",                   to: "contests#index",       format: false
get "contests/:slug",             to: "contests#show",        format: false, as: :contest
get "contests/:slug/leaderboard", to: "contests#leaderboard", format: false, as: :contest_leaderboard
get "entries",                    to: "entries#index",        format: false
get "entries/:slug",              to: "entries#show",         format: false, as: :entry

# Writes. An entry is created whole and funded in one call (no cart), and its
# picks can be replaced until the contest locks.
post  "contests/:slug/entries", to: "entries#create", format: false, as: :contest_entries
patch "entries/:slug",          to: "entries#update", format: false
