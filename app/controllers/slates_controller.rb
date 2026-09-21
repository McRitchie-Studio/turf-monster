class SlatesController < ApplicationController
  before_action :require_admin
  before_action :set_slate, only: [:show, :update_rankings, :update_turf_scores, :update_formula]

  def index
    real_slates = Slate.where.not(name: "Default")
    slate = real_slates.where("starts_at >= ?", Time.current).order(starts_at: :asc).first ||
            real_slates.order(starts_at: :desc, created_at: :desc).first
    return redirect_to root_path, alert: "No slates found" unless slate
    redirect_to slate_path(slate)
  end

  def formula_report
    # Samples come from the most recent SOCCER slate whose matchups carry the
    # seeded DK odds (Soccer::CacheTeamTotalOdds). Only rows with BOTH the
    # line and the over odds join the sample — the report computes implied
    # probability and v1/v2/v3 from them, and a partial row (every NFL
    # matchup: line, no odds) is what 500'd this page before.
    @slate = Slate.order(starts_at: :desc, created_at: :desc)
                  .detect { |s| s.sport == "fifa" && s.slate_matchups.where.not(team_total_over_odds: nil).exists? }

    matchups = @slate&.slate_matchups&.includes(:team) || []

    @sample_matchups = matchups.filter_map do |m|
      next unless m.expected_score && m.team_total_over_odds

      odds = m.team_total_over_odds
      line = m.expected_score.to_f
      prob = if odds < 0
        odds.abs.to_f / (odds.abs + 100)
      else
        100.0 / (odds + 100)
      end

      {
        team: m.team.name,
        emoji: m.team.emoji,
        line: line,
        over_odds: odds,
        over_dec: nil,
        prob: prob,
        v1: (line + (prob - 0.5)).round(2),
        v2: (line + (prob - 0.5) * 3).round(2),
        v3: SlateMatchup.dk_score_for(line, odds)
      }
    end
  end

  # NFL analog of the formula report, on its own tab. nil (empty state) when
  # the historical dataset is missing (ArgumentError), corrupt
  # (JSON::ParserError), or malformed (KeyError from the fetch reads).
  def nfl_report
    @nfl_distribution = begin
      Nfl::PointsDistribution.call
    rescue ArgumentError, JSON::ParserError, KeyError
      nil
    end
  end

  def show
    @slates = Slate.selector_ordered
    @matchups = @slate.slate_matchups.ranked.includes(:team, :opponent_team, :game)
    # The page ranks TEAMS, not matchup rows: a team's standing is its summed
    # expected points across every game it plays in this slate. A one-week slate
    # yields one row per team exactly as before; a "Weeks 1-3" slate yields 32
    # rows rather than 96.
    @team_rows = @slate.team_rows
  end

  def update_rankings
    rescue_and_log(target: @slate) do
      if params[:matchup_ids].present?
        # The dragged rows are TEAMS. Each posted id identifies a team via one of
        # its matchups, and the rank it lands on is written to EVERY game that
        # team plays in this slate — otherwise a multi-week team would be priced
        # by whichever of its three rows happened to be the handle.
        n = params[:matchup_ids].size
        # A bye team keeps its two-game line through a hand re-rank — a drag
        # moves its RANK, never which line it prices on (Slate "Two lines").
        factors = @slate.game_factors
        params[:matchup_ids].each_with_index do |id, index|
          matchup = @slate.slate_matchups.find_by(id: id)
          next unless matchup

          rank = index + 1
          turf_score = SlateMatchup.turf_score_for(rank, n, sport: @slate.sport,
                                                            game_factor: factors.fetch(matchup.team_slug, 1.0))
          @slate.slate_matchups.where(team_slug: matchup.team_slug).find_each do |team_matchup|
            team_matchup.update!(rank: rank, turf_score: turf_score)
          end
        end
      end
      redirect_to slate_path(@slate), notice: "Rankings saved! Multipliers recalculated."
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  # Manual multiplier override — the one endpoint that writes a price nobody
  # computed. It used to be a single unguarded line:
  #
  #   update_all(turf_score: entry[:turf_score].to_f.round(1))
  #
  # `.to_f` never refuses: an empty cell, an unpriced row's "—" and a leading-x
  # "x2.5" all arrive as 0.0, while "2.5x" arrives TRUNCATED to 2.5 (measured —
  # see SlateMatchup.parse_turf_score). `update_all` skips validations by
  # construction, so the guard has to live HERE, at the write. `turf_score` is
  # the column Selection#compute_points! settles from, frozen at pick time and
  # paid on-chain: a zero pays nothing.
  #
  # The band is a deliberate OVERRIDE band, wider than the slate's resolved
  # curve — the widest price this slate's own board can display. The reasoning,
  # and what it deliberately still lets through, is on SlateMatchup.price_band.
  def update_turf_scores
    rescue_and_log(target: @slate) do
      writes, refusals = planned_turf_scores

      if refusals.any?
        redirect_to slate_path(@slate), alert: refusal_alert(refusals)
      else
        ActiveRecord::Base.transaction do
          writes.each do |team_slug, price|
            # Same as update_rankings: the edited row is a TEAM, so the multiplier
            # applies to every game that team plays here.
            @slate.slate_matchups.where(team_slug: team_slug).update_all(turf_score: price)
          end
        end
        redirect_to slate_path(@slate), notice: "Turf Scores saved!"
      end
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  def update_formula
    rescue_and_log(target: @slate) do
      @slate.update!(formula_params)
      redirect_to slate_path(@slate), notice: "Formula saved!"
    end
  rescue StandardError => e
    redirect_to @slate ? slate_path(@slate) : root_path, alert: e.message
  end

  def admin_formula
    @default_slate = Slate.default_record
    unless @default_slate
      @default_slate = Slate.create!(name: "Default")
    end
  end

  def update_admin_formula
    @default_slate = Slate.default_record
    return redirect_to root_path, alert: "Default slate not found" unless @default_slate

    rescue_and_log(target: @default_slate) do
      @default_slate.update!(formula_params)
      redirect_to admin_formula_slates_path, notice: "Default formula saved!"
    end
  rescue StandardError => e
    redirect_to admin_formula_slates_path, alert: e.message
  end

  private

  # Reads EVERY posted row before anything is written, and returns
  # [{ team_slug => price }, ["why this row was refused", ...]].
  #
  # Validate-then-write, and one bad row refuses the WHOLE batch. The board
  # posts all 32 rows in one form, so writing the readable ones and dropping the
  # rest would leave the slate in a state the admin never typed — half the board
  # re-priced, half not, under a "Turf Scores saved!" flash. That is worse than
  # the typo. (House rule: validate before irreversible side effects.)
  #
  # Each refusal names the TEAM and what it saw, because the admin's next move is
  # to go find that row.
  def planned_turf_scores
    entries = params[:turf_scores]
    return [{}, []] if entries.blank?

    band = @slate.admin_price_band
    writes = {}
    refusals = []

    entries.each do |entry|
      matchup = @slate.slate_matchups.find_by(id: entry[:id])
      next unless matchup

      posted = entry[:turf_score]
      price = SlateMatchup.parse_turf_score(posted)
      # Resolved LAZILY. `matchup.team` is an association load per row, and the
      # happy path never needs the name — so eager-reading it cost 32 queries on
      # every SUCCESSFUL save of a full NFL board, for a string that was thrown
      # away. A refusal is the rare case; pay for it there.
      name = -> { matchup.team&.name || matchup.team_slug }

      if price.nil?
        seen = posted.to_s.strip.presence&.inspect || "a blank cell"
        refusals << "#{name.call}: #{seen} is not a number."
      elsif !band.cover?(price)
        refusals << "#{name.call}: #{price_label(price)} is outside " \
                    "#{price_label(band.first)}-#{price_label(band.last)} for this slate."
      else
        writes[matchup.team_slug] = price
      end
    end

    [writes, refusals]
  end

  def price_label(value)
    format("x%.1f", value)
  end

  # The flash rides the SESSION COOKIE, and a cookie is capped at 4096 bytes.
  # ActionDispatch raises CookieOverflow past it — from MIDDLEWARE, after the
  # action has already returned, so the `rescue StandardError` on
  # #update_turf_scores cannot catch it. The operator gets a bare HTTP 500
  # instead of being told which price was refused, which is acceptance criterion
  # 3 of this task failing on a slate shape that exists in production.
  #
  # It is not hypothetical and it is not all-or-nothing. Measured here against
  # the seeded rosters, every row refused:
  #
  #   the real 48-team World Cup slate, band label "x1.0-x3.0"  -> 2,511 bytes
  #   the 32-team NFL roster, band label "x1.0-x11.0"           -> 1,994 bytes
  #
  # THE BAND LABEL IS PART OF THE MEASUREMENT, and naming it is not pedantry:
  # every refusal sentence carries the label, so one extra character in it is
  # +48 bytes on a 48-team board. Two people measuring "the 48-team case" this
  # week got 2,511 and 2,559 for exactly that reason, and an earlier revision of
  # this comment printed 2,532 — a real run of the first 48 soccer teams
  # ALPHABETICALLY, which is not a slate. The figure is not the argument; it
  # only has to be a large fraction of 4,096 for the rest of the session to
  # decide the outcome.
  #
  # Neither exceeds 4,096 on its own, and that is exactly what made this latent:
  # the alert is only PART of the session, so whether it overflows depends on how
  # full that admin's session already is. Shannon drove the 48-team case through a
  # real browser session on a desk stack and got the raise — HTTP 500,
  # "cookie overflowed with size 4144 bytes" — while the same payload on a session
  # holding nothing but a login did not. Some operators, not others.
  #
  # The list is therefore bounded TWICE, and the two bounds answer different
  # questions. PREVIEW answers "how much can a person read in a four-second
  # toast" — 48 near-identical sentences is not a message, it is a wall.
  # MAX_BYTES answers "can this overflow the cookie" WITHOUT a claim about how
  # long a team name is: the names come from seed data this controller does not
  # own, so a count alone bounds the sentences, not the bytes.
  REFUSAL_PREVIEW = 3
  REFUSAL_MAX_BYTES = 400

  def refusal_alert(refusals)
    shown = refusals.first(REFUSAL_PREVIEW)
    hidden = refusals.size - shown.size
    tail = hidden.positive? ? " and #{hidden} more." : ""

    body = shown.join(" ")
    budget = [REFUSAL_MAX_BYTES - tail.bytesize, 0].max
    # byteslice, not [0, n] — the latter counts CHARACTERS, and a multi-byte
    # team name would slip past a byte budget measured in characters. It can cut
    # mid-codepoint, so .scrub repairs the tail; an invalid-encoding string is
    # not merely ugly, it raises on the next regex that touches it.
    body = "#{body.byteslice(0, budget).scrub}…" if body.bytesize > budget

    "No multipliers saved. #{body}#{tail}"
  end

  def set_slate
    @slate = Slate.find_by(slug: params[:id])
    return redirect_to root_path, alert: "Slate not found" unless @slate
  end

  def formula_params
    params.permit(*Slate::FORMULA_COLUMNS)
  end
end
