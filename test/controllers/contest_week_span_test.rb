require "test_helper"
require "minitest/mock"

# The create form's "Weeks" control and the server-side span resolution behind
# it. The span is NOT trusted from the form: the controller resolves it into the
# ONE span slate the contest is played on, and refuses rather than truncates.
class ContestWeekSpanTest < ActionDispatch::IntegrationTest
  setup do
    @w1 = Slate.create!(name: "NFL 2026 Week 1", slug: "nfl-2026-week-1", week: 1)
    @w2 = Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2", week: 2)
    @w3 = Slate.create!(name: "NFL 2026 Week 3", slug: "nfl-2026-week-3", week: 3)
    [[@w1, 1], [@w2, 2], [@w3, 3]].each do |slate, week|
      %w[team-a team-b].each_with_index do |team, index|
        SlateMatchup.create!(slate: slate, team_slug: team, opponent_team_slug: "team-f",
                             game_slug: "#{team}-wk#{week}-#{SecureRandom.hex(3)}",
                             week: week, expected_score: 25.0 - index, status: "pending")
      end
    end
    log_in_as(users(:alex)) # admin
  end

  # Pins the CALL SITE. contests_controller previously derived the span year from the
  # anchor's NAME with an unbounded /\b(\d{4})\b/, so "Week 1234 Showcase" resolved year
  # 1234. It now reads Slate#season_year (column-first, bounded to 20xx).
  #
  # A SOURCE assertion, deliberately, and the repo already uses this shape
  # (test/views/tokens_pack_button_test.rb greps render sites). Asserting only that
  # #season_year is bounded left the controller free to go back to the regex — that
  # mutation passed the entire suite. This is narrow but it kills exactly that.
  test "the span year is read from the slate column, not parsed from its name" do
    source = File.read(Rails.root.join("app/controllers/contests_controller.rb"))
    span_method = source[/def resolve_span_slate.*?\n  end/m]
    refute_nil span_method, "resolve_span_slate not found — update this guard"

    assert_includes span_method, "anchor.season_year",
                    "the span year must come from the column via Slate#season_year"
    refute_match(/anchor\.name\[/, span_method,
                 "the span year must not be parsed out of the slate NAME — an unbounded " \
                 "4-digit match reads \"Week 1234\" as year 1234")
  end

  test "the create form offers a week span control" do
    get new_contest_path

    assert_response :success
    assert_select "select#contest_week_span"
    assert_select "select#contest_week_span option", text: "3 weeks"
  end

  test "weekly NFL slates are selectable even though they have no start time" do
    assert_nil @w1.starts_at

    get new_contest_path

    assert_response :success
    assert_select "select#contest_slate_id option", text: "NFL 2026 Week 1"
  end

  test "the generator renders slates that have no start time" do
    # Regression: making weekly slates selectable exposed them to the generator,
    # which called strftime on a nil starts_at and 500'd the whole page.
    assert_nil @w1.starts_at
    assert_nil @w1.first_game_starts_at

    get generator_contests_path

    assert_response :success
    assert_includes response.body, "NFL 2026 Week 1"
    assert_includes response.body, "no scheduled start"
  end

  test "the generator still shows a start time when the slate has one" do
    dated = Slate.create!(name: "Dated Slate", slug: "dated-slate", starts_at: 5.days.from_now)

    get generator_contests_path

    assert_response :success
    assert_includes response.body, "starts #{dated.starts_at.strftime('%b %-d, %Y')}"
  end

  # --- span assembly ------------------------------------------------------

  test "a span builds ONE slate holding every week's games" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal "NFL 2026 Weeks 1-3", span.name
    assert_equal 6, span.slate_matchups.count, "2 teams x 3 weeks"
    assert_equal 3, span.games_per_team
    assert span.multi_game_per_team?
  end

  test "the span slate stores a FROZEN multiplier on every row of a team" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    scores = span.matchups_by_team["team-a"].map(&:turf_score).uniq
    assert_equal 1, scores.size, "one multiplier per team, written to all its rows"
    assert scores.first.present?
    # Highest summed expectation ranks 1, which is exactly the 1.0x floor.
    assert_equal 1.0, scores.first.to_f
  end

  test "a span REFUSES a gap instead of silently truncating" do
    @w2.slate_matchups.destroy_all
    @w2.destroy!

    # Truncating here would sell a three-week contest, mint it on-chain with
    # three-week fees and prize pool, and then score it as two weeks.
    error = assert_raises(Nfl::BuildSpanSlate::Error) do
      Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    end
    assert_match(/week 2/, error.message)
  end

  test "a span REFUSES a week the season does not have" do
    error = assert_raises(Nfl::BuildSpanSlate::Error) do
      Nfl::BuildSpanSlate.call(year: 2026, weeks: [17, 18, 19])
    end
    assert_match(/17/, error.message)
  end

  test "a span never absorbs a slate from another season" do
    # Same week numbers, different year. slates carry a week but no year column,
    # so the year lives in the name — a lookup on week alone would collapse them.
    other = Slate.create!(name: "NFL 2025 Week 1", slug: "nfl-2025-week-1", week: 1)
    SlateMatchup.create!(slate: other, team_slug: "team-c", opponent_team_slug: "team-f",
                         game_slug: "stale-#{SecureRandom.hex(3)}", week: 1,
                         expected_score: 99.0, status: "pending")

    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_not_includes span.matchups_by_team.keys, "team-c",
                        "a 2026 span must not pull in a 2025 slate"
  end

  test "rebuilding a span does not duplicate its games" do
    Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal 6, span.slate_matchups.count
  end

  # --- frozen-slate guard: real-funds payout integrity --------------------
  #
  # #create runs BuildSpanSlate.call on EVERY span create, and the span slate is
  # REUSED by (year, anchor-week, span) via find_or_create_by!. A rebuild does
  # slate.slate_matchups.destroy_all, and SlateMatchup has_many :selections,
  # dependent: :destroy — so a SECOND contest on the same span (a normal
  # multi-tier GTM pattern) would cascade-delete the FIRST live contest's
  # Selections. Those entries would then hold zero picks, settle to 0, and pay
  # the wrong USDC on live mainnet. The guard freezes a span slate once it backs
  # any pick: it is deterministic for a (year, weeks), so reuse it AS-IS.

  test "a fresh span with no picks still builds its matchups" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal 6, span.slate_matchups.count, "first build populates the pool"
  end

  test "a second span build preserves the first contest's live picks" do
    first = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    # A real pick on the first contest: a Selection on one of the span's rows.
    picked = first.matchups_by_team["team-a"].first
    selection = Selection.create!(entry: entries(:one), slate_matchup: picked)
    frozen_score = picked.turf_score

    # A SECOND contest on the SAME year+anchor-week+span reuses the slate.
    second = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])

    assert_equal first.id, second.id, "the span slate is reused, not duplicated"
    assert Selection.exists?(selection.id), "the first contest's live pick must survive"
    assert_equal picked.id, selection.reload.slate_matchup_id, "and stay linked to its matchup"
    assert_equal 1, Selection.where(slate_matchup: SlateMatchup.where(slate_id: first.id)).count
    assert_equal 6, second.slate_matchups.count, "the frozen slate's rows are untouched"
    assert_equal frozen_score, picked.reload.turf_score, "and its frozen multiplier is not re-priced"
  end

  test "a contest on a span slate is multi-week and labels its span" do
    span = Nfl::BuildSpanSlate.call(year: 2026, weeks: [1, 2, 3])
    contest = contests(:one)
    contest.update!(slate: span)

    assert contest.multi_week?
    assert_equal "Weeks 1-3", contest.week_span_label
    assert_equal 2, contest.pickable_matchups.size, "one pickable row per team"
  end

  test "a single-week contest is unchanged" do
    contest = contests(:one)
    contest.update!(slate: @w1)

    assert_not contest.multi_week?
    assert_equal "Week 1", contest.week_span_label
  end

  # --- mainnet lock-time guard -------------------------------------------
  #
  # A weekly NFL slate carries no game kickoff times, so a Turf Totals contest
  # built on it can't resolve a lock time. onchain_params would then fall back
  # to lock_timestamp: 0 — a contest that NEVER locks, minted on live mainnet.
  # #create must refuse BEFORE any on-chain instruction is built.
  test "create refuses a no-start weekly slate before any on-chain build" do
    # Admin phantom: past the require_admin + phantom_wallet? gates so the flow
    # reaches the lock-time guard rather than short-circuiting earlier.
    users(:alex).update!(web3_solana_address: "AdMiNPhantoM1111111111111111111111111111111")
    assert_nil @w1.starts_at
    assert_nil @w1.first_game_starts_at, "the weekly slate has no resolvable start"

    vault = FakeVault.new(usdc_balance: 100_000.0)

    assert_no_difference("Contest.count") do
      Solana::Vault.stub :new, vault do
        post contests_path,
          params: { contest: { name: "No Lock Cup", slug: "no-lock-cup",
                               slate_id: @w1.id, contest_type: "medium" } },
          as: :json
      end
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_match(/set a lock time/i, json["error"])
    # Load-bearing: the guard short-circuits BEFORE the vault builds anything —
    # no create_contest instruction, and no params_token to sign it with.
    assert_empty vault.create_contest_calls
    assert_nil json["params_token"], "no create token may be issued when the contest is refused"
  end
end
