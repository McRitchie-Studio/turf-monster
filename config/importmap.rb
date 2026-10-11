# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "debug_logger"
pin "session_wipe"
pin "base58"
pin "wallet_provider"
pin "solana_utils"
pin "solana_errors"
pin "solana_stores"
pin "wallet_signal"
pin "cosign_signatures"
pin "cosign"
pin "lock_contest"
pin "turf_board"
pin "turbo_snapshot_cache"
pin "slate_simulator"
pin "state_fanout"
pin "cdp_offramp_send"
pin "page_experiments"

# Turf's Stimulus application (turf_stimulus) runs on every page. Every file
# under controllers/ and turf/ (their logic modules) is pinned. Only a module
# turf_stimulus imports statically is preloaded, and it is listed in
# every_page; a lazy controller and its modules are fetched by the page that
# names it. test/integration/turf_stimulus_test.rb holds this list to the
# import graph. Locals, not constants: this file is evaluated on every redraw.
pin "turf_stimulus"
pin "dev_tools", preload: false
every_page = %w[
  controllers/accordion_controller turf/accordion
  controllers/arrival_scroll_controller turf/arrival_scroll
  controllers/auto_submit_controller
  controllers/card_filter_controller turf/card_filter
  controllers/contest_chain_controller
  controllers/contest_rail_controller turf/contest_rail
  controllers/copy_link_controller turf/copy_link
  controllers/cost_calculator_controller turf/cost_calculator
  controllers/disclosure_controller turf/transition
  controllers/leaderboard_controller turf/leaderboard
  controllers/leaderboard_poll_controller turf/leaderboard_poll
  controllers/proof_of_reserves_controller turf/proof_of_reserves
  controllers/row_link_controller
  controllers/settled_filter_controller turf/settled_filter
  controllers/swatch_copy_controller turf/swatch_copy
  controllers/tabs_controller
]
%w[controllers turf].each do |directory|
  Rails.root.glob("app/javascript/#{directory}/*.js").sort.each do |file|
    name = "#{directory}/#{file.basename('.js')}"
    pin name, preload: every_page.include?(name)
  end
end
