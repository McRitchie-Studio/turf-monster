require "test_helper"

class EntryTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @m1 = slate_matchups(:m1)
    @m2 = slate_matchups(:m2)
    @m3 = slate_matchups(:m3)
    @m4 = slate_matchups(:m4)
    @m5 = slate_matchups(:m5)
    @m6 = slate_matchups(:m6)
  end

  test "confirm! activates a paid entry given payment proof" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "paid-tx-sig")

    assert entry.active?
  end

  test "confirm! rejects a paid entry with no payment proof" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/payment required/i, error.message)
    assert entry.reload.cart?
  end

  test "confirm! activates a comped entry without payment" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
  end

  test "confirm! scores the entry immediately against already-decided games" do
    # Regression: an entry confirmed onto a slate whose games are ALREADY
    # completed/scored must be scored at confirm time. Entry scoring is otherwise
    # purely reactive (Goal events / grade!), so without this the entry sits at 0
    # forever — the prod bug where live-contest leaderboards showed all 0.0.
    matchups = [@m1, @m2, @m3, @m4, @m5, @m6]
    matchups.each_with_index { |m, i| m.update!(goals: i + 1) } # goals 1..6
    expected = matchups.sum { |m| m.goals * m.turf_score }
    assert expected > 0, "fixture sanity: expected a positive projected score"

    entry = @contest.entries.create!(user: @user, status: :cart)
    matchups.each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
    assert_in_delta expected, entry.reload.score, 0.001
  end

  test "confirm! leaves score at 0 when no games are decided yet" do
    matchups = [@m1, @m2, @m3, @m4, @m5, @m6]
    matchups.each { |m| m.update!(goals: nil) }

    entry = @contest.entries.create!(user: @user, status: :cart)
    matchups.each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
    assert_equal 0, entry.reload.score
  end

  test "confirm! rejects with less than 6 selections" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/selections required/, error.message)
    assert entry.reload.cart?
  end

  test "confirm! accepts every matchup on a short knockout slate" do
    contest, matchups = create_short_slate_contest
    entry = contest.entries.create!(user: @user, status: :cart)
    matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }

    entry.confirm!(tx_signature: "short-knockout-paid")

    assert entry.active?
    assert_equal 2, entry.selections.count
  end

  test "confirm! rejects partial picks on a short knockout slate" do
    contest, matchups = create_short_slate_contest
    entry = contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: matchups.first)

    error = assert_raises(RuntimeError) { entry.confirm!(tx_signature: "short-knockout-paid") }

    assert_match(/Exactly 2 selections required/, error.message)
    assert entry.reload.cart?
  end

  test "confirm! rejects for non-open contest" do
    @contest.update!(status: "settled")
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_equal "Contest is not open", error.message
  end

  test "confirm! accepts tx_signature parameter" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "fake_tx_sig_123")

    assert entry.active?
    assert_equal "fake_tx_sig_123", entry.onchain_tx_signature
  end

  test "confirm! leaves onchain fields nil for an off-chain contest" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
    assert_nil entry.onchain_tx_signature
    assert_nil entry.onchain_entry_id
  end

  test "confirm! stores onchain_entry_id" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(tx_signature: "tx_123", onchain_entry_id: "pda_addr_456")

    assert entry.active?
    assert_equal "tx_123", entry.onchain_tx_signature
    assert_equal "pda_addr_456", entry.onchain_entry_id
  end

  test "confirm_onchain! rejects a paid entry with a blank signature (fail-closed gate)" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm_onchain!(tx_signature: "", entry_pda: "pda") }
    assert_match(/payment required/i, error.message)
    assert entry.reload.cart?
  end

  test "confirm_onchain! cannot reuse a signature already credited to another entry (replay guard)" do
    first = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| first.selections.create!(slate_matchup: m) }
    first.confirm_onchain!(tx_signature: "dup-sig-1", entry_pda: "pda-1")
    assert first.active?

    other = users(:jordan)
    second = @contest.entries.create!(user: other, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| second.selections.create!(slate_matchup: m) }

    # Same finalized signature must not credit a second row.
    assert_raises(ActiveRecord::RecordInvalid) do
      second.confirm_onchain!(tx_signature: "dup-sig-1", entry_pda: "pda-2")
    end
    assert second.reload.cart?, "replayed signature must not activate a second entry"
  end

  # --- toggle_selection! tests ---

  test "toggle_selection! creates a new selection" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    selections_hash = entry.toggle_selection!(@m1)

    assert_equal({ @m1.id.to_s => true }, selections_hash)
    assert_equal 1, entry.selections.count
  end

  test "toggle_selection! removes selection when toggled again" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: @m1)

    result = entry.toggle_selection!(@m1)

    assert_nil result
    assert_not Entry.exists?(entry.id)
  end

  test "confirm! rejects duplicate selection combo (sybil check)" do
    # First entry
    entry1 = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry1.selections.create!(slate_matchup: m) }
    entry1.confirm!(comped: true)

    # Second entry with same combo
    entry2 = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry2.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry2.confirm! }
    assert_match(/already have an entry/, error.message)
  end

  # --- slug test ---

  test "slug includes id after creation" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.reload
    assert_includes entry.slug, entry.id.to_s
  end

  test "to_param returns slug" do
    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.reload
    assert_equal entry.slug, entry.to_param
  end

  test "confirm! rejects when a game has already started" do
    # Link m1 to a past game (kickoff in the past = locked)
    @m1.update!(game_slug: "past-game")

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/already started/, error.message)
    assert entry.reload.cart?
  end

  test "confirm! rejects when contest lock time has passed (H7)" do
    # Contest is still :open but starts_at is in the past — exactly the
    # staggered-kickoff information-edge attack the H7 audit caught.
    @contest.update!(starts_at: 1.hour.ago)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm!(tx_signature: "paid-tx-sig") }
    assert_match(/locked/i, error.message)
    assert entry.reload.cart?
  end

  test "confirm! allows comped entries past lock time (admin fill exemption)" do
    # Contest#fill! seeds entries via comped: true and may run after lock.
    @contest.update!(starts_at: 1.hour.ago)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    entry.confirm!(comped: true)

    assert entry.active?
  end

  test "confirm_onchain! rejects when contest lock time has passed (H7)" do
    @contest.update!(starts_at: 1.hour.ago)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm_onchain!(tx_signature: "tx", entry_pda: "pda") }
    assert_match(/locked/i, error.message)
    assert entry.reload.cart?
  end

  test "confirm! rejects when user has reached per-contest entry limit" do
    # Create 3 confirmed entries with different combos
    # We only have 6 matchups, so we need different combos — use subsets
    # Actually with 6 matchups and picks_required=6, all combos are the same.
    # So we need more matchups. Let's mock the limit directly.
    # Create entries that are already active to fill the limit.
    3.times do |i|
      entry = @contest.entries.create!(user: @user, status: :active)
    end

    # Try to confirm a 4th entry
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    error = assert_raises(RuntimeError) { entry.confirm! }
    assert_match(/Maximum 3 entries per contest/, error.message)
  end

  # --- update_picks! tests ---

  test "update_picks! replaces selections atomically" do
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])

    # Swap m6 → m1 stays; new combo uses m1..m5 + m6 same? Use a different swap:
    # add a new matchup, remove m6. We only have 6 fixtures, so swap by
    # replacing the order — the model treats the set as the source of truth,
    # not order. Force a real change by swapping m6 with a fresh matchup.
    m7 = create_extra_matchup(team_short: "G", slug: "team-g", rank: 7, turf_score: 1.8)

    entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, m7.id])

    new_ids = entry.reload.selections.map(&:slate_matchup_id).sort
    assert_equal [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, m7.id].sort, new_ids
  end

  test "update_picks! rejects when contest is not open" do
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])
    @contest.update!(status: "settled")

    error = assert_raises(RuntimeError) { entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id]) }
    assert_equal "Contest is not open", error.message
  end

  test "update_picks! rejects when count is not picks_required" do
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])

    error = assert_raises(RuntimeError) { entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id]) }
    assert_match(/selections required/i, error.message)
    # Selections unchanged
    assert_equal 6, entry.reload.selections.count
  end

  test "update_picks! uses the short knockout slate pick count" do
    contest, matchups = create_short_slate_contest
    entry = contest.entries.create!(user: @user, status: :active)
    matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }

    error = assert_raises(RuntimeError) { entry.update_picks!([matchups.first.id]) }

    assert_match(/Exactly 2 selections required/, error.message)
    assert_equal 2, entry.reload.selections.count
  end

  test "update_picks! rejects when adding a locked matchup" do
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])

    # Create a new matchup tied to past-game (locked)
    locked_m = create_extra_matchup(team_short: "H", slug: "team-h", rank: 7, turf_score: 1.8, game_slug: "past-game")

    error = assert_raises(RuntimeError) {
      entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, locked_m.id])
    }
    assert_match(/already started/, error.message)
    # Original selections preserved
    assert_equal 6, entry.reload.selections.count
    assert_equal [@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id].sort,
                 entry.selections.map(&:slate_matchup_id).sort
  end

  test "update_picks! rejects when removing a locked matchup" do
    # Build entry where one pick (m6) is now tied to a past game
    @m6.update!(game_slug: "past-game")
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])

    # Need another non-locked matchup to swap in
    m7 = create_extra_matchup(team_short: "G", slug: "team-g", rank: 7, turf_score: 1.8)

    # Removing locked m6 should fail
    error = assert_raises(RuntimeError) {
      entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, m7.id])
    }
    assert_match(/already started/, error.message)
    assert_equal 6, entry.reload.selections.count
  end

  test "update_picks! allows unchanged locked picks (only validates the diff)" do
    # Same scenario — m6 is locked — but the user submits exactly the same
    # six picks (a no-op edit). Should pass because the diff is empty.
    @m6.update!(game_slug: "past-game")
    entry = build_active_entry([@m1, @m2, @m3, @m4, @m5, @m6])

    entry.update_picks!([@m1.id, @m2.id, @m3.id, @m4.id, @m5.id, @m6.id])

    assert_equal 6, entry.reload.selections.count
  end

  test "update_picks! refuses an entry on a retired-format contest" do
    retired = Contest.create!(name: "Retired", slate: @contest.slate, contest_type: "standard",
                              entry_fee_cents: 1900, max_entries: 59, status: :open, starts_at: 2.weeks.from_now,
                              slug: "test-retired")
    entry = retired.entries.create!(user: @user, status: :active)
    write_retired_format!(retired)

    error = assert_raises(RuntimeError) { entry.update_picks!([]) }
    assert_match(/not supported/i, error.message)
  end

  private

  # Build an :active entry with the given matchups already selected, bypassing
  # confirm!'s payment gates (we're testing update_picks! mechanics, not entry).
  def build_active_entry(matchups)
    entry = @contest.entries.create!(user: @user, status: :active)
    matchups.each { |m| entry.selections.create!(slate_matchup: m) }
    entry
  end

  # SlateMatchup#team_slug must be unique per slate, and the fixtures use
  # team-a..team-f across the six matchups. Spin up a fresh Team + matchup
  # so update_picks! tests can swap a real new pick in. Team includes
  # Sluggable, whose before_save overwrites slug from name_slug — so the
  # name has to parameterize to the slug we want.
  def create_extra_matchup(team_short:, slug:, rank:, turf_score:, game_slug: nil)
    name = slug.tr("-", " ").split.map(&:capitalize).join(" ")  # "team-g" -> "Team G"
    team = Team.find_by(slug: slug) || Team.create!(name: name, short_name: team_short, emoji: "\u{1F3F3}")
    SlateMatchup.create!(
      slate: @contest.slate,
      team_slug: team.slug,
      opponent_team_slug: "team-a",
      rank: rank,
      turf_score: turf_score,
      status: "pending",
      game_slug: game_slug
    )
  end

  def create_short_slate_contest
    slate = Slate.create!(
      name: "Short Knockout Slate #{SecureRandom.hex(3)}",
      starts_at: 2.days.from_now
    )
    matchups = [
      SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: "team-b", rank: 1, turf_score: 1.0, status: "pending"),
      SlateMatchup.create!(slate: slate, team_slug: "team-b", opponent_team_slug: "team-a", rank: 2, turf_score: 1.2, status: "pending")
    ]
    contest = Contest.create!(
      name: "Short Knockout Contest #{SecureRandom.hex(3)}",
      slug: "short-knockout-contest-#{SecureRandom.hex(4)}",
      slate: slate,
      contest_type: "standard",
      entry_fee_cents: 19_00,
      max_entries: 29,
      status: :open,
      starts_at: 2.days.from_now
    )
    [contest, matchups]
  end

end
