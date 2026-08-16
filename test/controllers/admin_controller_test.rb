require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)   # role: admin
    @user  = users(:jordan) # regular user
  end

  # --- hub (Link Hub) ---

  test "hub renders for admins" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    assert_select "h1", text: "Link Hub"
    assert_select "h2", text: "Design"              # hub section
    assert_select "h2", text: "Sports"              # hub section
    assert_select "h2", text: "Admin"               # hub section
    assert_select "a[href=?]", admin_models_path    # QA browser for seeded models
    assert_select "a[href=?]", admin_seasons_path   # a navigation link moved off the gear
    assert_select "a[href=?]", nfl_team_totals_path # NFL baseline totals dashboard
    assert_select "button", text: "Refresh Balance" # an action control kept out of the gear sidebar
  end

  test "hub marks reviewed and flagged links" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    reviewed = [admin_models_path, admin_users_path, admin_geo_path, admin_error_logs_path, contests_path, admin_landing_pages_path]
    flagged  = [new_contest_path, admin_seasons_path, admin_pending_transactions_path, "/admin/jobs",
                slates_path, formula_report_slates_path, nfl_report_slates_path, admin_formula_slates_path,
                generator_contests_path, admin_transactions_path]
    reviewed.each { |path| assert_select "a[href=?][data-status=?]", path, "reviewed" }
    flagged.each  { |path| assert_select "a[href=?][data-status=?]", path, "flagged" }

    assert_select "span", text: "Not added to the gear"
  end

  test "hub links the NFL report beside the soccer formula report" do
    log_in_as(@admin)
    get admin_hub_path
    assert_response :success
    assert_select "a[href=?]", nfl_report_slates_path, text: /🏈 NFL Points Distribution/
    # The two formula reports stay adjacent tiles: soccer first, NFL right after.
    soccer_at = response.body.index(%(href="#{formula_report_slates_path}"))
    nfl_at    = response.body.index(%(href="#{nfl_report_slates_path}"))
    assert soccer_at && nfl_at, "both formula-report tiles must render"
    assert soccer_at < nfl_at, "soccer formula tile must precede the NFL tile"
    between = response.body[soccer_at...nfl_at]
    assert_equal 1, between.scan('href="').count, "no other link between the two formula-report tiles"
  end

  test "hub redirects non-admins" do
    log_in_as(@user)
    get admin_hub_path
    assert_response :redirect
  end

  test "hub redirects anonymous visitors" do
    get admin_hub_path
    assert_response :redirect
  end

  # --- hold button fizz lab ---

  test "hold button fizz lab renders every state for admins" do
    log_in_as(@admin)
    get admin_hold_button_path
    assert_response :success
    assert_select "h1", text: "Hold Button — Fizz Lab"
    # The comparison pair: default fizz vs the fizz: false opt-out. The bubbles
    # are the button's SIBLING (they paint behind it), so they hang off the
    # stack, not the button.
    assert_select ".hold-stack:has(.hold-btn[data-hold-id=?]) > .hold-fizz", "fizz-on"
    assert_select ".hold-stack:has(.hold-btn[data-hold-id=?]) > .hold-fizz", "fizz-off", count: 0
    # Every pinned phase plus the live button, the team-colored one, the two
    # fizz levels, and the three candidate confirmed greens.
    %w[fizz-rest fizz-process fizz-success fizz-error fizz-teams fizz-live
       fizz-calm fizz-lively fizz-green-brand fizz-green-deep fizz-green-mint].each do |id|
      assert_select ".hold-btn[data-hold-id=?]", id
    end
    # The lively variant is the stack's modifier, not a button state.
    assert_select ".hold-stack.fizz-lively:has(.hold-btn[data-hold-id=?])", "fizz-lively"
    assert_select ".hold-stack.fizz-lively:has(.hold-btn[data-hold-id=?])", "fizz-calm", count: 0
    # The team demo wears brand colors in the twelve slots.
    assert_select ".hold-stack[style*=?]", "--fizz-c-1:"
  end

  test "hold button fizz lab dresses its palette in the named teams, in order" do
    # The six are a curated set (AdminController::FIZZ_DEMO_MASCOTS), not
    # whatever the database happens to sort first — and they keep that order.
    broncos = Team.create!(name: "Denver Broncos", slug: "denver-broncos-demo", mascot: "Broncos",
                           sport: "football", league: "nfl", color_light: "#FB4F14", color_dark: "#002244")
    bills = Team.create!(name: "Buffalo Bills", slug: "buffalo-bills-demo", mascot: "Bills",
                         sport: "football", league: "nfl", color_light: "#C60C30", color_dark: "#00338D")

    log_in_as(@admin)
    get admin_hold_button_path
    assert_response :success

    assert_equal %w[Broncos Bills Chargers Seahawks Buccaneers Ravens], AdminController::FIZZ_DEMO_MASCOTS
    # team_card_palette normalizes brand hex to lower case on the way out.
    style = css_select(".hold-stack[style*='--fizz-c-1:']").first["style"]
    assert_includes style, "--fizz-c-1:#{broncos.color_light.downcase}"
    assert_includes style, "--fizz-c-2:#{broncos.color_dark.downcase}"
    assert_includes style, "--fizz-c-3:#{bills.color_light.downcase}"
    assert_includes style, "--fizz-c-4:#{bills.color_dark.downcase}"
  end

  test "hold button fizz lab is admin only" do
    log_in_as(@user)
    get admin_hold_button_path
    assert_response :redirect
  end

  # --- navbar gear sidebar ---

  test "navbar gear sidebar renders for admins" do
    log_in_as(@admin)
    get faucet_path
    assert_response :success
    assert_select "button[data-gear-sidebar-trigger][aria-controls=?]", "gear-sidebar gear-sidebar-mobile"
    assert_select "button[data-username-display][aria-controls=?]", "gear-sidebar gear-sidebar-mobile"
    assert_select "button[data-profile-image-toggle][aria-controls=?]", "gear-sidebar gear-sidebar-mobile"
    # Slim admin shortlist (everything else lives on the Link Hub, reachable
    # from the dashboard — no longer linked from the gear).
    assert_select "a[href=?]", admin_dashboard_path     # Admin: Dashboard
    assert_select "a[href=?]", admin_users_path         # Admin: Users
    assert_select "a[href=?]", admin_landing_pages_path # Admin: Landing Pages
  end

  test "navbar gear sidebar hides admin links from non-admins" do
    log_in_as(@user)
    get faucet_path
    assert_response :success
    assert_select "a[href=?]", admin_hub_path, count: 0
  end

  # --- Sidekiq Web admin gate (SidekiqAdminMiddleware) ---
  # Lazarus audit #17 / OPSEC-045: /admin/jobs must require BOTH admin? AND a
  # session whose token still matches the user's current session_token, so a
  # rotated/revoked session (e.g. after the email-change flow or a forced
  # re-login) loses Sidekiq Web access too — not just admin? alone.

  test "Sidekiq /admin/jobs denies non-admins (404)" do
    log_in_as(@user)
    get "/admin/jobs"
    assert_response :not_found
  end

  test "Sidekiq /admin/jobs denies a stale session_token (OPSEC-045)" do
    log_in_as(@admin)
    # Rotate the DB token so the session's stored token is now stale, as if the
    # admin re-authed elsewhere or an email change rotated it.
    @admin.update_column(:session_token, SecureRandom.hex(32))
    get "/admin/jobs"
    assert_response :not_found
  end

  test "Sidekiq /admin/jobs opens for an admin with a matching session token" do
    log_in_as(@admin)
    get "/admin/jobs"
    assert_not_equal 404, response.status, "a valid admin session must pass the gate"
  end

  # --- usdc_balance hydrate endpoint (combined balance — USDT entries 2026-06-10) ---
  # `balance` is the USDC + USDT sum the navbar pill paints (refreshBalance
  # reads data.balance); `usdc`/`usdt` stay per-currency for
  # $store.session.usdcCents/usdtCents and the /account wallet tiles.

  test "usdc_balance returns combined balance plus per-currency fields" do
    log_in_as(users(:sam)) # web3 wallet fixture → solana_connected?
    vault = FakeVault.new
    vault.wallet_balances = { sol: 0.1, usdc: 5.0, usdt: 3.0 }

    Solana::Vault.stub :new, vault do
      get admin_usdc_balance_path
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 8.0, body["balance"]
    assert_equal 5.0, body["usdc"]
    assert_equal 3.0, body["usdt"]
  end

  test "usdc_balance emits null balance when both wallet reads flaked (client keeps prior pill)" do
    log_in_as(users(:sam))
    vault = FakeVault.new
    vault.wallet_balances = nil # simulated RPC flake — non-Hash

    Solana::Vault.stub :new, vault do
      get admin_usdc_balance_path
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["balance"]
    assert_nil body["usdc"]
    assert_nil body["usdt"]
  end
end
