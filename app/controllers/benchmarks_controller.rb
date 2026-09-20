# The public Turf Score benchmarks page at /benchmarks.
#
# Public and read-only, like /live: a player who wants to know why a team costs
# 1.5x should not have to sign in to find out. It shows the market numbers a
# slate was priced from (DraftKings via ESPN — see Nfl::Espn::MarketLines), each
# team's expected points PER GAME, and the rank and multiplier those earn,
# including which line a bye team rides (Slate "Two lines").
#
# It reads STORED prices (Slate#team_rows), the same column settlement
# multiplies by — so this page can never show a number the board would not pay.
class BenchmarksController < ApplicationController
  skip_before_action :require_authentication

  def index
    @slates = Slate.selector_ordered.select(&:week_range)
    @slate = params[:slug].present? ? Slate.find_by(slug: params[:slug]) : default_slate
    return redirect_to(root_path, alert: "Slate not found") if @slate.nil?

    @team_rows = @slate.team_rows
    # EVERY snapshot behind this slate's weeks, newest first — a span is pulled
    # week by week, so one week's row counts are not the span's.
    @snapshots = snapshots_for(@slate)
    @snapshot = @snapshots.first
  end

  private

  # The span a player is most likely asking about: the next one to kick off,
  # falling back to the most recent (the season's last span, once they have all
  # started) and then to any slate at all, so the page never renders empty.
  def default_slate
    spans = @slates.select { |slate| slate.week_range.size > 1 }
    upcoming = spans.select { |slate| slate.first_game_starts_at&.future? }
    upcoming.min_by(&:first_game_starts_at) ||
      spans.max_by { |slate| slate.first_game_starts_at || Time.at(0) } ||
      @slates.first
  end

  # What the slate's prices were derived from. Each projection points at the run
  # that WROTE it, so selecting through the projections yields the live
  # snapshots — never a superseded run that merely happens to be newer.
  def snapshots_for(slate)
    weeks = slate.week_range&.to_a || [slate.week]
    projections = NflTeamTotalProjection.where(year: slate.season_year, week: weeks)
                                        .where.not(market_snapshot_id: nil)
    MarketSnapshot.where(id: projections.select(:market_snapshot_id)).recent_first.to_a
  end
end
