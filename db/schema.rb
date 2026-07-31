# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_30_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "aeropay_purchases", force: :cascade do |t|
    t.string "aeropay_reference"
    t.string "aeropay_transaction_id"
    t.datetime "captured_at"
    t.string "contest_slug"
    t.datetime "created_at", null: false
    t.text "mint_tx_signatures"
    t.datetime "minted_at"
    t.string "pack_id", null: false
    t.integer "price_cents", null: false
    t.integer "quantity", default: 1, null: false
    t.string "refund_reason"
    t.datetime "refunded_at"
    t.string "slug", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "wallet_address"
    t.index ["aeropay_reference"], name: "index_aeropay_purchases_on_aeropay_reference", unique: true
    t.index ["aeropay_transaction_id"], name: "index_aeropay_purchases_on_aeropay_transaction_id", unique: true
    t.index ["slug"], name: "index_aeropay_purchases_on_slug", unique: true
    t.index ["user_id"], name: "index_aeropay_purchases_on_user_id"
  end

  create_table "arenas", force: :cascade do |t|
    t.string "address"
    t.string "city"
    t.string "country"
    t.datetime "created_at", null: false
    t.string "location"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "state"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_arenas_on_slug", unique: true
  end

  create_table "cdp_ramp_transactions", force: :cascade do |t|
    t.string "asset", default: "USDC", null: false
    t.datetime "broadcast_at"
    t.datetime "cashout_deadline_at"
    t.string "cdp_status"
    t.string "coinbase_transaction_id"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.string "network", default: "solana", null: false
    t.string "partner_user_ref"
    t.string "payment_method"
    t.jsonb "raw_payload", default: {}
    t.datetime "returned_at"
    t.string "sell_amount_currency"
    t.decimal "sell_amount_value", precision: 30, scale: 12
    t.string "sent_signature"
    t.string "status", default: "initiated", null: false
    t.string "to_address"
    t.string "tx_hash"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "wallet_address", null: false
    t.string "wallet_mode", null: false
    t.index ["coinbase_transaction_id"], name: "index_cdp_ramp_transactions_on_coinbase_transaction_id", unique: true
    t.index ["partner_user_ref"], name: "index_cdp_ramp_transactions_on_partner_user_ref", unique: true
    t.index ["status", "direction"], name: "index_cdp_ramp_transactions_on_status_and_direction"
    t.index ["user_id"], name: "index_cdp_ramp_transactions_on_user_id"
  end

  create_table "coinflow_purchases", force: :cascade do |t|
    t.datetime "captured_at"
    t.string "coinflow_payment_id"
    t.string "coinflow_reference"
    t.string "contest_slug"
    t.datetime "created_at", null: false
    t.text "mint_tx_signatures"
    t.datetime "minted_at"
    t.string "pack_id", null: false
    t.integer "price_cents", null: false
    t.integer "quantity", default: 1, null: false
    t.string "refund_reason"
    t.datetime "refunded_at"
    t.string "slug", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "wallet_address"
    t.index ["coinflow_payment_id"], name: "index_coinflow_purchases_on_coinflow_payment_id", unique: true
    t.index ["coinflow_reference"], name: "index_coinflow_purchases_on_coinflow_reference", unique: true
    t.index ["slug"], name: "index_coinflow_purchases_on_slug", unique: true
    t.index ["user_id"], name: "index_coinflow_purchases_on_user_id"
  end

  create_table "contest_slates", force: :cascade do |t|
    t.bigint "contest_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", default: 1, null: false
    t.bigint "slate_id", null: false
    t.datetime "updated_at", null: false
    t.index ["contest_id", "position"], name: "index_contest_slates_on_contest_id_and_position", unique: true
    t.index ["contest_id", "slate_id"], name: "index_contest_slates_on_contest_id_and_slate_id", unique: true
    t.index ["contest_id"], name: "index_contest_slates_on_contest_id"
    t.index ["slate_id"], name: "index_contest_slates_on_slate_id"
  end

  create_table "contests", force: :cascade do |t|
    t.boolean "accepts_usdt", default: false, null: false
    t.boolean "chat_enabled", default: true, null: false
    t.datetime "concludes_at"
    t.string "contest_type", default: "small", null: false
    t.datetime "created_at", null: false
    t.integer "entry_fee_cents", default: 0, null: false
    t.string "game_type", default: "turf_totals", null: false
    t.string "locks_at_date_selected"
    t.string "locks_at_time_selected"
    t.string "locks_at_timezone_selected"
    t.integer "max_entries"
    t.string "name", null: false
    t.boolean "onchain_cancelled", default: false, null: false
    t.boolean "onchain_closed", default: false, null: false
    t.string "onchain_contest_id"
    t.boolean "onchain_settled", default: false, null: false
    t.string "onchain_tx_signature"
    t.integer "rank"
    t.integer "season_id"
    t.bigint "slate_id"
    t.string "slug"
    t.datetime "starts_at"
    t.string "status", default: "pending", null: false
    t.string "tagline"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["game_type"], name: "index_contests_on_game_type"
    t.index ["rank"], name: "index_contests_on_rank"
    t.index ["slate_id"], name: "index_contests_on_slate_id"
    t.index ["slug"], name: "index_contests_on_slug", unique: true
    t.index ["status"], name: "index_contests_on_status"
    t.index ["user_id"], name: "index_contests_on_user_id"
  end

  create_table "email_deliveries", force: :cascade do |t|
    t.string "action", null: false
    t.jsonb "args", default: [], null: false
    t.datetime "created_at", null: false
    t.string "email_key", null: false
    t.text "error"
    t.jsonb "kwargs", default: {}, null: false
    t.string "mailer", null: false
    t.boolean "sent", default: false, null: false
    t.datetime "sent_at"
    t.string "to"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["created_at"], name: "index_email_deliveries_on_created_at"
    t.index ["email_key"], name: "index_email_deliveries_on_email_key"
    t.index ["sent"], name: "index_email_deliveries_on_sent"
    t.index ["user_id"], name: "index_email_deliveries_on_user_id"
  end

  create_table "entries", force: :cascade do |t|
    t.bigint "contest_id", null: false
    t.datetime "created_at", null: false
    t.integer "eliminated_round"
    t.integer "entry_number"
    t.string "onchain_entry_id"
    t.string "onchain_tx_signature"
    t.integer "payout_cents", default: 0
    t.integer "rank"
    t.float "score", default: 0.0, null: false
    t.string "slug"
    t.string "status", default: "cart", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.datetime "winner_notified_at"
    t.index ["contest_id", "status"], name: "index_entries_on_contest_id_and_status"
    t.index ["contest_id"], name: "index_entries_on_contest_id"
    t.index ["onchain_tx_signature"], name: "index_entries_on_onchain_tx_signature_unique", unique: true, where: "(onchain_tx_signature IS NOT NULL)"
    t.index ["slug"], name: "index_entries_on_slug", unique: true
    t.index ["status"], name: "index_entries_on_status"
    t.index ["user_id", "contest_id", "entry_number"], name: "index_entries_on_user_contest_entry_number", unique: true, where: "(entry_number IS NOT NULL)"
    t.index ["user_id", "contest_id"], name: "index_entries_on_user_id_and_contest_id"
    t.index ["user_id"], name: "index_entries_on_user_id"
  end

  create_table "error_logs", force: :cascade do |t|
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.text "inspect"
    t.text "message", null: false
    t.bigint "parent_id"
    t.string "parent_name"
    t.string "parent_type"
    t.string "slug"
    t.bigint "target_id"
    t.string "target_name"
    t.string "target_type"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_error_logs_on_created_at"
    t.index ["parent_type", "parent_id"], name: "index_error_logs_on_parent_type_and_parent_id"
    t.index ["target_type", "target_id"], name: "index_error_logs_on_target_type_and_target_id"
  end

  create_table "games", force: :cascade do |t|
    t.string "advancing_team_slug"
    t.integer "away_score"
    t.string "away_team_slug", null: false
    t.datetime "created_at", null: false
    t.integer "home_score"
    t.string "home_team_slug", null: false
    t.datetime "kickoff_at"
    t.string "slug", null: false
    t.string "status", default: "scheduled"
    t.bigint "survivor_round_id"
    t.datetime "updated_at", null: false
    t.string "venue"
    t.index ["away_team_slug"], name: "index_games_on_away_team_slug"
    t.index ["home_team_slug"], name: "index_games_on_home_team_slug"
    t.index ["slug"], name: "index_games_on_slug", unique: true
    t.index ["status"], name: "index_games_on_status"
    t.index ["survivor_round_id"], name: "index_games_on_survivor_round_id"
  end

  create_table "geo_settings", force: :cascade do |t|
    t.string "app_name", null: false
    t.jsonb "banned_states", default: []
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.string "slug"
    t.datetime "updated_at", null: false
    t.index ["app_name"], name: "index_geo_settings_on_app_name", unique: true
    t.index ["slug"], name: "index_geo_settings_on_slug", unique: true
  end

  create_table "goals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "game_slug", null: false
    t.integer "minute"
    t.string "player_slug"
    t.string "slug", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["game_slug"], name: "index_goals_on_game_slug"
    t.index ["player_slug"], name: "index_goals_on_player_slug"
    t.index ["slug"], name: "index_goals_on_slug", unique: true
    t.index ["team_slug"], name: "index_goals_on_team_slug"
  end

  create_table "image_caches", force: :cascade do |t|
    t.integer "bytes"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "owner_id"
    t.string "owner_type"
    t.string "purpose", null: false
    t.string "s3_key", null: false
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.string "variant", null: false
    t.index ["owner_type", "owner_id", "purpose", "variant"], name: "idx_image_caches_owner_purpose_variant", unique: true
    t.index ["owner_type", "owner_id"], name: "index_image_caches_on_owner"
    t.index ["s3_key"], name: "index_image_caches_on_s3_key", unique: true
  end

  create_table "impersonation_logs", force: :cascade do |t|
    t.integer "action", default: 0, null: false
    t.integer "admin_id", null: false
    t.datetime "created_at", null: false
    t.string "ip"
    t.string "reason"
    t.integer "target_user_id", null: false
    t.string "user_agent"
    t.index ["admin_id", "created_at"], name: "index_impersonation_logs_on_admin_id_and_created_at"
  end

  create_table "landing_pages", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.string "background_style", default: "gradient", null: false
    t.string "badge"
    t.bigint "contest_id"
    t.datetime "created_at", null: false
    t.string "cta_label"
    t.string "headline"
    t.string "name", null: false
    t.string "slug"
    t.text "subheadline"
    t.datetime "updated_at", null: false
    t.index ["contest_id"], name: "index_landing_pages_on_contest_id"
    t.index ["slug"], name: "index_landing_pages_on_slug", unique: true
  end

  create_table "magic_links", force: :cascade do |t|
    t.boolean "age_attested", default: false, null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.string "return_to"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_magic_links_on_expires_at"
    t.index ["token"], name: "index_magic_links_on_token", unique: true
  end

  create_table "market_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "dataset_path", null: false
    t.integer "derived_count", default: 0, null: false
    t.integer "posted_count", default: 0, null: false
    t.integer "row_count", default: 0, null: false
    t.string "source", null: false
    t.string "source_url"
    t.string "sport", null: false
    t.datetime "updated_at", null: false
    t.integer "week"
    t.integer "year", null: false
    t.index ["sport", "year", "week"], name: "index_market_snapshots_on_sport_and_year_and_week"
  end

  create_table "messages", force: :cascade do |t|
    t.text "body", null: false
    t.bigint "contest_id", null: false
    t.datetime "created_at", null: false
    t.datetime "hidden_at"
    t.bigint "hidden_by_id"
    t.boolean "system", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["contest_id", "created_at"], name: "index_messages_on_contest_id_and_created_at"
    t.index ["contest_id", "user_id", "system"], name: "index_messages_on_contest_user_system", where: "system"
    t.index ["hidden_by_id"], name: "index_messages_on_hidden_by_id", where: "(hidden_by_id IS NOT NULL)"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "nfl_team_total_projections", force: :cascade do |t|
    t.string "basis"
    t.datetime "cached_at", null: false
    t.datetime "created_at", null: false
    t.decimal "expected_points", precision: 5, scale: 2, null: false
    t.decimal "favorite_spread", precision: 5, scale: 2, null: false
    t.string "favorite_team_slug", null: false
    t.string "game_slug", null: false
    t.decimal "game_total", precision: 5, scale: 2, null: false
    t.boolean "home", null: false
    t.decimal "home_spread", precision: 5, scale: 2, null: false
    t.bigint "market_snapshot_id"
    t.string "opponent_team_slug", null: false
    t.integer "over_odds"
    t.decimal "posted_line", precision: 5, scale: 2
    t.bigint "slate_id"
    t.string "source", null: false
    t.date "source_published_on"
    t.text "source_text"
    t.string "source_url"
    t.string "team_slug", null: false
    t.integer "under_odds"
    t.datetime "updated_at", null: false
    t.integer "week", null: false
    t.integer "year", null: false
    t.index ["market_snapshot_id"], name: "index_nfl_team_total_projections_on_market_snapshot_id"
    t.index ["slate_id"], name: "index_nfl_team_total_projections_on_slate_id"
    t.index ["source"], name: "index_nfl_team_total_projections_on_source"
    t.index ["year", "week", "expected_points"], name: "idx_on_year_week_expected_points_24fdabb3b7"
    t.index ["year", "week", "game_slug", "team_slug"], name: "index_nfl_team_totals_unique_team_game", unique: true
    t.index ["year", "week", "team_slug"], name: "idx_on_year_week_team_slug_9bdbdd9d2c"
  end

  create_table "outbound_requests", force: :cascade do |t|
    t.integer "acting_admin_id"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "endpoint"
    t.string "error_class"
    t.text "error_message"
    t.string "method"
    t.jsonb "request_body", default: {}
    t.jsonb "response_body", default: {}
    t.string "service", null: false
    t.bigint "source_id"
    t.string "source_type"
    t.integer "status_code"
    t.bigint "user_id"
    t.index ["acting_admin_id"], name: "index_outbound_requests_on_acting_admin_id", where: "(acting_admin_id IS NOT NULL)"
    t.index ["created_at"], name: "index_outbound_requests_on_created_at"
    t.index ["error_class"], name: "index_outbound_requests_on_error_class", where: "(error_class IS NOT NULL)"
    t.index ["service", "created_at"], name: "index_outbound_requests_on_service_and_created_at"
    t.index ["source_type", "source_id"], name: "index_outbound_requests_on_source_type_and_source_id"
    t.index ["user_id"], name: "index_outbound_requests_on_user_id", where: "(user_id IS NOT NULL)"
  end

  create_table "paypal_purchases", force: :cascade do |t|
    t.string "capture_id"
    t.datetime "captured_at"
    t.string "contest_slug"
    t.datetime "created_at", null: false
    t.text "mint_tx_signatures"
    t.datetime "minted_at"
    t.string "pack_id", null: false
    t.string "paypal_order_id"
    t.integer "price_cents", null: false
    t.integer "quantity", default: 1, null: false
    t.string "refund_reason"
    t.datetime "refunded_at"
    t.string "slug", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "wallet_address"
    t.index ["capture_id"], name: "index_paypal_purchases_on_capture_id"
    t.index ["paypal_order_id"], name: "index_paypal_purchases_on_paypal_order_id", unique: true
    t.index ["slug"], name: "index_paypal_purchases_on_slug", unique: true
    t.index ["user_id"], name: "index_paypal_purchases_on_user_id"
  end

  create_table "pending_transactions", force: :cascade do |t|
    t.string "cosigner_address"
    t.datetime "created_at", null: false
    t.string "initiator_address"
    t.jsonb "metadata", default: {}
    t.text "serialized_tx", null: false
    t.string "slug"
    t.string "status", default: "pending", null: false
    t.bigint "target_id"
    t.string "target_type"
    t.string "tx_signature"
    t.string "tx_type", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_pending_transactions_on_slug", unique: true
    t.index ["status"], name: "index_pending_transactions_on_status"
    t.index ["target_type", "target_id"], name: "index_pending_transactions_on_target"
    t.index ["tx_signature"], name: "index_pending_transactions_on_tx_signature_unique", unique: true, where: "(tx_signature IS NOT NULL)"
  end

  create_table "players", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "jersey_number"
    t.string "name", null: false
    t.string "position"
    t.string "slug", null: false
    t.string "team_slug"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_players_on_slug", unique: true
    t.index ["team_slug"], name: "index_players_on_team_slug"
  end

  create_table "reactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "emoji", null: false
    t.bigint "message_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["message_id", "user_id", "emoji"], name: "index_reactions_uniqueness", unique: true
    t.index ["message_id"], name: "index_reactions_on_message_id"
    t.index ["user_id"], name: "index_reactions_on_user_id"
  end

  create_table "season_configs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "current_season_id", default: 0, null: false
    t.bigint "main_contest_id"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["main_contest_id"], name: "index_season_configs_on_main_contest_id"
    t.index ["slug"], name: "index_season_configs_on_slug", unique: true
  end

  create_table "selections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "entry_id", null: false
    t.decimal "points", precision: 5, scale: 1
    t.bigint "slate_matchup_id", null: false
    t.string "slug"
    t.datetime "updated_at", null: false
    t.index ["entry_id", "slate_matchup_id"], name: "index_selections_on_entry_id_and_slate_matchup_id", unique: true
    t.index ["entry_id"], name: "index_selections_on_entry_id"
    t.index ["slate_matchup_id"], name: "index_selections_on_slate_matchup_id"
    t.index ["slug"], name: "index_selections_on_slug", unique: true
  end

  create_table "site_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_og_description"
    t.string "default_og_title"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_site_settings_on_slug", unique: true
  end

  create_table "slate_matchups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "expected_score", precision: 3, scale: 1
    t.string "game_slug"
    t.integer "goals"
    t.string "opponent_team_slug"
    t.integer "rank"
    t.bigint "slate_id", null: false
    t.string "slug"
    t.string "status", default: "pending", null: false
    t.string "team_slug", null: false
    t.integer "team_total_over_odds"
    t.integer "team_total_under_odds"
    t.decimal "turf_score", precision: 3, scale: 1
    t.datetime "updated_at", null: false
    t.integer "week"
    t.index ["game_slug"], name: "index_slate_matchups_on_game_slug"
    t.index ["slate_id", "team_slug", "game_slug"], name: "index_slate_matchups_on_slate_team_and_game", unique: true
    t.index ["slate_id", "week"], name: "index_slate_matchups_on_slate_id_and_week"
    t.index ["slate_id"], name: "index_slate_matchups_on_slate_id"
    t.index ["slug"], name: "index_slate_matchups_on_slug", unique: true
    t.index ["status"], name: "index_slate_matchups_on_status"
  end

  create_table "slates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "formula_a"
    t.float "formula_goal_base"
    t.float "formula_goal_scale"
    t.float "formula_line_exp"
    t.float "formula_mult_base"
    t.float "formula_mult_scale"
    t.float "formula_prob_exp"
    t.string "name", null: false
    t.string "slug"
    t.string "sport"
    t.datetime "starts_at"
    t.datetime "updated_at", null: false
    t.integer "week"
    t.integer "year"
    t.index ["slug"], name: "index_slates_on_slug", unique: true
    t.index ["week"], name: "index_slates_on_week"
    t.index ["year", "week"], name: "index_slates_on_year_and_week"
  end

  create_table "stripe_purchases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "mint_tx_signatures"
    t.datetime "minted_at"
    t.integer "price_cents", null: false
    t.integer "quantity", default: 1, null: false
    t.string "refund_reason"
    t.datetime "refunded_at"
    t.string "slug", null: false
    t.string "status", default: "pending", null: false
    t.string "stripe_charge_id"
    t.string "stripe_customer_id"
    t.string "stripe_session_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["slug"], name: "index_stripe_purchases_on_slug", unique: true
    t.index ["stripe_session_id"], name: "index_stripe_purchases_on_stripe_session_id", unique: true
    t.index ["user_id"], name: "index_stripe_purchases_on_user_id"
  end

  create_table "studio_links", force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "kind", null: false
    t.bigint "linkable_id"
    t.string "linkable_type"
    t.jsonb "metadata", default: {}, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_studio_links_on_kind"
    t.index ["linkable_type", "linkable_id", "kind"], name: "idx_studio_links_owner_kind"
    t.index ["token"], name: "index_studio_links_on_token", unique: true
  end

  create_table "survivor_picks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "entry_id", null: false
    t.string "result", default: "pending", null: false
    t.string "slug"
    t.bigint "survivor_round_id", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id", "survivor_round_id"], name: "index_survivor_picks_on_entry_and_round", unique: true
    t.index ["entry_id", "team_slug"], name: "index_survivor_picks_on_entry_and_team", unique: true
    t.index ["entry_id"], name: "index_survivor_picks_on_entry_id"
    t.index ["slug"], name: "index_survivor_picks_on_slug", unique: true
    t.index ["survivor_round_id"], name: "index_survivor_picks_on_survivor_round_id"
    t.index ["team_slug"], name: "index_survivor_picks_on_team_slug"
  end

  create_table "survivor_rounds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "number", null: false
    t.datetime "picks_lock_at"
    t.string "slug"
    t.string "stage", default: "group", null: false
    t.string "status", default: "upcoming", null: false
    t.datetime "updated_at", null: false
    t.index ["number"], name: "index_survivor_rounds_on_number", unique: true
    t.index ["slug"], name: "index_survivor_rounds_on_slug", unique: true
    t.index ["status"], name: "index_survivor_rounds_on_status"
  end

  create_table "teams", force: :cascade do |t|
    t.string "coaches_url"
    t.string "color_alt"
    t.string "color_dark"
    t.string "color_dark_alt"
    t.string "color_disposition", default: "dark", null: false
    t.string "color_grey"
    t.string "color_light"
    t.string "color_light_alt"
    t.string "conference"
    t.datetime "created_at", null: false
    t.string "division"
    t.string "emoji"
    t.string "hashtag"
    t.string "hashtag2"
    t.string "home_arena_slug"
    t.string "league"
    t.string "location"
    t.string "logo_path"
    t.string "logo_source"
    t.string "logo_url"
    t.string "mascot"
    t.string "name", null: false
    t.jsonb "rivals", default: [], null: false
    t.string "short_name"
    t.string "slug", null: false
    t.string "sport"
    t.string "team_website"
    t.datetime "updated_at", null: false
    t.string "x_handle"
    t.index ["home_arena_slug"], name: "index_teams_on_home_arena_slug"
    t.index ["slug"], name: "index_teams_on_slug", unique: true
    t.index ["sport", "league"], name: "index_teams_on_sport_and_league"
  end

  create_table "theme_settings", force: :cascade do |t|
    t.string "accent1"
    t.string "accent2"
    t.string "app_name", null: false
    t.datetime "created_at", null: false
    t.string "danger"
    t.string "dark"
    t.string "light"
    t.string "primary"
    t.string "slug"
    t.datetime "updated_at", null: false
    t.string "warning"
    t.index ["app_name"], name: "index_theme_settings_on_app_name", unique: true
  end

  create_table "transaction_logs", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.integer "balance_after_cents"
    t.datetime "created_at", null: false
    t.string "description"
    t.string "direction", null: false
    t.jsonb "metadata", default: {}
    t.string "moonpay_tx_id"
    t.string "onchain_tx"
    t.string "slug"
    t.bigint "source_id"
    t.string "source_name"
    t.string "source_type"
    t.string "status", default: "completed", null: false
    t.string "stripe_session_id"
    t.string "transaction_type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["moonpay_tx_id"], name: "index_transaction_logs_on_moonpay_tx_id_unique", unique: true, where: "(moonpay_tx_id IS NOT NULL)"
    t.index ["slug"], name: "index_transaction_logs_on_slug", unique: true
    t.index ["source_type", "source_id"], name: "index_transaction_logs_on_source_type_and_source_id"
    t.index ["status"], name: "index_transaction_logs_on_status"
    t.index ["stripe_session_id"], name: "index_transaction_logs_on_stripe_session_id_unique", unique: true, where: "(stripe_session_id IS NOT NULL)"
    t.index ["transaction_type"], name: "index_transaction_logs_on_transaction_type"
    t.index ["user_id", "status"], name: "index_transaction_logs_on_user_id_and_status"
    t.index ["user_id", "transaction_type"], name: "index_transaction_logs_on_user_id_and_type"
    t.index ["user_id"], name: "index_transaction_logs_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "age_attested_at"
    t.date "birth_date"
    t.integer "birth_year"
    t.boolean "contest_entered", default: false, null: false
    t.datetime "created_at", null: false
    t.date "date_of_birth"
    t.string "email"
    t.datetime "email_verified_at"
    t.text "encrypted_web2_solana_private_key"
    t.datetime "export_initiated_at"
    t.datetime "first_chat_message_at"
    t.string "first_name"
    t.datetime "frozen_at"
    t.string "frozen_reason"
    t.bigint "invited_by_id"
    t.integer "invitees_count", default: 0, null: false
    t.integer "invitees_in_contest_count", default: 0, null: false
    t.jsonb "ips", default: {}, null: false
    t.datetime "joined_email_list_at"
    t.string "last_name"
    t.datetime "last_seen_at"
    t.datetime "left_email_list_at"
    t.integer "level", default: 1, null: false
    t.string "name"
    t.string "password_digest", default: "", null: false
    t.boolean "payment_risk_flag", default: false, null: false
    t.string "provider"
    t.string "reference"
    t.string "role", default: "viewer"
    t.integer "seeds", default: 0, null: false
    t.datetime "self_custodied_at"
    t.string "session_token"
    t.string "slug"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.string "username"
    t.datetime "username_changed_at"
    t.string "web2_solana_address"
    t.string "web3_solana_address"
    t.index "lower((username)::text)", name: "index_users_on_lower_username", unique: true, where: "(username IS NOT NULL)"
    t.index ["contest_entered"], name: "index_users_on_contest_entered_true", where: "(contest_entered = true)"
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["frozen_at"], name: "index_users_on_frozen_at", where: "(frozen_at IS NOT NULL)"
    t.index ["invited_by_id"], name: "index_users_on_invited_by_id"
    t.index ["ips"], name: "index_users_on_ips", using: :gin
    t.index ["joined_email_list_at"], name: "index_users_on_joined_email_list_at"
    t.index ["last_seen_at"], name: "index_users_on_last_seen_at"
    t.index ["left_email_list_at"], name: "index_users_on_left_email_list_at"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "(provider IS NOT NULL)"
    t.index ["reference"], name: "index_users_on_reference"
    t.index ["seeds"], name: "index_users_on_seeds"
    t.index ["self_custodied_at"], name: "index_users_on_self_custodied_at"
    t.index ["session_token"], name: "index_users_on_session_token"
    t.index ["slug"], name: "index_users_on_slug", unique: true
    t.index ["web2_solana_address"], name: "index_users_on_web2_solana_address", unique: true, where: "(web2_solana_address IS NOT NULL)"
    t.index ["web3_solana_address"], name: "index_users_on_web3_solana_address", unique: true, where: "(web3_solana_address IS NOT NULL)"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "aeropay_purchases", "users"
  add_foreign_key "coinflow_purchases", "users"
  add_foreign_key "contest_slates", "contests"
  add_foreign_key "contest_slates", "slates"
  add_foreign_key "contests", "slates"
  add_foreign_key "contests", "users"
  add_foreign_key "email_deliveries", "users"
  add_foreign_key "entries", "contests"
  add_foreign_key "entries", "users"
  add_foreign_key "games", "survivor_rounds"
  add_foreign_key "landing_pages", "contests", on_delete: :nullify
  add_foreign_key "messages", "contests"
  add_foreign_key "messages", "users"
  add_foreign_key "nfl_team_total_projections", "market_snapshots"
  add_foreign_key "nfl_team_total_projections", "slates"
  add_foreign_key "paypal_purchases", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "season_configs", "contests", column: "main_contest_id", on_delete: :nullify
  add_foreign_key "selections", "entries"
  add_foreign_key "selections", "slate_matchups"
  add_foreign_key "slate_matchups", "slates"
  add_foreign_key "stripe_purchases", "users"
  add_foreign_key "survivor_picks", "entries"
  add_foreign_key "survivor_picks", "survivor_rounds"
  add_foreign_key "transaction_logs", "users"
  add_foreign_key "users", "users", column: "invited_by_id"
end
