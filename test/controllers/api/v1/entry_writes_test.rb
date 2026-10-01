require "test_helper"

# [integration] POST /api/v1/contests/:slug/entries and PATCH /api/v1/entries/:slug
# over HTTP: the happy paths, every error code the doc lists, and the retry
# rules as a client sees them. The idempotency state machine itself is
# exercised state by state in test/services/entries/api_submission_test.rb.
#
# Spends are counted on LedgerVault (test/support/ledger_vault.rb), which keeps
# the chain's books: `tickets` are entries that exist on chain.
class Api::V1::EntryWritesTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @key = mint_api_key(@user)
    @picks = fixture_matchups.map(&:id)
    @vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }])
  end

  def enter(picks = @picks, **options)
    on_chain(@vault) { api_enter(@contest, picks, **options) }
  end

  def edit(entry, picks, **options)
    on_chain(@vault) { api_write(:patch, api_v1_entry_path(entry.slug), body: { matchup_ids: picks }, **options) }
  end

  def my_entries
    @contest.entries.where(user: @user)
  end

  def assert_nothing_spent
    assert_empty @vault.tickets
    assert_empty @vault.spent_tokens
    assert_empty my_entries.where.not(status: :cart), "an entry was created"
  end

  def assert_refused(code, status: :unprocessable_entity)
    assert_api_error status, code
    assert_nothing_spent
  end

  # ── POST: the happy path ──────────────────────────────────────────────────

  test "POST creates a funded, active entry in one call and answers 201 in the read shape" do
    enter

    assert_response :created
    assert_equal %w[entry funding], json.keys
    assert_equal({ "method" => "token", "token_consumed" => true }, json["funding"])
    entry = my_entries.sole
    assert entry.active?
    assert_equal entry.slug, json.dig("entry", "slug")
    assert_equal "active", json.dig("entry", "status")
    assert_equal true, json.dig("entry", "editable")
    assert_equal @vault.tickets.sole[:signature], json.dig("entry", "tx_signature")
    assert_equal @picks.sort, json.dig("entry", "picks").map { |pick| pick["matchup_id"] }.sort
    assert_nil response.headers["Idempotent-Replayed"]

    created = json["entry"]
    api_get api_v1_entry_path(entry.slug)
    assert_equal json["entry"], created, "the 201 body is exactly what GET /entries/:slug returns"
  end

  test "POST with the same Idempotency-Key replays the first answer and spends one token" do
    @vault.grant_token("token-2")
    enter(idem: "retry-me")
    first = response.body

    enter(idem: "retry-me")

    assert_response :created
    assert_equal first, response.body
    assert_equal "true", response.headers["Idempotent-Replayed"]
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "POST allow_usdc pays the fee in USDC when there is no token" do
    @vault = LedgerVault.new(tokens: [], usdc: 50.0)

    AppFlags.stub(:web2_usdc_entry?, true) { enter(allow_usdc: true) }

    assert_response :created
    assert_equal({ "method" => "usdc", "token_consumed" => false }, json["funding"])
    assert_in_delta 31.0, @vault.usdc_balance
  end

  # ── POST: 400s, before anything is recorded ───────────────────────────────

  test "POST without an Idempotency-Key is a 400 and records nothing" do
    enter(idem: nil)

    assert_refused "bad_request", status: :bad_request
    assert_match(/Idempotency-Key/, json.dig("error", "message"))
    assert_equal 0, ApiEntryRequest.count
  end

  test "POST with a malformed Idempotency-Key is a 400" do
    ["has space", "x" * 256, "tab\there"].each do |bad|
      enter(idem: bad)
      assert_refused "bad_request", status: :bad_request
    end
  end

  test "POST with malformed parameters is a 400, never a 500" do
    bodies = [
      {}, { matchup_ids: "1,2,3" }, { matchup_ids: [] }, { matchup_ids: [1, "two"] }, { matchup_ids: { a: 1 } },
      { matchup_ids: [1, [2]] }, { matchup_ids: [-1] }, { matchup_ids: [10**30] },
      { matchup_ids: @picks, allow_usdc: "yes" }, { matchup_ids: @picks, allow_usdc: 1 },
      { matchup_ids: @picks, allow_usdc: "true" }, { matchup_ids: @picks, allow_usdc: "false" }
    ]

    bodies.each do |body|
      on_chain(@vault) do
        api_write(:post, api_v1_contest_entries_path(@contest.slug), body: body,
                                                                     headers: { "Idempotency-Key" => SecureRandom.uuid })
      end
      assert_api_error :bad_request, "bad_request"
    end
    assert_nothing_spent
    assert_equal 0, ApiEntryRequest.count
  end

  test "POST with a body that is not JSON is a 400 in the envelope" do
    post api_v1_contest_entries_path(@contest.slug), params: "{not json",
                                                     headers: { "Authorization" => "Bearer #{@key.raw_token}", "Content-Type" => "application/json",
                                                                "Idempotency-Key" => "k", "User-Agent" => AGENT_UA }

    assert_api_error :bad_request, "bad_request"
  end

  test "POST without a key is a 401, and to an unknown contest a 404" do
    enter(key: nil)
    assert_refused "missing_api_key", status: :unauthorized

    on_chain(@vault) { api_write(:post, api_v1_contest_entries_path("no-such-contest"), body: { matchup_ids: @picks }, headers: { "Idempotency-Key" => "k" }) }
    assert_refused "not_found", status: :not_found
  end

  # ── POST: the account gates ───────────────────────────────────────────────

  test "POST from a frozen account is 403 account_frozen" do
    @user.freeze_for_payment_risk!(reason: "test")

    enter

    assert_refused "account_frozen", status: :forbidden
  end

  test "POST with the age gate on and no verified date of birth is 403 age_verification_required" do
    AppFlags.stub :age_gate?, true do
      enter
      assert_refused "age_verification_required", status: :forbidden

      @user.update!(age_attested_at: Time.current)
      enter
      assert_response :created
    end
  end

  # ── POST: every 422 ───────────────────────────────────────────────────────

  test "POST contest_not_open: a settled contest" do
    @contest.update!(status: :settled)
    enter
    assert_refused "contest_not_open"
  end

  test "POST contest_locked: the lock time has passed" do
    @contest.update!(starts_at: 1.minute.ago)
    enter
    assert_refused "contest_locked"
  end

  test "POST contest_cancelled" do
    @contest.update!(onchain_cancelled: true)
    enter
    assert_refused "contest_cancelled"
  end

  test "POST coming_soon" do
    @contest.update!(coming_soon: true)
    enter
    assert_refused "coming_soon"
  end

  test "POST contest_full" do
    @contest.update!(max_entries: 1)
    enter!(users(:jordan), @contest, fixture_matchups)
    enter
    assert_refused "contest_full"
  end

  test "POST entry_limit_reached: the player already holds three entries" do
    g, h = extra_matchups
    [fixture_matchups.first(5) + [g], fixture_matchups.first(5) + [h], fixture_matchups.last(5) + [g]].each do |lineup|
      enter!(@user, @contest, lineup)
    end

    enter

    assert_api_error :unprocessable_entity, "entry_limit_reached"
    assert_empty @vault.tickets
    assert_equal 3, my_entries.count
  end

  test "POST invalid_picks: wrong count, a repeat, an id from elsewhere" do
    foreign = SlateMatchup.create!(slate: Slate.create!(name: "Other #{SecureRandom.hex(2)}"), team_slug: "team-a",
                                   rank: 1, turf_score: 1.0, status: "pending")
    [@picks.first(5), @picks.first(5) + [@picks.first], @picks.first(5) + [foreign.id], @picks + [foreign.id]].each do |picks|
      enter(picks)
      assert_refused "invalid_picks"
    end
  end

  test "POST invalid_picks: a later-week row of a span slate is not a pickable id" do
    extend SpanContestBuilder
    build_span_contest!(@contest)
    anchors = @contest.pickable_matchup_ids
    later = span_row(@contest, "team-a", week: 2)

    enter(anchors.first(5) + [later.id])
    assert_refused "invalid_picks"

    enter(anchors)
    assert_response :created
  end

  test "POST duplicate_lineup: the player already holds this exact lineup" do
    enter!(@user, @contest, fixture_matchups)

    enter

    assert_api_error :unprocessable_entity, "duplicate_lineup"
    assert_empty @vault.tickets
    assert_empty @vault.spent_tokens
  end

  test "POST team_locked: a team whose game has kicked off cannot be picked" do
    game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 1.hour.ago)
    slate_matchups(:m1).update!(game_slug: game.slug)

    enter

    assert_refused "team_locked"
    assert_match(/Team A/, json.dig("error", "message"))
  end

  test "POST no_entry_token: token only by default, even with USDC in the wallet and USDC entry on" do
    @vault = LedgerVault.new(tokens: [], usdc: 500.0)

    AppFlags.stub(:web2_usdc_entry?, true) { enter }

    assert_refused "no_entry_token"
    assert_equal 500.0, @vault.usdc_balance
    assert_match(/allow_usdc/, json.dig("error", "message"))
  end

  test "POST insufficient_funds: allow_usdc with too little USDC" do
    @vault = LedgerVault.new(tokens: [], usdc: 3.0)

    AppFlags.stub(:web2_usdc_entry?, true) { enter(allow_usdc: true) }

    assert_refused "insufficient_funds"
    assert_equal 3.0, @vault.usdc_balance
  end

  test "POST wallet_not_server_signable: self-custodied, Phantom-linked, and no wallet" do
    arrangements = [
      -> { @user.update!(self_custodied_at: Time.current) },
      -> { @user.update!(web3_solana_address: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds") },
      -> { @user.update!(web2_solana_address: nil, encrypted_web2_solana_private_key: nil) }
    ]

    arrangements.each do |arrange|
      make_managed!(@user).update!(self_custodied_at: nil)
      arrange.call
      enter
      assert_refused "wallet_not_server_signable"
      assert_match(/turfmonster\.media/, json.dig("error", "message"))
    end
  end

  test "POST unsupported_contest: a survivor contest is not entered through the API" do
    @contest.update!(game_type: :world_cup_survivor, slate: nil)
    enter
    assert_refused "unsupported_contest"
  end

  # ── POST: 409 and 503 ─────────────────────────────────────────────────────

  test "POST idempotency_key_reused: the same key with a different body is a 409" do
    g, = extra_matchups
    @vault.grant_token("token-2")
    enter(idem: "one-key")

    enter(@picks.first(5) + [g.id], idem: "one-key")

    assert_api_error :conflict, "idempotency_key_reused"
    assert_equal 1, @vault.tickets.size
    assert_equal 1, my_entries.count
  end

  # The guide's advice for this code has to END. "Send the original body" does
  # not, in this case: the body IS the original, and the answer never changes.
  # What ends it is a new key, which is what the guide now says.
  test "POST idempotency_key_reused: a key whose entry a reset removed answers 409 for the original body, every time, and a new key gets through" do
    enter(idem: "reset-key")
    assert_response :created
    # A contest reset deletes the entry rows; the request row survives with its
    # entry_id nulled (the foreign key is ON DELETE SET NULL). This is the row
    # of a request that never stored its response.
    request_row = ApiEntryRequest.find_by!(user: @user, idempotency_key: "reset-key")
    request_row.update_columns(response_body: nil)
    my_entries.each(&:destroy!)
    assert_nil request_row.reload.entry_id

    2.times do
      enter(idem: "reset-key")
      assert_api_error :conflict, "idempotency_key_reused"
      assert_match(/no longer exists\. Use a new key/, json["error"]["message"])
    end
    assert_empty my_entries.where.not(status: :cart)

    # A new key is a new request and gets a definite answer of its own. It is
    # also a new entry that is paid for again, which is why the guide asks for
    # the player's yes first: with no second token the answer is no_entry_token.
    enter(idem: "after-reset-key")
    assert_api_error :unprocessable_entity, "no_entry_token"

    @vault.grant_token("token-2")
    enter(idem: "after-reset-key")
    assert_response :created
    assert_equal 1, my_entries.where(status: :active).count
  end

  test "POST idempotency_in_progress: a concurrent duplicate is a 409 with Retry-After and spends nothing" do
    duplicate = nil
    @vault.grant_token("token-2")
    @vault.before_enter = lambda do
      @vault.before_enter = nil
      other = open_session
      other.post api_v1_contest_entries_path(@contest.slug), params: { matchup_ids: @picks }, as: :json,
                                                             headers: { "Authorization" => "Bearer #{@key.raw_token}", "Idempotency-Key" => "same", "User-Agent" => AGENT_UA }
      duplicate = [other.response.status, JSON.parse(other.response.body), other.response.headers["Retry-After"]]
    end

    enter(idem: "same")

    assert_response :created
    assert_equal [409, "idempotency_in_progress", "2"], [duplicate[0], duplicate[1].dig("error", "code"), duplicate[2]]
    assert_equal 2, duplicate[1].dig("error", "retry_after")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "POST chain_unavailable: a lost answer is a 503, and the retry returns the one paid entry" do
    @vault.fail_next_enter = :lost
    @vault.grant_token("token-2")

    enter(idem: "lost")

    assert_api_error :service_unavailable, "chain_unavailable"
    assert_equal "5", response.headers["Retry-After"]
    assert_equal 1, @vault.tickets.size

    enter(idem: "lost")

    assert_response :created
    assert_equal @vault.tickets.sole[:signature], json.dig("entry", "tx_signature")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "POST chain_unavailable: a landing the node reports as 'already been processed' is one entry on retry" do
    @vault.fail_next_enter = :resent
    @vault.grant_token("token-2")

    enter(idem: "resent")
    assert_api_error :service_unavailable, "chain_unavailable"

    enter(idem: "resent")
    assert_response :created
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "POST chain_unavailable: an unreadable chain spends nothing and the same key works afterwards" do
    @vault.token_read_raises = true
    enter(idem: "flaky")
    assert_refused "chain_unavailable", status: :service_unavailable

    @vault.token_read_raises = false
    enter(idem: "flaky")
    assert_response :created
    assert_equal 1, @vault.tickets.size
  end

  test "POST 202: paid but not yet confirmed; the same key then returns the entry" do
    boom = ->(*, **) { raise ActiveRecord::StatementInvalid, "simulated post-broadcast DB failure" }
    TransactionLog.stub(:record!, boom) { enter(idem: "paid") }

    assert_response :accepted
    assert_equal({ "entry" => nil, "funding" => { "method" => "token", "token_consumed" => true },
                   "pending" => true, "retry_after" => 5 }, json)
    assert_equal "5", response.headers["Retry-After"]
    api_get api_v1_entries_path
    assert_empty json["entries"], "an unconfirmed entry is not listed"

    enter(idem: "paid")

    assert_response :created
    assert_equal "active", json.dig("entry", "status")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, my_entries.count
  end

  # ── PATCH ─────────────────────────────────────────────────────────────────

  def entered
    enter
    assert_response :created
    my_entries.sole
  end

  test "PATCH replaces the picks and answers 200 with the entry" do
    entry = entered
    g, = extra_matchups
    swapped = @picks.first(5) + [g.id]

    edit(entry, swapped)

    assert_response :success
    assert_equal %w[entry], json.keys
    assert_equal entry.slug, json.dig("entry", "slug")
    assert_equal swapped.sort, json.dig("entry", "picks").map { |pick| pick["matchup_id"] }.sort
    assert_equal swapped.sort, entry.reload.selections.pluck(:slate_matchup_id).sort
    assert_equal 1, @vault.tickets.size, "an edit is not a spend"

    edit(entry, swapped)
    assert_response :success, "the same picks again is the same entry again"
  end

  test "PATCH contest_locked once the lock time has passed" do
    entry = entered
    g, = extra_matchups
    @contest.update!(starts_at: 1.minute.ago)

    edit(entry, @picks.first(5) + [g.id])

    assert_api_error :unprocessable_entity, "contest_locked"
    assert_equal @picks.sort, entry.reload.selections.pluck(:slate_matchup_id).sort
  end

  test "PATCH team_locked: a team whose game has kicked off cannot be dropped or added" do
    entry = entered
    g, h = extra_matchups
    past = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 1.hour.ago)

    slate_matchups(:m1).update!(game_slug: past.slug)
    edit(entry, @picks.drop(1) + [g.id])
    assert_api_error :unprocessable_entity, "team_locked"
    assert_match(/Team A/, json.dig("error", "message"))

    slate_matchups(:m1).update!(game_slug: nil)
    h.update!(game_slug: past.slug)
    edit(entry, @picks.first(5) + [h.id])
    assert_api_error :unprocessable_entity, "team_locked"

    assert_equal @picks.sort, entry.reload.selections.pluck(:slate_matchup_id).sort

    slate_matchups(:m1).update!(game_slug: past.slug)
    edit(entry, @picks.first(5) + [g.id])
    assert_response :success, "a kicked-off team that stays in the lineup does not block an edit elsewhere"
  end

  test "PATCH invalid_picks, duplicate_lineup, contest_cancelled and contest_not_open" do
    entry = entered
    g, = extra_matchups
    other = @picks.first(5) + [g.id]

    edit(entry, @picks.first(5))
    assert_api_error :unprocessable_entity, "invalid_picks"

    enter!(@user, @contest, SlateMatchup.where(id: other).to_a)
    edit(entry, other)
    assert_api_error :unprocessable_entity, "duplicate_lineup"

    @contest.update!(onchain_cancelled: true)
    edit(entry, @picks.last(5) + [g.id])
    assert_api_error :unprocessable_entity, "contest_cancelled"

    @contest.update!(onchain_cancelled: false, status: :settled)
    edit(entry, @picks.last(5) + [g.id])
    assert_api_error :unprocessable_entity, "contest_not_open"

    assert_equal @picks.sort, entry.reload.selections.pluck(:slate_matchup_id).sort
  end

  test "PATCH is refused for a frozen account and under the age gate, and 400 on bad parameters" do
    entry = entered

    on_chain(@vault) { api_write(:patch, api_v1_entry_path(entry.slug), body: { matchup_ids: "nope" }) }
    assert_api_error :bad_request, "bad_request"

    AppFlags.stub :age_gate?, true do
      edit(entry, @picks)
      assert_api_error :forbidden, "age_verification_required"
    end

    @user.freeze_for_payment_risk!(reason: "test")
    edit(entry, @picks)
    assert_api_error :forbidden, "account_frozen"
  end

  test "PATCH reaches only the caller's own confirmed entries" do
    rival = enter!(users(:jordan), @contest, fixture_matchups)
    cart = @contest.entries.create!(user: @user, status: :cart)

    [rival, cart].each do |entry|
      edit(entry, @picks)
      assert_api_error :not_found, "not_found"
    end
  end

  # ── the read shape agrees with what the writes will do ────────────────────

  test "editable and accepting_entries are false for an account that may not write" do
    entry = entered
    flags = lambda do
      api_get api_v1_contest_path(@contest.slug)
      accepting = json.dig("contest", "accepting_entries")
      api_get api_v1_entry_path(entry.slug)
      [accepting, json.dig("entry", "editable")]
    end

    assert_equal [true, true], flags.call

    AppFlags.stub(:age_gate?, true) { assert_equal [false, false], flags.call }

    @user.freeze_for_payment_risk!(reason: "test")
    assert_equal [false, false], flags.call
  end

  test "editable is false in a cancelled contest, and accepting_entries false for a survivor contest" do
    entry = entered
    @contest.update!(onchain_cancelled: true)
    api_get api_v1_entry_path(entry.slug)
    assert_equal false, json.dig("entry", "editable")

    @contest.update!(onchain_cancelled: false, game_type: :world_cup_survivor)
    api_get api_v1_contests_path
    assert_equal [false], json["contests"].map { |contest| contest["accepting_entries"] }.uniq
  end
end
