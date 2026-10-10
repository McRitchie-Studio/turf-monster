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

# Turf's Stimulus application (turf_stimulus) runs on every page. Its
# controllers are fetched by the pages that name them, and their logic modules
# (app/javascript/turf) with them, so neither is preloaded.
pin "turf_stimulus"
pin_all_from "app/javascript/controllers", under: "controllers", preload: false
pin_all_from "app/javascript/turf", under: "turf", preload: false
