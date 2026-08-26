require "test_helper"
require "minitest/mock"

class ContestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  # FakeVault is shared — see test/support/fake_vault.rb (LW1 extraction).
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @m1 = slate_matchups(:m1)
    @m2 = slate_matchups(:m2)
    @m3 = slate_matchups(:m3)
    @m4 = slate_matchups(:m4)
    @m5 = slate_matchups(:m5)
    @m6 = slate_matchups(:m6)
    SeasonConfig.set_current!(1)
  end

  # --- update_banner tests ---

  test "update_banner attaches a new banner and refreshes the edit-screen preview" do
    log_in_as(users(:alex)) # admin

    assert_changes -> { @contest.reload.contest_image.attached? }, from: false, to: true do
      patch banner_contest_path(@contest),
        params: { contest: { contest_image: fixture_file_upload("banner.png", "image/png") } },
        as: :turbo_stream
    end

    assert_response :success
    assert_match "contest-banner-preview", response.body
  end

  test "update_banner rejects a non-image file and does not attach" do
    log_in_as(users(:alex)) # admin

    patch banner_contest_path(@contest),
      params: { contest: { contest_image: fixture_file_upload("not_an_image.txt", "text/plain") } },
      as: :turbo_stream

    assert_response :redirect
    assert_not @contest.reload.contest_image.attached?
  end

  test "update_banner is admin-only" do
    log_in_as(@user) # sam — not an admin

    patch banner_contest_path(@contest),
      params: { contest: { contest_image: fixture_file_upload("banner.png", "image/png") } }

    assert_response :redirect
    assert_not @contest.reload.contest_image.attached?
  end

  test "admin sees the Edit banner control on the edit screen" do
    log_in_as(users(:alex))
    get edit_contest_path(@contest)
    assert_response :success
    assert_match "Edit banner", response.body
    assert_match "contest-banner-form", response.body # the banner editor's own form
  end

  # --- toggle_selection tests ---

  test "toggle_selection creates entry and selection on first toggle" do
    log_in_as(@user)

    assert_difference ["Entry.count", "Selection.count"], 1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({ @m1.id.to_s => true }, json["selections"])
    assert_equal 1, json["selection_count"]
  end

  test "toggle_selection removes selection when toggled again" do
    log_in_as(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: @m1)

    assert_difference "Selection.count", -1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({}, json["selections"])
    assert_equal 0, json["selection_count"]
    # Entry should be destroyed when empty
    assert_not Entry.exists?(entry.id)
  end

  test "toggle_selection requires authentication" do
    post toggle_selection_contest_path(@contest),
      params: { matchup_id: @m1.id },
      as: :json

    # JSON requests get a clean 401 (which solana_utils.authedFetch turns into
    # the login modal). Previously the engine's require_authentication did a
    # blind redirect_to login_path even on AJAX, which Rails responded to with
    # 406 Not Acceptable — silent failure for the client.
    assert_response :unauthorized
    assert_equal "unauthenticated", JSON.parse(response.body)["error"]
  end

  # --- enter (confirm) tests ---

  test "enter confirms cart entry with JSON" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["redirect"]
    assert entry.reload.active?
  end

  test "enter with JSON redirects when no cart entry" do
    log_in_as(@user)

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :redirect
  end

  test "enter requires authentication" do
    post enter_contest_path(@contest)

    assert_response :redirect
    assert_redirected_to signin_path
  end

  test "enter with HTML redirects on success" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest)

    assert_response :redirect
    assert_redirected_to contest_path(contest)
  end

  # --- join announcement (chat) on confirmed entry ---

  test "enter posts a single join announcement to chat on first confirmed entry" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_difference -> { contest.messages.system_messages.count }, 1 do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end

    assert_response :success
    announcement = contest.messages.system_messages.find_by(user: @user)
    assert announcement.present?
    assert_includes announcement.body, @user.display_name
    assert_includes announcement.body, "joined the contest"
  end

  test "enter does NOT re-announce when the user already has a join announcement" do
    log_in_as(@user)
    contest = free_contest

    # Simulate the user's first confirmed entry having already announced them
    # (the fixtures only carry 6 matchups, so a second DISTINCT 6-combo — which
    # the Sybil check requires — can't be built here; pre-seeding the
    # announcement exercises the same controller idempotency boundary).
    Message.announce_join!(contest: contest, user: @user)
    assert_equal 1, contest.messages.system_messages.where(user: @user).count

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference -> { contest.messages.system_messages.count } do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end
    assert_response :success
    assert entry.reload.active?
  end

  test "enter posts no join announcement when chat is disabled" do
    log_in_as(@user)
    contest = free_contest
    contest.update!(chat_enabled: false)

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference "Message.count" do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end
    assert_response :success
    assert entry.reload.active?
  end

  # --- post_entry_seeds_payload tests ---
  #
  # The shared seeds-payload helper extracted in the R1 refactor is the
  # single place that emits the `[entry][confirmed]` log line + busts the
  # navbar seeds/USDC caches after a confirmed entry. These tests pin that
  # contract so the structured log line stays grep-able in prod and the
  # caches actually get invalidated.

  test "enter emits structured [entry][confirmed] log on success" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    begin
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    ensure
      Rails.logger = original_logger
    end

    assert_response :success
    log = captured.string
    assert_match(/\[entry\]\[confirmed\] path=managed/, log)
    assert_match(/user_id=#{@user.id}/, log)
    assert_match(/entry_id=#{entry.id}/, log)
    assert_match(/contest=#{contest.slug}/, log)
    assert_match(/seeds_earned=\d+/, log)
    assert_match(/seeds_total=\d+/, log)
    assert_match(/seeds_level=\d+/, log)
    assert_match(/token_consumed=/, log)
  end

  test "enter invalidates seeds and USDC caches on success for solana-connected user" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # Pre-populate both caches with sentinels so we can verify they got cleared.
    Rails.cache.write("user_seeds:#{@user.id}", { seeds: 999 })
    Rails.cache.write("usdc_balance:#{@user.id}", 999.0)

    post enter_contest_path(contest), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_nil Rails.cache.read("user_seeds:#{@user.id}"),
               "seeds cache should be cleared after a successful entry"
    assert_nil Rails.cache.read("usdc_balance:#{@user.id}"),
               "USDC cache should be cleared after a successful entry"
  end

  # --- onchain session entry tests ---
  #
  # #enter is the WEB2 / managed server-signing path. A web3 session belongs on
  # prepare_entry -> confirm_onchain_entry, where the on-chain transaction it
  # signs IS the wallet-ownership proof.
  #
  # THREE TESTS WERE DELETED HERE, DELIBERATELY, and one of them passed:
  # "enter accepts onchain session with valid signature" asserted that a web3
  # session COULD enter through this path given a signed message. That behaviour
  # is what this change removes, so the test had to go with it rather than be
  # relabelled. The other two ("without signature", "with wrong wallet") asserted
  # the failure modes of the same branch and are subsumed by the unconditional
  # refusal below, which is strictly stronger: it does not depend on a client
  # supplying — or omitting — anything.
  #
  # No client could reach the deleted branch: both boards POST /enter with
  # headers only and no body.

  test "enter refuses an onchain session and points at prepare_entry" do
    log_in_as_onchain(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest), headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/prepare_entry/, json["error"],
                 "the refusal must name the path a web3 session should use")
    assert entry.reload.cart?, "a refused entry must stay in the cart"
  end

  test "enter refuses an onchain session even when it carries a valid signature" do
    key = log_in_as_onchain(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # A correctly signed message must NOT buy a web3 session through this path
    # any more. This is the case that used to succeed.
    message = "www.example.com wants you to sign in with your Solana account:\n" \
              "#{@user.web3_solana_address}\n\nUser-ID: #{@user.id}\n\nEnter #{contest.name}"
    post enter_contest_path(contest),
         params: {
           message: message,
           signature: Solana::Keypair.encode_base58(key.sign(message)),
           pubkey: @user.web3_solana_address
         },
         as: :json

    assert_response :unprocessable_entity
    assert_match(/prepare_entry/, JSON.parse(response.body)["error"])
    assert entry.reload.cart?, "a signature must not activate an entry on this path"
  end

  test "enter works for offchain session" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert entry.reload.active?
  end

  test "enter rejects a paid contest that is not on-chain" do
    log_in_as(@user)
    # contests(:one) is paid ($19) but has no onchain_contest_id — the exact
    # state that used to hand out a free entry. The payment gate must refuse it.
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/on-chain/i, json["error"])
    assert entry.reload.cart?, "an unpaid entry must never be activated"
  end

  # --- web2 / managed-wallet token spend ---

  test "enter consumes on-chain token via vault.enter_contest_with_token for managed-wallet users" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected entry success, got: #{json["error"]}"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_token, vault.enter_calls.first[:method]
    assert_equal "tpda_1", vault.enter_calls.first[:token_pda]
    assert entry.reload.active?
  end

  # Unified funding (operator spec 2026-06-13): a managed-wallet user with NO
  # token but ENABLE_WEB2_USDC_ENTRY on now funds the entry with USDC (server
  # signs enter_contest via Solana::Vault#enter_contest_with_usdc) instead of
  # being walled. USDT is never offered to web2 (currency_idx hard-pinned 0).
  test "enter funds a tokenless managed-wallet user via vault.enter_contest_with_usdc when ENABLE_WEB2_USDC_ENTRY is on" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [])
    # The funding-preflight safety net pre-checks USDC before the on-chain enter,
    # so a USDC-funded entry needs a wallet that actually covers the $19 fee.
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected USDC-funded entry success, got: #{json["error"]}"
    refute json["token_consumed"], "a USDC entry must NOT report a token consume"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_usdc, vault.enter_calls.first[:method]
    assert_equal 0, vault.enter_calls.first[:currency_idx], "web2 entry must hard-pin USDC (idx 0), never USDT"
    assert_equal @user.web2_solana_address, vault.enter_calls.first[:wallet]
    assert entry.reload.active?
  end

  # Kill-switch off → web2 reverts to TOKEN-ONLY (today's pre-unification
  # behavior): a tokenless managed user is blocked with the "No entry tokens"
  # raise, which Solana::ErrorInterpreter maps to the no_funding blocker.
  test "enter blocks a tokenless managed-wallet user when ENABLE_WEB2_USDC_ENTRY is off" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [])
    AppFlags.stub :web2_usdc_entry?, false do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/No entry tokens/, body["error"])
    assert_equal "no_funding", body.dig("blocker", "reason")
    assert_equal "web2",       body.dig("blocker", "mode")
    assert entry.reload.cart?
    assert_equal 0, vault.enter_calls.length
  end

  # Combo-account desync regression (Avi review 2026-06-13). A managed+phantom
  # account in a web2 (magic-link) session holds a token minted to its WEB3
  # address (tokens mint to #solana_address, web3-preferred). The web2 server-sign
  # path signs with the MANAGED keypair, so it must NOT try to consume that
  # web3-owned token (on-chain owner != signer → atomic fail) AND must NOT let a
  # bogus "found a token" branch mask the working USDC fallback. With token
  # detection scoped to the web2 address (#next_unconsumed_entry_token_for), the
  # resolver sees no web2-owned token and funds the entry via USDC.
  test "enter ignores a web3-owned token for a combo account in a web2 session and funds via USDC" do
    web2_addr = "ManagedAddr#{SecureRandom.hex(4)}"
    web3_addr = "Web3Combo#{SecureRandom.hex(4)}"
    @user.update!(
      web3_solana_address: web3_addr,
      web2_solana_address: web2_addr,
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # The unconsumed token lives on the WEB3 address; the web2 address holds none.
    vault = FakeVault.new(tokens: {
      web3_addr => [{ pda: "tpda_web3", consumed: false }],
      web2_addr => []
    })
    # Funded enough USDC for the safety-net pre-check to clear → USDC fallback.
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected USDC-funded entry success, got: #{json["error"]}"
    refute json["token_consumed"], "the web3-owned token must NOT be consumed by the web2 keypair"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_usdc, vault.enter_calls.first[:method],
                 "a combo web2 session must fall through to USDC, not a doomed web3-token consume"
    assert_equal web2_addr, vault.enter_calls.first[:wallet]
    assert entry.reload.active?
  end

  # Positive twin: when the SAME combo account's WEB2 address owns an unconsumed
  # token, the scoped lookup finds it and consumes it with the managed keypair
  # (owner == signer), ahead of the USDC fallback. Proves the scoping reads web2
  # tokens, not just that it ignores web3 ones.
  test "enter consumes a web2-owned token for a combo account in a web2 session" do
    web2_addr = "ManagedAddr#{SecureRandom.hex(4)}"
    web3_addr = "Web3Combo#{SecureRandom.hex(4)}"
    @user.update!(
      web3_solana_address: web3_addr,
      web2_solana_address: web2_addr,
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: {
      web2_addr => [{ pda: "tpda_web2", consumed: false }],
      web3_addr => [{ pda: "tpda_web3", consumed: false }]
    })
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
        Solana::Vault.stub :new, vault do
          post enter_contest_path(@contest), as: :json
        end
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected token-funded entry success, got: #{json["error"]}"
    assert_equal :enter_contest_with_token, vault.enter_calls.first[:method]
    assert_equal "tpda_web2", vault.enter_calls.first[:token_pda],
                 "the scoped lookup must consume the WEB2-owned token, not the web3 one"
    assert_equal web2_addr, vault.enter_calls.first[:wallet]
    assert entry.reload.active?
  end

  # SAFETY NET (funding preflight, 2026-06-13). A tokenless managed user with a
  # $0 USDC balance + the flag ON must be blocked with no_funding BEFORE the
  # doomed on-chain enter_contest_with_usdc — never the cryptic 0x1 sim error.
  test "enter pre-checks USDC and blocks a $0 managed wallet with no_funding instead of attempting a doomed on-chain entry" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: []) # default wallet_balances are all 0.0 → $0 USDC
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "no_funding", body.dig("blocker", "reason")
    assert_equal "web2",       body.dig("blocker", "mode")
    assert_match(/USDC/i, body["error"])
    assert entry.reload.cart?, "the entry must stay cart — no doomed on-chain attempt"
    refute(vault.enter_calls.any? { |c| c[:method] == :enter_contest_with_usdc },
           "enter_contest_with_usdc must NOT be called for a $0 wallet")
  end

  # SAFETY-NET regression guard (Avi review 2026-06-13). The pre-check must
  # distinguish a transient getTokenAccountsByOwner FLAKE from a confirmed $0:
  # the real Solana::Vault returns usdc:0 on a flake, which would FALSE-BLOCK a
  # genuinely funded user (their atomic SPL transfer holds the real balance and
  # would succeed). On a read flake the pre-check must FAIL OPEN — fall through
  # to the self-protecting atomic enter_contest_with_usdc — never raise
  # no_funding. (Contrast the $0 test above: a CONFIRMED zero still blocks.)
  test "enter fails OPEN on a token-accounts RPC flake and proceeds to the atomic USDC enter" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances_raises = true # pre-check getTokenAccountsByOwner flake → RpcError
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "a flaked pre-check must NOT false-block a funded user, got: #{json["error"]}"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_usdc, vault.enter_calls.first[:method],
                 "a flaked pre-check must defer to the self-protecting atomic enter, not raise no_funding"
    assert entry.reload.active?
  end

  # SAFETY-NET regression guard (fix-vault-connection-error-escape). Sibling of
  # the token-accounts-flake test above, but for a CONNECTION-level RPC failure.
  # A Helius connection refusal surfaces from the gem client as a RAW
  # Errno::ECONNREFUSED — solana-studio's Solana::Client#call wraps only
  # timeouts/ECONNRESET into RpcError, never ECONNREFUSED/SocketError. Before the
  # fix that raw error escaped Solana::Vault#fetch_wallet_balances (get_balance
  # sat OUTSIDE any rescue) and walked past the pre-check's
  # `rescue Solana::Client::RpcError` → the entry false-blocked (422) instead of
  # deferring to the self-protecting atomic USDC enter. The pre-check must FAIL
  # OPEN on a transport failure exactly as it does on a token-accounts flake.
  test "enter fails OPEN on a CONNECTION-level RPC failure (ECONNREFUSED) and proceeds to the atomic USDC enter" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # REAL Solana::Vault so the ACTUAL fetch_wallet_balances rescue boundary runs
    # (the fix lives there, not at the controller call site). Inject the failure
    # BELOW it at the gem client: get_balance raises a raw Errno::ECONNREFUSED,
    # exactly as Net::HTTP does when Helius is unreachable and the gem does NOT
    # wrap. The atomic USDC enter + entry-slot probe are stubbed so the test stays
    # hermetic while exercising the real fail-open routing.
    raising_client = Class.new do
      def get_balance(_addr)
        raise Errno::ECONNREFUSED
      end

      def get_token_accounts_by_owner(_addr)
        raise Errno::ECONNREFUSED
      end
    end.new
    vault = Solana::Vault.new(client: raising_client)
    enter_usdc_calls = []
    vault.define_singleton_method(:next_free_entry_index) { |*_args, **_kwargs| 0 }
    vault.define_singleton_method(:enter_contest_with_usdc) do |user:, contest:, entry_num:|
      enter_usdc_calls << { user: user.id, contest: contest.slug, entry_num: entry_num }
      { signature: "fake-usdc-sig-conn", entry_pda: "epda-conn" }
    end

    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "a connection-level RPC failure must NOT false-block a funded user, got: #{json["error"]}"
    assert_equal 1, enter_usdc_calls.length,
                 "a connection-level failure must defer to the self-protecting atomic USDC enter, not false-block"
    assert entry.reload.active?
  end

  # --- check_funding (hold-to-confirm funding pre-check, 2026-06-13) ---
  #
  # check_funding is a pure capability check on the contest fee + wallet, so
  # these tests intentionally create NO cart entry — it's independent of the row.

  test "check_funding requires authentication" do
    post check_funding_contest_path(@contest), as: :json
    assert_response :unauthorized
  end

  test "check_funding reports fundable via token for a managed user holding an entry token" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@contest), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["fundable"]
    assert_nil body["reason"]
    assert_equal "token", body["method"]
  end

  test "check_funding reports fundable via usdc for a tokenless funded managed user when the flag is on" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["fundable"]
    assert_equal "usdc", body["method"]
  end

  test "check_funding reports NOT fundable for a fresh $0 managed wallet (the bug case)" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: []) # default balances all 0.0
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    refute body["fundable"]
    assert_equal "no_funding", body["reason"]
    assert_nil body["method"]
  end

  test "check_funding reports NOT fundable for a USDC-funded managed wallet when ENABLE_WEB2_USDC_ENTRY is off" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, false do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    body = JSON.parse(response.body)
    refute body["fundable"], "web2 USDC entry is gated off — a USDC-only wallet is not fundable"
    assert_equal "no_funding", body["reason"]
  end

  test "check_funding reports fundable via usdc for a web3 session regardless of the web2 flag" do
    log_in_as_onchain @user # sets web3 address + onchain session
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, false do # web2 flag has no bearing on web3
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    body = JSON.parse(response.body)
    assert body["fundable"]
    assert_equal "usdc", body["method"]
  end

  test "check_funding reports fundable via usdt for a web3 session on an accepts_usdt contest" do
    log_in_as_onchain @user
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1, accepts_usdt: true)

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 0.0, usdt: 25.0 } # USDT only
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@contest), as: :json
    end

    body = JSON.parse(response.body)
    assert body["fundable"]
    assert_equal "usdt", body["method"]
  end

  test "check_funding reports NOT fundable via usdt when the contest does not accept it" do
    log_in_as_onchain @user
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1, accepts_usdt: false)

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 0.0, usdt: 25.0 } # USDT only
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@contest), as: :json
    end

    body = JSON.parse(response.body)
    refute body["fundable"], "a USDT-only wallet can't fund a USDC-only contest"
    assert_equal "no_funding", body["reason"]
  end

  test "check_funding reports fundable on a free contest with no wallet funds" do
    log_in_as @user
    contest = free_contest

    vault = FakeVault.new(tokens: [])
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(contest), as: :json
    end

    body = JSON.parse(response.body)
    assert body["fundable"]
    assert_nil body["method"], "a free entry needs no funding method"
  end

  # A WHOLESALE read failure (the method itself raises a non-RpcError — e.g.
  # get_balance down, decode error) stays fail-CLOSED via check_funding's outer
  # rescue. This is distinct from the targeted token-accounts RPC flake below,
  # which fails OPEN: only the narrow getTokenAccountsByOwner-flake case is
  # eligible for fail-open (Avi review 2026-06-13), everything else stays
  # conservative.
  test "check_funding fails CLOSED (not fundable) and records an ErrorLog when the balance read raises" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [])
    def vault.fetch_wallet_balances(_addr, raise_on_read_error: false) = raise("RPC down")

    before = ErrorLog.count
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    refute body["fundable"], "a read failure must fail CLOSED (Top Up Wallet)"
    assert_equal "no_funding", body["reason"]
    assert_operator ErrorLog.count, :>, before, "the read failure must be recorded to ErrorLog"
  end

  # A TRANSIENT getTokenAccountsByOwner flake (the narrow case Avi flagged) must
  # NOT be conflated with a confirmed $0: the real Solana::Vault returns usdc:0
  # on a flake, which would FALSE-BLOCK a funded web2 user (their atomic SPL
  # transfer would have succeeded). With raise_on_read_error the flake RAISES
  # Solana::Client::RpcError and check_funding fails OPEN — the atomic enter is
  # the self-protecting authority. (FakeVault#wallet_balances_raises models the
  # conflation the suite previously could not catch.)
  test "check_funding fails OPEN (fundable) on a token-accounts RPC flake for a managed user when the flag is on" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances_raises = true # getTokenAccountsByOwner flake → RpcError under raise_on_read_error
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["fundable"], "a token-accounts RPC flake must fail OPEN — never false-block a funded user"
    assert_nil body["reason"]
  end

  # The fail-open is bounded: when web2 USDC entry is OFF there is NO balance
  # funding path (token-only), so a token-accounts flake has nothing to fail open
  # TO and check_funding stays not-fundable.
  test "check_funding stays NOT fundable on a token-accounts RPC flake when web2 USDC entry is off" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    log_in_as @user

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances_raises = true
    AppFlags.stub :web2_usdc_entry?, false do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    refute body["fundable"], "token-only (flag off) + no token → a balance flake can't grant fundability"
    assert_equal "no_funding", body["reason"]
  end

  # Incident 2026-06-08 (entry #133), defense-in-depth half: a TRANSIENT failure
  # (RPC/DB) inside confirm! AFTER a successful consume must not silently strand
  # the entry. The validation gates now run PRE-flight (see the two tests above),
  # so the only way to reach confirm! post-consume is a non-validation fault —
  # here a forced TransactionLog.record! failure inside confirm!'s transaction.
  # The durable-capture write leaves the consume signature on the row
  # (recoverable) and a reconcile job is scheduled to converge it.
  test "enter leaves a recoverable record + schedules reconcile when confirm! hits a transient failure after a successful token consume" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain133", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    # Simulate a transient DB fault inside confirm!'s transaction, AFTER the
    # FakeVault consume has already "spent" the token on-chain and the durable
    # capture has committed the signature.
    boom = ->(*, **) { raise StandardError, "simulated post-broadcast DB failure" }
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        TransactionLog.stub :record!, boom do
          assert_enqueued_with(job: Entries::OnchainReconcileJob, args: [entry.id]) do
            post enter_contest_path(@contest), as: :json
          end
        end
      end
    end

    # The on-chain consume happened exactly once...
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_token, vault.enter_calls.first[:method]

    # ...and although confirm! failed, the entry is NOT a silent cart: the
    # consume signature + Entry PDA are durably captured so it can self-heal.
    entry.reload
    assert entry.cart?, "entry stays cart until the reconciler heals it"
    assert entry.onchain_tx_signature.present?, "consume signature must survive the confirm! failure"
    assert entry.onchain_entry_id.present?, "entry PDA must survive the confirm! failure"

    # B1 (PR #115 review): the swallow-and-reconcile branch records an ErrorLog
    # with entry/contest context so the strand is diagnosable (incident #133 was
    # reconstructed by hand precisely because this row was missing).
    log = ErrorLog.where(target: entry).order(:id).last
    assert log, "a swallowed post-broadcast confirm! failure must still create an ErrorLog"
    assert_equal entry.slug, log.target_name
    assert_equal @contest, log.parent
    assert_equal @contest.slug, log.parent_name
    assert_match "simulated post-broadcast DB failure", log.message
  end

  # validate-before-consume (backend discipline #2). A read-only eligibility
  # failure (here: too few selections) must raise in the PRE-FLIGHT
  # assert_enterable! BEFORE vault.enter_contest_with_token — so the token stays
  # UNCONSUMED, the entry stays `cart`, and NO reconcile is scheduled (there is
  # nothing to recover; fail loudly). This is the primary fix for incident
  # 2026-06-08, where the gate ran AFTER the irreversible burn.
  test "enter validates selection count BEFORE consuming the token (short entry → nothing burned)" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain-preflight-count", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2].each { |m| entry.selections.create!(slate_matchup: m) } # only 2 of 6

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        assert_no_enqueued_jobs only: Entries::OnchainReconcileJob do
          post enter_contest_path(@contest), as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_match(/selections required/i, JSON.parse(response.body)["error"])
    assert_equal 0, vault.enter_calls.length, "token must NOT be consumed when a gate fails pre-flight"
    entry.reload
    assert entry.cart?, "entry must stay cart"
    assert_nil entry.onchain_tx_signature, "no signature — nothing was broadcast"
  end

  # Same validate-before-consume guarantee for the sybil / duplicate-exact-combo
  # gate: a repeat of an existing active combo must be rejected pre-flight, with
  # the token left unconsumed.
  test "enter validates the duplicate-combo (sybil) gate BEFORE consuming the token" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain-preflight-sybil", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    # An existing ACTIVE entry with the exact combo the user is about to repeat.
    existing = @contest.entries.create!(user: @user, status: :active)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| existing.selections.create!(slate_matchup: m) }

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        assert_no_enqueued_jobs only: Entries::OnchainReconcileJob do
          post enter_contest_path(@contest), as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_match(/already have an entry/i, JSON.parse(response.body)["error"])
    assert_equal 0, vault.enter_calls.length, "token must NOT be consumed when the sybil gate fails pre-flight"
    assert entry.reload.cart?
  end

  # --- prepare_entry tests (web3 single-signature flow) ---

  test "prepare_entry builds the TX + creates a pending PT" do
    @user.update!(web3_solana_address: "Web3PrepWallet#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_prep", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    assert_difference "PendingTransaction.count", 1 do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert body["serialized_tx"].start_with?("FAKE_TX_")
    assert_equal entry.id, body["entry_id"]
    assert body["entry_pda"].start_with?("epda-")
    assert body["ptx_slug"].start_with?("ptx-")

    ptx = PendingTransaction.find_by(slug: body["ptx_slug"])
    assert_equal "pending", ptx.status
    assert_equal "enter_contest", ptx.tx_type
    assert_equal entry, ptx.target
    assert_equal @user.web3_solana_address, ptx.initiator_address
  end

  # --- prepare_entry funding priority (Phantom spends a token, 2026-08-21) -----
  #
  # Until this task the Phantom path went straight to the currency transfer, so a
  # wallet holding an entry token was charged USDC anyway and the token sat
  # unspent — while the board's CTA told that user the entry was free. These pin
  # the priority the web2 path has always had: token first, transfer otherwise.

  test "prepare_entry spends an entry token the Phantom wallet holds" do
    @user.update!(web3_solana_address: "Web3TokenPrep#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_token_prep", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_web3_1", consumed: false }])
    Solana::Vault.stub :new, vault do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["token_funded"], "the response must tell the client this entry is token-funded"

    built = vault.enter_calls.last
    assert_equal :build_enter_contest_with_token, built[:method],
                 "a token-holding wallet must build the token instruction, not the transfer"
    assert_equal "tpda_web3_1", built[:entry_token_pda]

    # No ATA is created for a token entry — there is no transfer to fund.
    assert_empty vault.ensure_ata_calls,
                 "the token path moves no SPL, so it must not create a currency ATA"

    # The server's own record of what it prepared. The cosign guard and the
    # broadcast verification both read this back instead of trusting the client.
    ptx  = PendingTransaction.find_by(slug: body["ptx_slug"])
    meta = JSON.parse(ptx.metadata)
    assert_equal "token", meta["funding"]
    assert_equal "tpda_web3_1", meta["entry_token_pda"]
  end

  test "prepare_entry falls back to the currency transfer when the wallet holds no token" do
    @user.update!(web3_solana_address: "Web3NoTokenPrep#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_notoken_prep", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_spent", consumed: true }])
    Solana::Vault.stub :new, vault do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["token_funded"], "a CONSUMED token must not read as funding"

    built = vault.enter_calls.last
    assert_equal :build_enter_contest, built[:method]

    ptx  = PendingTransaction.find_by(slug: body["ptx_slug"])
    meta = JSON.parse(ptx.metadata)
    assert_equal "transfer", meta["funding"]
    assert_nil meta["entry_token_pda"]
  end

  test "discard_prepared_entry expires an unsigned wallet request so retry can rebuild it" do
    @user.update!(web3_solana_address: "Web3Discard#{SecureRandom.hex(4)}")
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "unsigned-wire",
      status: "pending", target: entry,
      initiator_address: @user.web3_solana_address,
      metadata: { funding: "token", entry_token_pda: "token-pda" }.to_json
    )

    post discard_prepared_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    assert_equal({ "retired" => true }, JSON.parse(response.body))
    assert_equal "expired", ptx.reload.status
    assert entry.reload.cart?, "discarding an unsigned request must not consume the cart entry"
  end

  test "discard_prepared_entry never expires a transaction that may have been broadcast" do
    @user.update!(web3_solana_address: "Web3KeepSigned#{SecureRandom.hex(4)}")
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "signed-wire",
      status: "submitted", tx_signature: "chain-signature",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { funding: "token", entry_token_pda: "token-pda" }.to_json
    )

    post discard_prepared_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    assert_equal({ "retired" => false }, JSON.parse(response.body))
    assert_equal "submitted", ptx.reload.status
    assert_equal "chain-signature", ptx.tx_signature
  end

  # The retire guard moved from Ruby into the WHERE clause to close a race (a
  # signature landing between the read and the write would otherwise expire a
  # transaction that SUCCEEDED). `blank?` covered nil AND "", and SQL does not
  # — so an empty-string signature is the case a naive `tx_signature: nil`
  # predicate silently starts retiring.
  test "an EMPTY-STRING signature is not retired either — blank? parity in SQL" do
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "signed-wire",
      status: "submitted", tx_signature: "",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { funding: "token", entry_token_pda: "token-pda" }.to_json
    )

    post discard_prepared_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    assert_equal({ "retired" => true }, JSON.parse(response.body))
    assert_equal "expired", ptx.reload.status
  end

  # The affected-row COUNT is the verdict, so a row someone else already moved
  # reports false rather than claiming a retire that did not happen.
  test "a PT already expired reports retired=false, not a second retire" do
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "signed-wire",
      status: "expired",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { funding: "token", entry_token_pda: "token-pda" }.to_json
    )

    post discard_prepared_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    assert_equal({ "retired" => false }, JSON.parse(response.body))
  end

  test "discard_prepared_entry refuses another user's unsigned request" do
    other = users(:jordan)
    other.update!(web3_solana_address: "Web3DiscardOther#{SecureRandom.hex(4)}")
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: other, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "unsigned-wire",
      status: "pending", target: entry,
      initiator_address: other.web3_solana_address
    )

    post discard_prepared_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :forbidden
    assert_equal "pending", ptx.reload.status
  end

  test "prepare_entry rejects an on-chain contest pinned to an unavailable season before signing" do
    @user.update!(web3_solana_address: "Web3PrepBadSeason#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_bad_season", season_id: 7)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(season: nil)
    assert_no_difference "PendingTransaction.count" do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_match(/Season 7 is not initialized/i, body["error"])
    assert_empty vault.enter_calls
  end

  test "prepare_entry rejects when the session was not Phantom-authenticated" do
    @user.update!(web3_solana_address: "Web3NotOnchain#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_x", season_id: 1)

    log_in_as @user  # email/password login — no session[:onchain]
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference "PendingTransaction.count" do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "prepare_entry rejects when there is no cart entry" do
    @user.update!(web3_solana_address: "Web3NoCart#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_y", season_id: 1)
    log_in_as_onchain(@user)

    post prepare_entry_contest_path(@contest), as: :json
    assert_response :unprocessable_entity
    assert_match(/No cart entry/, JSON.parse(response.body)["error"])
  end

  test "prepare_entry rejects when selections are incomplete" do
    @user.update!(web3_solana_address: "Web3Incomp#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_z", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2].each { |m| entry.selections.create!(slate_matchup: m) }  # only 2 of 6

    vault = FakeVault.new
    assert_no_difference "PendingTransaction.count" do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_match(/Exactly .* selections/, JSON.parse(response.body)["error"])
  end

  # --- prepare_entry currency selection (USDT entries, 2026-06-10) ---

  test "prepare_entry currency=usdt on an accepts_usdt contest builds with currency_idx 1 + the USDT ATA" do
    @user.update!(web3_solana_address: "Web3UsdtHappy#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_usdt_ok", season_id: 1, accepts_usdt: true)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    assert_difference "PendingTransaction.count", 1 do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), params: { currency: "usdt" }, as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]

    build = vault.enter_calls.last
    assert_equal :build_enter_contest, build[:method]
    assert_equal 1, build[:currency_idx]

    # The pre-entry ATA bootstrap must target the USDT mint, not USDC.
    assert_equal [Solana::Config::USDT_MINT], vault.ensure_ata_calls.map { |c| c[:mint] }

    ptx = PendingTransaction.find_by(slug: body["ptx_slug"])
    assert_equal 1, JSON.parse(ptx.metadata)["currency_idx"]
  end

  test "prepare_entry defaults to USDC: currency_idx 0, USDC ATA, metadata 0" do
    @user.update!(web3_solana_address: "Web3UsdcDef#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_usdc_def", season_id: 1, accepts_usdt: true)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :success
    assert_equal 0, vault.enter_calls.last[:currency_idx]
    assert_equal [Solana::Config::USDC_MINT], vault.ensure_ata_calls.map { |c| c[:mint] }

    ptx = PendingTransaction.find_by(slug: JSON.parse(response.body)["ptx_slug"])
    assert_equal 0, JSON.parse(ptx.metadata)["currency_idx"]
  end

  test "prepare_entry rejects currency=usdt when the contest does not accept USDT" do
    @user.update!(web3_solana_address: "Web3UsdtNo#{SecureRandom.hex(4)}")
    # accepts_usdt stays false — e.g. any contest created before 2026-06-10
    # (its on-chain entry_fee_by_currency slot 1 is an immutable zero).
    @contest.update!(onchain_contest_id: "onchain_usdt_no", season_id: 1)
    log_in_as_onchain(@user)
    @contest.entries.create!(user: @user, status: :cart)

    assert_no_difference "PendingTransaction.count" do
      post prepare_entry_contest_path(@contest), params: { currency: "usdt" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/doesn't accept USDT/, JSON.parse(response.body)["error"])
  end

  test "prepare_entry rejects an unknown currency outright" do
    @user.update!(web3_solana_address: "Web3BadCur#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_bad_cur", season_id: 1, accepts_usdt: true)
    log_in_as_onchain(@user)
    @contest.entries.create!(user: @user, status: :cart)

    assert_no_difference "PendingTransaction.count" do
      post prepare_entry_contest_path(@contest), params: { currency: "doge" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/Unsupported currency/, JSON.parse(response.body)["error"])
  end

  # --- confirm_onchain_entry tests ---

  test "confirm_onchain_entry promotes entry to active + marks PT confirmed" do
    @user.update!(web3_solana_address: "Web3Confirm#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conf", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    # Phantom-FIRST flow: prepare_entry creates the PT pending with NO signature
    # (broadcast is server-side); confirm_onchain_entry stamps the
    # server-broadcast signature.
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "pending",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0" }.to_json
    )

    vault = FakeVault.new
    vault.sync_balance_seeds = 100
    expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"

    # encode_base58 here would normally turn pda bytes into a base58 string;
    # FakeVault.entry_pda returns the string already, so stub encode_base58
    # to pass it through unchanged. The Phantom-signed wire bytes are opaque to
    # the controller (passed straight to vault.cosign_and_broadcast_entry, faked).
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_enqueued_with(job: LevelUpTokenMintJob, args: [{ user_id: @user.id }]) do
            post confirm_onchain_entry_contest_path(@contest),
              params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: entry.id, entry_pda: expected_pda },
              as: :json
          end
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    # The signature is the SERVER's cosign+broadcast result, not a client value.
    assert_equal "fake-cosign-broadcast-sig", body["tx_signature"]
    assert_equal ["PHANTOM_SIGNED_WIRE_B64"], vault.cosign_broadcast_calls
    assert entry.reload.active?
    assert_equal "fake-cosign-broadcast-sig", entry.onchain_tx_signature
    ptx.reload
    assert_equal "confirmed", ptx.status
    assert_equal "fake-cosign-broadcast-sig", ptx.tx_signature
  end

  # --- confirm_onchain_entry funding expectations (2026-08-21) -----------------
  #
  # The funding is decided at prepare time and recorded on the PendingTransaction.
  # Confirm must read its OWN note back — never the request — because that single
  # fact drives two locks: which instruction the admin will cosign, and which
  # instruction the broadcast has to prove. Verifying the wrong name would accept
  # a signature that never moved the funding this entry was priced with.

  def setup_web3_confirm_entry(address_prefix:, metadata:)
    @user.update!(web3_solana_address: "#{address_prefix}#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conf_funding", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"
    PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx", status: "pending",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: expected_pda }.merge(metadata).to_json
    )
    [entry, expected_pda]
  end

  test "confirm_onchain_entry cosigns and verifies the TOKEN instruction it prepared" do
    entry, expected_pda = setup_web3_confirm_entry(
      address_prefix: "Web3ConfToken",
      metadata: { funding: "token", entry_token_pda: "tpda_web3_1" }
    )

    vault    = FakeVault.new
    verified = []
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(v) { v.is_a?(String) ? v : v.to_s } do
        Solana::TxVerifier.stub :verify!, ->(**kw) { verified << kw; true } do
          post confirm_onchain_entry_contest_path(@contest),
            params: { signed_tx: "PHANTOM_SIGNED_TOKEN_WIRE", entry_id: entry.id, entry_pda: expected_pda },
            as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert body["token_consumed"], "a token-funded entry must report the consume (navbar badge punch)"

    # The guard was handed the SERVER's decision, not a client value.
    assert_equal "tpda_web3_1", vault.cosign_safe_calls.first[:entry_token_pda]
    assert_equal "enter_contest_with_token", verified.first[:instruction_name]
    assert entry.reload.active?
  end

  test "confirm_onchain_entry expects the TRANSFER instruction when no token was prepared" do
    entry, expected_pda = setup_web3_confirm_entry(
      address_prefix: "Web3ConfTransfer",
      metadata: {}   # a row from before this task carries no funding key at all
    )

    vault    = FakeVault.new
    verified = []
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(v) { v.is_a?(String) ? v : v.to_s } do
        Solana::TxVerifier.stub :verify!, ->(**kw) { verified << kw; true } do
          post confirm_onchain_entry_contest_path(@contest),
            params: { signed_tx: "PHANTOM_SIGNED_USDC_WIRE", entry_id: entry.id, entry_pda: expected_pda },
            as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["token_consumed"]
    assert_nil vault.cosign_safe_calls.first[:entry_token_pda],
               "with no prepared token the guard must admit ONLY enter_contest"
    assert_equal "enter_contest", verified.first[:instruction_name]
  end

  # --- the token cache must not outlive the token it describes ----------------
  #
  # These assert on the REAL cache key the navbar badge and the "Hold for Free
  # Entry" CTA read (Solana::Vault.entry_tokens_cache_key), not on a mock call
  # count — the previous bust DID get called, it just deleted a different key,
  # so only observing the reader's key can tell the two apart. The test env runs
  # :null_store, hence the injected MemoryStore.
  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  test "confirm_onchain_entry busts the entry-token cache the badge actually reads" do
    entry, expected_pda = setup_web3_confirm_entry(
      address_prefix: "Web3ConfBust",
      metadata: { funding: "token", entry_token_pda: "tpda_bust_1" }
    )
    cache_key = Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address)

    with_memory_cache do
      Rails.cache.write(cache_key, [{ pda: "tpda_bust_1", consumed: false }])

      vault = FakeVault.new
      Solana::Vault.stub :new, vault do
        Solana::Keypair.stub :encode_base58, ->(v) { v.is_a?(String) ? v : v.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post confirm_onchain_entry_contest_path(@contest),
              params: { signed_tx: "PHANTOM_SIGNED_TOKEN_WIRE", entry_id: entry.id, entry_pda: expected_pda },
              as: :json
          end
        end
      end

      assert_response :success
      assert_nil Rails.cache.read(cache_key),
                 "the spent token must not survive in the layer the badge and the CTA read"
    end
  end

  test "recover_pending_entry busts the entry-token cache after a token-funded recovery" do
    @user.update!(web3_solana_address: "WalletRTok#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-recover-token-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-r1", funding: "token", entry_token_pda: "tpda_recover_1" }.to_json
    )
    cache_key = Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address)

    with_memory_cache do
      Rails.cache.write(cache_key, [{ pda: "tpda_recover_1", consumed: false }])

      vault = FakeVault.new(signature_statuses: {
        "sig-recover-token-1" => { "err" => nil, "confirmationStatus" => "confirmed" }
      })
      Solana::Vault.stub :new, vault do
        Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post recover_pending_entry_contest_path(@contest),
              params: { ptx_slug: ptx.slug }, as: :json
          end
        end
      end

      assert_equal "confirmed", JSON.parse(response.body)["status"]
      assert entry.reload.active?
      assert_nil Rails.cache.read(cache_key),
                 "crash recovery credits an entry whose token was burned on-chain — it owes " \
                 "the same cache bust as the live confirm path"
    end
  end

  # CONTROL: the bust is conditional on the SERVER having prepared a token, and
  # the harness can see a cache entry survive. Without this a bust-everything
  # implementation would pass the two tests above for the wrong reason.
  test "recover_pending_entry leaves the entry-token cache alone for a USDC recovery" do
    @user.update!(web3_solana_address: "WalletRUsdc#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-recover-usdc-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-r2" }.to_json
    )
    cache_key = Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address)

    with_memory_cache do
      Rails.cache.write(cache_key, [{ pda: "tpda_untouched_1", consumed: false }])

      vault = FakeVault.new(signature_statuses: {
        "sig-recover-usdc-1" => { "err" => nil, "confirmationStatus" => "confirmed" }
      })
      Solana::Vault.stub :new, vault do
        Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post recover_pending_entry_contest_path(@contest),
              params: { ptx_slug: ptx.slug }, as: :json
          end
        end
      end

      assert_equal "confirmed", JSON.parse(response.body)["status"]
      assert_equal [{ pda: "tpda_untouched_1", consumed: false }], Rails.cache.read(cache_key),
                   "no token was spent, so nothing about the wallet's tokens changed"
    end
  end

  test "confirm_onchain_entry rejects a mismatched client-supplied entry_pda" do
    @user.update!(web3_solana_address: "Web3Mismatch#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_m", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        post confirm_onchain_entry_contest_path(@contest),
          params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: entry.id, entry_pda: "epda-attacker-fake" },
          as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/Entry PDA mismatch/, JSON.parse(response.body)["error"])
    assert entry.reload.cart?
  end

  test "confirm_onchain_entry returns tx_rejected (422) and NEVER broadcasts when cosign validation refuses the wire (audit C1)" do
    @user.update!(web3_solana_address: "Web3Cosign#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_c1", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    # The real validator refuses a tx that doesn't match the prepared entry —
    # e.g. an admin-fee-payer SystemProgram.transfer (the C1 attack). The detailed
    # reason is for server logs only; it must never reach the client.
    vault.cosign_safe_raises = "system_not_advance: ix 0 (the C1 attack)"

    Solana::Vault.stub :new, vault do
      post confirm_onchain_entry_contest_path(@contest),
        params: { signed_tx: "MALICIOUS_WIRE_B64", entry_id: entry.id, entry_pda: "whatever" },
        as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    refute body["success"]
    assert_equal "tx_rejected", body["code"]          # stable code the frontend keys its modal off
    assert_empty vault.cosign_broadcast_calls          # validation ran BEFORE cosign — nothing broadcast
    refute_match(/system_not_advance/, body["error"].to_s) # detailed reason never leaked to the client
    assert entry.reload.cart?                          # no charge, safe to retry
  end

  test "confirm_onchain_entry surfaces a cosign/broadcast failure, leaves entry in cart with a BLANK PT (safe retry)" do
    @user.update!(web3_solana_address: "Web3CosignFail#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_cf", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx", status: "pending",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: expected_pda }.to_json
    )

    vault = FakeVault.new
    vault.cosign_broadcast_raises = "Entry pre-flight simulation failed"
    Solana::Vault.stub :new, vault do
      post confirm_onchain_entry_contest_path(@contest),
        params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: entry.id, entry_pda: expected_pda },
        as: :json
    end

    assert_response :unprocessable_entity
    assert entry.reload.cart?, "entry must stay in cart when broadcast fails"
    ptx.reload
    # Broadcast never succeeded → no signature stamped → recover_pending_entry reads
    # this as 'never broadcast' and safely lets the user retry (no double charge).
    assert ptx.tx_signature.blank?, "no signature should be stamped when cosign/broadcast raises"
    assert_equal "pending", ptx.status
  end

  test "confirm_onchain_entry stamps the PT signature BEFORE verify, so a post-broadcast verify failure stays recoverable (A1)" do
    @user.update!(web3_solana_address: "Web3A1#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_a1", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx", status: "pending",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: expected_pda }.to_json
    )

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        # Broadcast SUCCEEDS (FakeVault returns the fake sig), but verification raises
        # — simulating a transient RPC failure on getTransaction AFTER money moved.
        Solana::TxVerifier.stub :verify!, ->(*) { raise StandardError, "transient RPC on getTransaction" } do
          post confirm_onchain_entry_contest_path(@contest),
            params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: entry.id, entry_pda: expected_pda },
            as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert entry.reload.cart?, "entry stays cart until verify succeeds"
    ptx.reload
    # A1: the signature MUST persist despite the verify failure, so recovery credits
    # the already-paid entry instead of letting the user re-enter and pay twice.
    assert_equal "fake-cosign-broadcast-sig", ptx.tx_signature, "PT must carry the broadcast signature after a post-broadcast verify failure"
    assert_equal "submitted", ptx.status
  end

  # --- stamp_entry_signature tests ---

  test "stamp_entry_signature flips a pending PT to submitted with the signature" do
    @user.update!(web3_solana_address: "WalletStamp#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: ptx.slug, tx_signature: "sig-abc-123" },
      as: :json

    assert_response :success
    assert JSON.parse(response.body)["success"]
    ptx.reload
    assert_equal "submitted", ptx.status
    assert_equal "sig-abc-123", ptx.tx_signature
  end

  test "stamp_entry_signature refuses a PT belonging to another user" do
    @user.update!(web3_solana_address: "WalletA#{SecureRandom.hex(4)}")
    other_user = users(:jordan)
    other_user.update!(web3_solana_address: "WalletB#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: other_user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: other_user.web3_solana_address
    )

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: ptx.slug, tx_signature: "sig-x" },
      as: :json

    assert_response :forbidden
    assert_equal "pending", ptx.reload.status
    assert_nil ptx.tx_signature
  end

  test "stamp_entry_signature 404s when the PT is missing or already confirmed" do
    log_in_as @user

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: "ptx-nope", tx_signature: "sig" },
      as: :json
    assert_response :not_found
  end

  # --- pendingRecoveryPtxSlug exposure on contest show ---
  #
  # The recovery flow only fires when load_contest_board_data populates
  # @pending_recovery_ptx and the board partial echoes its slug into the
  # board-config JSON block. These tests assert the server-to-client
  # linkage for the four scope cases — present, wrong user, wrong contest,
  # non-pending status.

  def stranded_ptx_for(user:, contest:, status: "pending", tx_signature: nil)
    entry = contest.entries.find_or_create_by!(user: user, status: :cart)
    PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: status, target: entry, tx_signature: tx_signature,
      initiator_address: user.web3_solana_address
    )
  end

  test "contest show exposes pendingRecoveryPtxSlug for a BROADCAST (signed) pending PT here" do
    @user.update!(web3_solana_address: "Web3Show#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_show")
    log_in_as_onchain(@user)
    ptx = stranded_ptx_for(user: @user, contest: @contest, tx_signature: "sig-broadcast")

    get contest_path(@contest)
    assert_response :success
    assert_match(/"pendingRecoveryPtxSlug":"#{ptx.slug}"/, response.body,
                 "expected the board cfg to carry the stranded PT's slug")
  end

  test "contest show does NOT expose a PT belonging to another user" do
    @user.update!(web3_solana_address: "Web3Mine#{SecureRandom.hex(4)}")
    other = users(:jordan)
    other.update!(web3_solana_address: "Web3Theirs#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_x")
    log_in_as_onchain(@user)
    stranded_ptx_for(user: other, contest: @contest, tx_signature: "sig-theirs")

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "another user's stranded PT must not leak into my recovery flow")
  end

  test "contest show does NOT expose a PT for a different contest" do
    @user.update!(web3_solana_address: "Web3Diff#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_a")
    other_contest = Contest.create!(
      name: "Other Onchain", contest_type: @contest.contest_type, slate: @contest.slate,
      status: :open, onchain_contest_id: "onchain_b"
    )
    log_in_as_onchain(@user)
    stranded_ptx_for(user: @user, contest: other_contest, tx_signature: "sig-elsewhere")

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "a PT on a DIFFERENT contest must not surface as recovery on this one")
  end

  test "contest show does NOT expose a PT that has already resolved (confirmed/failed)" do
    @user.update!(web3_solana_address: "Web3Done#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_done")
    log_in_as_onchain(@user)
    stranded_ptx_for(user: @user, contest: @contest, status: "confirmed")
    stranded_ptx_for(user: @user, contest: @contest, status: "failed")

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "only pending/submitted PTs are eligible for client-side recovery")
  end

  # --- broadcast-only recovery policy (operator call, 2026-06-11) ---
  # "If it fails, it fails": only a PT that actually broadcast (carries a
  # tx_signature — real money may have moved) triggers the recovery modal.
  # Never-broadcast PTs surface nothing; stale ones are quietly retired.

  test "a signatureless pending PT is NOT surfaced for recovery (nothing was broadcast)" do
    @user.update!(web3_solana_address: "Web3NoSig#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_nosig")
    log_in_as_onchain(@user)
    stranded_ptx_for(user: @user, contest: @contest) # no tx_signature

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "a PT that never broadcast must not trigger the recovery modal")
  end

  test "a STALE signatureless pending PT is quietly retired on page load" do
    @user.update!(web3_solana_address: "Web3Stale#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_stale")
    log_in_as_onchain(@user)
    ptx = stranded_ptx_for(user: @user, contest: @contest)
    ptx.update_columns(created_at: 11.minutes.ago)

    get contest_path(@contest)
    assert_equal "expired", ptx.reload.status,
                 "stale never-broadcast PTs are retired, not recovered"
  end

  test "a FRESH signatureless pending PT is left alone (a tab may be mid-confirm)" do
    @user.update!(web3_solana_address: "Web3Fresh#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_fresh")
    log_in_as_onchain(@user)
    ptx = stranded_ptx_for(user: @user, contest: @contest)

    get contest_path(@contest)
    assert_equal "pending", ptx.reload.status,
                 "a <10min signatureless PT must not be retired out from under a mid-confirm tab"
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body)
  end

  # --- recover_pending_entry tests ---

  test "recover_pending_entry returns confirmed for an already-active entry" do
    @user.update!(web3_solana_address: "WalletR1#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :active, onchain_tx_signature: "sig-was-here")
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "submitted",
      tx_signature: "sig-x",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "sig-was-here", body["tx_signature"]
    assert_equal "confirmed", ptx.reload.status
  end

  test "recover_pending_entry busts a spent token cache for an already-active entry" do
    @user.update!(web3_solana_address: "WalletRActiveToken#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :active, onchain_tx_signature: "sig-token-active")
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "submitted",
      tx_signature: "sig-token-active",
      target: entry,
      initiator_address: @user.web3_solana_address,
      metadata: { funding: "token", entry_token_pda: "tpda_active_recovery" }.to_json
    )
    cache_key = Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address)

    with_memory_cache do
      Rails.cache.write(cache_key, [{ pda: "tpda_active_recovery", consumed: false }])

      post recover_pending_entry_contest_path(@contest),
        params: { ptx_slug: ptx.slug }, as: :json

      assert_response :success
      assert_equal "confirmed", JSON.parse(response.body)["status"]
      assert_nil Rails.cache.read(cache_key),
                 "activation can land before the live-path bust; recovery still owes the invalidation"
    end
  end

  test "recover_pending_entry marks PT failed when there is no tx_signature stamped" do
    @user.update!(web3_solana_address: "WalletR2#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert_match(/did not go through/, body["error"])
    assert_equal "failed", ptx.reload.status
  end

  test "recover_pending_entry forbids resolving another user's PT" do
    @user.update!(web3_solana_address: "WalletR3#{SecureRandom.hex(4)}")
    other = users(:jordan)
    other.update!(web3_solana_address: "WalletR4#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: other, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "submitted",
      tx_signature: "sig-y",
      target: entry,
      initiator_address: other.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :forbidden
    assert_equal "submitted", ptx.reload.status
  end

  test "recover_pending_entry returns missing when no PT matches" do
    @user.update!(web3_solana_address: "WalletR5#{SecureRandom.hex(4)}")
    log_in_as @user

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: "ptx-does-not-exist" }, as: :json

    assert_response :success
    assert_equal "missing", JSON.parse(response.body)["status"]
  end

  test "recover_pending_entry promotes entry + marks PT confirmed when RPC reports confirmed" do
    @user.update!(web3_solana_address: "WalletR6#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-confirmed-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-1" }.to_json
    )

    vault = FakeVault.new(signature_statuses: {
      "sig-confirmed-1" => { "err" => nil, "confirmationStatus" => "confirmed" }
    })
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post recover_pending_entry_contest_path(@contest),
            params: { ptx_slug: ptx.slug }, as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "sig-confirmed-1", body["tx_signature"]
    assert_equal "confirmed", ptx.reload.status
    assert entry.reload.active?, "expected entry to be promoted to active"
    assert_equal "sig-confirmed-1", entry.onchain_tx_signature
  end

  test "recover_pending_entry rejects an unverified signature (forged/unrelated tx) and leaves entry in cart" do
    @user.update!(web3_solana_address: "WalletR9#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    # Attacker stamps a real-but-unrelated finalized signature and a forged
    # entry_pda in the PT metadata.
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-forged-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-attacker-controlled" }.to_json
    )

    # RPC reports the signature finalized, but semantic verification must
    # reject it — it is not an enter_contest IX writing to this user's
    # server-derived entry PDA.
    vault = FakeVault.new(signature_statuses: {
      "sig-forged-1" => { "err" => nil, "confirmationStatus" => "finalized" }
    })
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, ->(*_a, **_k) { raise Solana::TxVerifier::VerificationError, "Transaction does not contain a `enter_contest` instruction" } do
          post recover_pending_entry_contest_path(@contest),
            params: { ptx_slug: ptx.slug }, as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert entry.reload.cart?, "a forged/unverified signature must NOT activate the entry"
    assert_nil entry.onchain_tx_signature
    assert_equal "failed", ptx.reload.status
  end

  test "recover_pending_entry returns processing when RPC doesn't know the signature" do
    @user.update!(web3_solana_address: "WalletR7#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-unknown",
      target: entry, initiator_address: @user.web3_solana_address
    )

    vault = FakeVault.new(signature_statuses: {}) # sig not seeded → RPC returns nil
    Solana::Vault.stub :new, vault do
      post recover_pending_entry_contest_path(@contest),
        params: { ptx_slug: ptx.slug }, as: :json
    end

    assert_response :success
    assert_equal "processing", JSON.parse(response.body)["status"]
    assert_equal "submitted", ptx.reload.status, "processing should not change PT status"
  end

  test "recover_pending_entry marks PT failed when RPC reports an error" do
    @user.update!(web3_solana_address: "WalletR8#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-errored",
      target: entry, initiator_address: @user.web3_solana_address
    )

    vault = FakeVault.new(signature_statuses: {
      "sig-errored" => { "err" => { "InstructionError" => [0, "Custom"] }, "confirmationStatus" => "confirmed" }
    })
    Solana::Vault.stub :new, vault do
      post recover_pending_entry_contest_path(@contest),
        params: { ptx_slug: ptx.slug }, as: :json
    end

    assert_response :success
    assert_equal "failed", JSON.parse(response.body)["status"]
    assert_equal "failed", ptx.reload.status
    assert entry.reload.cart?, "errored TX should leave entry in cart"
  end

  # --- page load tests ---

  test "index loads" do
    get contests_path
    assert_response :success
  end

  test "show loads" do
    get contest_path(@contest)
    assert_response :success
  end

  test "world_cup redirects to contest show" do
    get root_path
    assert_redirected_to contest_path(@contest)
  end

  test "world_cup redirects to index when no contests" do
    Contest.update_all(status: :pending)
    get root_path
    assert_redirected_to contests_path
  end

  # --- show tests (formerly lobby; merged 2026-05-17) ---

  test "show loads for guest" do
    get contest_path(@contest)
    assert_response :success
  end

  test "show loads for logged in user" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
  end

  test "show renders matchup board when user not in contest" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
    assert_select "section" # board renders inline
  end

  test "show shows an entries-closed state in place of Hold to Confirm once the contest is locked" do
    log_in_as(@user)
    # Derived time-lock: starts_at in the past → Contest#locked? is true.
    # update_column skips the onchain lock-time callback (test-only board).
    @contest.update_column(:starts_at, 1.minute.ago)
    assert @contest.reload.locked?, "precondition: contest should be derived-locked"

    get contest_path(@contest)
    assert_response :success
    # Specific to the picks-sidebar gate (the header's countdown also says
    # "Entries closed", so assert the unique closed-state copy instead).
    assert_match "this contest has locked", @response.body
  end

  test "show renders 'Add Nth Entry' link when user already has an entry" do
    log_in_as(@user)
    entry = @contest.entries.create!(user: @user, status: :active)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    get contest_path(@contest)
    assert_response :success
    assert_select "a", text: /Add 2nd Entry/
  end

  test "show redirects for missing contest" do
    get contest_path(id: "nonexistent")
    assert_redirected_to root_path
  end

  # --- generate_bundle (provision setup bundles) ---

  test "generator page renders for admins" do
    log_in_as(users(:alex))
    get generator_contests_path
    assert_response :success
  end

  # generate_bundle is now Phantom-driven (mirrors #create): admin must have a
  # Phantom wallet to provision because their wallet signs the prize-pool USDC
  # transfer. The actual on-chain flow needs Solana RPC + Phantom — covered by
  # the ContestBundle service test for the persistence half.
  test "generate_bundle requires a Phantom wallet" do
    log_in_as(users(:alex))
    assert_no_difference ["Contest.count", "LandingPage.count"] do
      post generate_bundle_contests_path(key: "survivor")
    end
    assert_response :unprocessable_entity
    assert_match(/phantom/i, response.parsed_body["error"].to_s)
  end

  test "generate_bundle is admin-only" do
    log_in_as(@user) # users(:sam) — not an admin
    post generate_bundle_contests_path(key: "survivor")
    assert_response :redirect
    assert_not LandingPage.exists?(slug: "survivor")
  end

  test "finalize_bundle is admin-only" do
    log_in_as(@user) # not an admin
    post finalize_bundle_contests_path
    assert_response :redirect
    assert_not LandingPage.exists?(slug: "survivor")
  end

  test "finalize_bundle rejects a tampered or expired token" do
    log_in_as(users(:alex))
    post finalize_bundle_contests_path, params: { params_token: "garbage", contest_pda: "x", tx_signature: "y" }
    assert_response :unprocessable_entity
    assert_match(/invalid or expired/i, response.parsed_body["error"].to_s)
  end

  # --- admin (operator override view) tests ---

  test "admin view renders show template for admin users" do
    log_in_as(users(:alex))  # admin role per fixtures
    get admin_contest_path(@contest)
    assert_response :success
    # Same content as the regular show page — contest name appears in the header.
    assert_includes response.body, @contest.name
  end

  test "admin view redirects non-admins" do
    log_in_as(@user)  # not admin
    get admin_contest_path(@contest)
    assert_response :redirect
  end

  test "admin view requires authentication" do
    get admin_contest_path(@contest)
    assert_response :redirect
  end

  private

  # --- lock action (derived time-lock, v0.17) ---

  test "lock now sets starts_at to ~now and makes the contest derived-locked" do
    log_in_as(users(:alex))
    travel_to Time.current do
      post lock_contest_path(@contest)
      @contest.reload
      assert_in_delta Time.current.to_i, @contest.starts_at.to_i, 5
      assert @contest.locked?, "contest should read derived-locked once starts_at is now"
    end
  end

  test "lock in 30s schedules a near-future lock that is not yet locked" do
    log_in_as(users(:alex))
    travel_to Time.current do
      post lock_contest_path(@contest, in_seconds: 30)
      @contest.reload
      assert_in_delta 30.seconds.from_now.to_i, @contest.starts_at.to_i, 5
      assert_not @contest.locked?, "a 30s-out lock should not be locked yet"
    end
  end

  test "lock is admin-only" do
    log_in_as(@user) # users(:sam) — not an admin
    original = @contest.starts_at
    post lock_contest_path(@contest)
    assert_response :redirect
    assert_equal original.to_i, @contest.reload.starts_at.to_i, "non-admin must not move the lock time"
  end

  # --- prepare_lock_time / confirm_lock_time (Phantom-signed lock, v0.17) ---

  test "prepare_lock_time builds a Phantom-signable set_contest_lock_time TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3Lock#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(admin)

    vault = FakeVault.new
    travel_to Time.current do
      Solana::Vault.stub :new, vault do
        post prepare_lock_time_contest_path(@contest, in_seconds: 30), as: :json
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert body["success"]
      assert body["serialized_tx"].start_with?("FAKE_TX_lock_")
      assert_in_delta 30.seconds.from_now.to_i, body["lock_timestamp"], 5
    end
    assert_equal 1, vault.lock_calls.length
    assert_equal admin.web3_solana_address, vault.lock_calls.first[:admin]
  end

  test "prepare_lock_time rejects a non-Phantom session" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3LockNo#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock2")
    log_in_as(admin) # email/password — no onchain session
    post prepare_lock_time_contest_path(@contest, in_seconds: 30), as: :json
    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "prepare_lock_time is admin-only" do
    @user.update!(web3_solana_address: "Web3LockSam#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock3")
    log_in_as_onchain(@user) # users(:sam) — not an admin
    post prepare_lock_time_contest_path(@contest, in_seconds: 30)
    assert_response :redirect
  end

  test "confirm_lock_time mirrors starts_at only after verifying the on-chain TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3LockC#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock4")
    log_in_as_onchain(admin)

    lock_ts = 30.seconds.from_now.to_i
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_lock_time_contest_path(@contest),
            params: { tx_signature: "lock-sig-1", lock_timestamp: lock_ts }, as: :json
        end
      end
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert_in_delta lock_ts, @contest.reload.starts_at.to_i, 2
  end

  # --- prepare_conclusion_time / confirm_conclusion_time (v0.18) ---

  test "prepare_conclusion_time builds a Phantom-signable set_contest_conclusion_time TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3Conc#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(admin)

    vault = FakeVault.new
    travel_to Time.current do
      Solana::Vault.stub :new, vault do
        post prepare_conclusion_time_contest_path(@contest, in_seconds: 60), as: :json
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert body["success"]
      assert body["serialized_tx"].start_with?("FAKE_TX_conclude_")
      assert_in_delta 60.seconds.from_now.to_i, body["conclusion_timestamp"], 5
    end
    assert_equal 1, vault.conclusion_calls.length
  end

  test "prepare_conclusion_time rejects a non-Phantom session" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3ConcNo#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc2")
    log_in_as(admin) # email/password — no onchain session
    post prepare_conclusion_time_contest_path(@contest, in_seconds: 60), as: :json
    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "confirm_conclusion_time mirrors concludes_at after verifying the on-chain TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3ConcC#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc3")
    log_in_as_onchain(admin)

    ts = 60.seconds.from_now.to_i
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_conclusion_time_contest_path(@contest),
            params: { tx_signature: "conc-sig-1", conclusion_timestamp: ts }, as: :json
        end
      end
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert_in_delta ts, @contest.reload.concludes_at.to_i, 2
  end

  # --- #live (active contest page) ---

  test "live renders for a live turf_totals contest + subscribes to the live stream" do
    @contest.update!(starts_at: 1.hour.ago) # contests(:one) — turf_totals, open → live
    get live_contest_path(@contest)
    assert_response :success
    assert_match(/turbo-cable-stream-source/, response.body)
  end

  test "live redirects to show when the contest is not yet live" do
    @contest.update!(starts_at: 1.hour.from_now)
    get live_contest_path(@contest)
    assert_redirected_to contest_path(@contest)
  end

  test "live redirects to show for a survivor contest" do
    survivor = Contest.create!(name: "Survivor Live #{SecureRandom.hex(2)}",
                               game_type: :world_cup_survivor, contest_type: "survivor_wc_free",
                               status: "open", starts_at: 1.hour.ago, rank: 8000 + rand(900))
    get live_contest_path(survivor)
    assert_redirected_to contest_path(survivor)
  end

  # --- Phantom-driven contest creation: precheck hardening + fresh unsigned rebuild ---
  #
  # #create / #rebuild_create_tx / #finalize are admin-only AND require a Phantom
  # wallet (the creator co-signs the prize-pool USDC transfer). Use a dedicated
  # admin user with a web3 address.
  def admin_phantom
    @admin_phantom ||= User.create!(
      name: "Admin Phantom", username: "admin_phantom", role: :admin,
      email: "admin_phantom@mcritchie.studio",
      web3_solana_address: "AdMiNPhantoM1111111111111111111111111111111"
    )
  end

  # Step 1 of the Phantom create flow: POST /contests, returns the parsed JSON
  # (serialized_tx, contest_pda, slug, params_token). Uses FakeVault with a
  # balance that covers any tier's prize pool.
  def run_create_via_phantom(name:, slug:, contest_type: "tiny", slate_id: slates(:one).id)
    json = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post contests_path,
        params: { contest: { name: name, slug: slug, slate_id: slate_id, contest_type: contest_type } },
        as: :json
      json = JSON.parse(response.body)
    end
    json
  end

  test "new contest form shows readable on-chain seasons" do
    log_in_as(admin_phantom)
    SeasonConfig.set_current!(2)
    vault = FakeVault.new(seasons: [
      { season_id: 2, name: "Season 2" },
      { season_id: 3, name: "Season 3" }
    ])

    Solana::Vault.stub :new, vault do
      get new_contest_path
    end

    assert_response :success
    assert_select "select#contest_season_id"
    assert_select "option[selected][value='2']", text: /Season 2 \(Current\)/
    assert_select "option[value='3']", text: "Season 3"
  end

  # Full Phantom create → finalize flow (steps 1 + 3; the on-chain sign in
  # between is the client's job; cosign/broadcast is server-side). Returns { create_json:, contest: } where
  # contest is the persisted record. Solana verification is stubbed.
  def create_contest_via_phantom(name:, slug:, contest_type: "tiny", slate_id: slates(:one).id)
    create_json = run_create_via_phantom(name: name, slug: slug, contest_type: contest_type, slate_id: slate_id)
    assert_equal true, create_json["success"], "create step failed: #{create_json.inspect}"

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_contests_path, params: {
            params_token: create_json["params_token"],
            contest_pda:  create_json["contest_pda"],
            signed_tx:    "SIGNED_CREATE_WIRE_#{slug}"
          }, as: :json
        end
      end
    end
    assert_response :success
    finalize_json = JSON.parse(response.body)
    assert_equal true, finalize_json["success"], "finalize step failed: #{finalize_json.inspect}"

    { create_json: create_json, contest: Contest.find_by!(slug: finalize_json["slug"]) }
  end

  test "create blocks when the USDC balance read fails (RPC exception is a HARD BLOCK, not a $0 pass)" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance_raises: true)

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup A", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_match(/couldn't verify your USDC balance/i, json["error"])
    # Never reached the TX build — a failed read must short-circuit.
    assert_empty vault.create_contest_calls
  end

  test "create blocks when the USDC balance read returns nil (unreadable response is a HARD BLOCK)" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance: nil) # get_token_account_balance → nil

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup B", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/couldn't verify your USDC balance/i, json["error"])
    assert_empty vault.create_contest_calls
  end

  test "create blocks with insufficient-USDC message when a readable balance is below the prize pool" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance: 1.0) # $1 readable, tiny needs $45

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup C", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Insufficient USDC/i, json["error"])
    assert_empty vault.create_contest_calls
  end

  test "create blocks before Phantom signing when the current on-chain season is unavailable" do
    log_in_as(admin_phantom)
    SeasonConfig.set_current!(7)
    vault = FakeVault.new(usdc_balance: 100.0, season: nil)

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Season Missing Cup", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_match(/Season 7 is not initialized/i, json["error"])
    assert_empty vault.create_contest_calls
  end

  test "create builds the unsigned TX when a readable balance covers the prize pool" do
    log_in_as(admin_phantom)
    SeasonConfig.set_current!(2)
    vault = FakeVault.new(usdc_balance: 100.0, season: { season_id: 2 }) # $100 covers tiny's $45

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup D", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "FAKE_TX_create_blockhash-cup-d", json["serialized_tx"]
    assert json["params_token"].present?, "create must issue a params_token for rebuild + finalize"
    assert_equal 1, vault.create_contest_calls.length
    assert_equal false, vault.create_contest_calls.first[:params][:admin_signs]
    assert_equal 2, vault.create_contest_calls.first[:params][:season_id]
  end

  test "create uses the season selected in the form" do
    log_in_as(admin_phantom)
    SeasonConfig.set_current!(1)
    vault = FakeVault.new(usdc_balance: 100.0, season: { season_id: 2 })

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Selected Season Cup", slate_id: slates(:one).id, contest_type: "tiny", season_id: 2 } },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal 2, vault.create_contest_calls.first[:params][:season_id]
  end

  test "finalize rejects a signed create tx that does not match the issued contest payload" do
    log_in_as(admin_phantom)
    create_json = run_create_via_phantom(name: "Unsafe Create", slug: "unsafe-create", contest_type: "tiny")
    assert_equal true, create_json["success"], create_json.inspect

    vault = FakeVault.new
    vault.create_cosign_safe_raises = "wrong create_contest ix"

    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        post finalize_contests_path, params: {
          params_token: create_json["params_token"],
          contest_pda:  create_json["contest_pda"],
          signed_tx:    "MALICIOUS_CREATE_WIRE"
        }, as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_match(/did not match/i, body["error"])
    assert_empty vault.create_cosign_broadcast_calls
    assert_not Contest.exists?(slug: "unsafe-create")
  end

  # ── name/slug decouple (epic Part A) — create path keys off the manual slug ──

  # THE KEY CASE: two contests with the SAME name but DIFFERENT manual slugs both
  # create successfully through the full Phantom create → finalize flow, and the
  # on-chain contest_id / PDA + serialized_tx derive from the MANUAL slug (not the
  # name). Proves duplicate names no longer collide on slug or on the PDA.
  test "two contests with the same name but different slugs both create; PDA derives from the manual slug" do
    log_in_as(admin_phantom)

    first  = create_contest_via_phantom(name: "World Cup Group A", slug: "wc-group-a-morning", contest_type: "tiny")
    second = create_contest_via_phantom(name: "World Cup Group A", slug: "wc-group-a-evening", contest_type: "tiny")

    # Both persisted, same name, distinct slugs.
    assert first[:contest].persisted?
    assert second[:contest].persisted?
    assert_equal "World Cup Group A", first[:contest].name
    assert_equal "World Cup Group A", second[:contest].name
    assert_equal "wc-group-a-morning", first[:contest].slug
    assert_equal "wc-group-a-evening", second[:contest].slug

    # The on-chain leg keyed off the MANUAL slug, not the (shared) name:
    #   build_create_contest was called with the slug, and the contest_pda /
    #   serialized_tx the client signs both derive from it.
    assert_equal "wc-group-a-morning", first[:create_json]["slug"]
    assert_equal "cpda-wc-group-a-morning", first[:create_json]["contest_pda"]
    assert_equal "FAKE_TX_create_wc-group-a-morning", first[:create_json]["serialized_tx"]
    assert_equal "cpda-wc-group-a-evening", second[:create_json]["contest_pda"]

    # The persisted on-chain id mirrors the slug-derived PDA the TX created.
    assert_equal "cpda-wc-group-a-morning", first[:contest].onchain_contest_id
    assert_equal "cpda-wc-group-a-evening", second[:contest].onchain_contest_id
  end

  test "create blocks a second contest reusing an existing slug (different name)" do
    log_in_as(admin_phantom)
    create_contest_via_phantom(name: "Original", slug: "dup-slug-x", contest_type: "tiny")

    # Same slug, DIFFERENT name → the precheck must refuse before a Phantom
    # signature is burned. The user-facing error keys off the slug, not the name.
    second = run_create_via_phantom(name: "Different Name", slug: "dup-slug-x", contest_type: "tiny")

    assert_response :unprocessable_entity
    assert_equal false, second["success"]
    # Rejected on the slug (the model's uniqueness check fires first), never the
    # name — proving the dup-name guard moved onto the slug.
    assert_match(/slug.*(already|taken)/i, second["error"])
    assert_no_match(/name/i, second["error"])
    assert_nil second["params_token"], "a blocked create must not issue a finalize token"
  end

  # Bundle provisioning (generate_bundle → finalize_bundle) keys the on-chain
  # contest_id/PDA off the bundle spec's EXPLICIT slug, not a name-derived one.
  # The "survivor" bundle has slug "world-cup-survivor-free-roll" but a name of
  # "World Cup Survivor Free Roll" — proving the PDA derives from the slug
  # (FakeVault returns cpda-<slug>), the round-trip persists, and finalize stores
  # that slug-derived PDA as onchain_contest_id.
  test "generate_bundle/finalize_bundle derive the PDA from the bundle's explicit slug" do
    log_in_as(admin_phantom)
    bundle_slug = ContestBundle::ALL["survivor"][:contest][:slug]
    assert_equal "world-cup-survivor-free-roll", bundle_slug

    # Step 1: generate_bundle builds the partially-signed create TX. The
    # contest_pda + serialized_tx + returned slug all derive from the explicit
    # bundle slug (FakeVault: cpda-<slug> / FAKE_TX_create_<slug>).
    gen = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post generate_bundle_contests_path(key: "survivor")
      gen = JSON.parse(response.body)
    end
    assert_response :success
    assert_equal true, gen["success"], gen.inspect
    assert_equal bundle_slug, gen["slug"]
    assert_equal "cpda-#{bundle_slug}", gen["contest_pda"]
    assert_equal "FAKE_TX_create_#{bundle_slug}", gen["serialized_tx"]
    assert gen["params_token"].present?

    # Step 3: finalize_bundle persists the Contest + LandingPage. The PDA it
    # verifies + stores is re-derived server-side from the SAME slug (identity
    # encode_base58 stub → cpda-<slug>), so onchain_contest_id matches.
    fin = nil
    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_bundle_contests_path, params: {
            params_token: gen["params_token"],
            contest_pda:  gen["contest_pda"],
            tx_signature: "sig-bundle-#{SecureRandom.hex(2)}"
          }
        end
      end
    end
    assert_response :success
    fin = JSON.parse(response.body)
    assert_equal true, fin["success"], fin.inspect

    contest = Contest.find_by!(slug: bundle_slug)
    assert_equal bundle_slug, contest.slug
    assert_equal "World Cup Survivor Free Roll", contest.name # slug != parameterized name path; explicit
    assert_equal "cpda-#{bundle_slug}", contest.onchain_contest_id
    assert LandingPage.exists?(slug: "survivor")
  end

  test "rebuild_create_tx re-issues a fresh unsigned TX from the create params_token" do
    log_in_as(admin_phantom)
    SeasonConfig.set_current!(2)
    token = nil
    build_vault = FakeVault.new(usdc_balance: 100.0, season: { season_id: 2 })

    Solana::Vault.stub :new, build_vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup E", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
      token = JSON.parse(response.body)["params_token"]
    end
    assert token.present?

    SeasonConfig.set_current!(3)
    # The rebuild call must NOT re-run the precheck (no balance read) — it
    # only re-issues the admin-cosigned TX over a fresh blockhash, using the
    # season id bound into the signed create token. A vault with NO balance
    # configured (would block in precheck) still succeeds here.
    rebuild_vault = FakeVault.new(season: { season_id: 2 })
    Solana::Vault.stub :new, rebuild_vault do
      post rebuild_create_tx_contests_path, params: { params_token: token }, as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "FAKE_TX_create_blockhash-cup-e", json["serialized_tx"]
    assert_equal 1, rebuild_vault.create_contest_calls.length
    assert_equal 2, rebuild_vault.create_contest_calls.first[:params][:season_id]
  end

  test "rebuild_create_tx rejects a token issued to a different user" do
    log_in_as(admin_phantom)
    token = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100.0) do
      post contests_path,
        params: { contest: { name: "Blockhash Cup F", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
      token = JSON.parse(response.body)["params_token"]
    end

    # Re-issue as a different admin+phantom user — the token's user_id won't match.
    other = User.create!(name: "Other", username: "other_phantom", role: :admin,
                         email: "other_phantom@mcritchie.studio",
                         web3_solana_address: "9aBcD3FgHjKmNpQrStUvWxYz1234567890aBcDeFgH12")
    log_in_as(other)
    Solana::Vault.stub :new, FakeVault.new do
      post rebuild_create_tx_contests_path, params: { params_token: token }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/User mismatch/i, json["error"])
  end

  # A free, off-chain contest — the only kind a successful #enter can be
  # exercised against without a Solana RPC mock (paid entries need a real
  # on-chain token consume / vault transfer). Free entries skip the payment gate.
  def free_contest
    Contest.create!(
      name: "Free Plumbing Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 0,
      max_entries: 29,
      status: :open,
      starts_at: 2.weeks.from_now
    )
  end
end
