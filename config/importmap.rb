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
every_page = %w[]
%w[controllers turf].each do |directory|
  Rails.root.glob("app/javascript/#{directory}/*.js").sort.each do |file|
    name = "#{directory}/#{file.basename('.js')}"
    pin name, preload: every_page.include?(name)
  end
end
