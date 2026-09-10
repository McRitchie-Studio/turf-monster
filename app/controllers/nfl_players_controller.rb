# Public browse surface for the seeded NFL player database.
#
# The active league is ~2,900 players, which is far too many to render as one
# client-filtered grid — so the filtering that decides WHICH players render is
# done in SQL, and the search box only narrows what is already on the page.
# With no filter the index shows a 32-team picker, which doubles as navigation
# and keeps the default page cheap.
class NflPlayersController < ApplicationController
  skip_before_action :require_authentication

  def index
    @team = Team.find_by(slug: params[:team]) if params[:team].present?
    @position = PositionConcern.normalize_position(params[:position]) if params[:position].present?

    @athletes =
      if @team
        roster_for(@team)
      elsif @position
        league_wide_at(@position)
      end

    # Nothing selected — render the team picker instead of 2,900 cards.
    @teams = Team.where(league: "nfl").order(:name) if @athletes.nil?

    # Chips offer only the positions present in what the visitor is looking at.
    # A team page must not advertise a position its roster lacks: every such chip
    # is a link the page itself rendered straight into an empty grid.
    pool = @team ? Athlete.football.for_team(@team.slug) : Athlete.football
    @positions = PositionConcern::ORDERED_POSITIONS & pool.distinct.pluck(:position).compact
  end

  def show
    @athlete = Athlete.includes(:person, :team, :image_caches).find_by(person_slug: params[:slug])
    return redirect_to nfl_players_path, alert: "Player not found" unless @athlete

    @team = @athlete.team
    @teammates = @team ? roster_for(@team).where.not(id: @athlete.id).limit(6) : Athlete.none
  end

  private

  def roster_for(team)
    scope = Athlete.football.for_team(team.slug)
    scope = scope.for_position(@position) if @position
    scope.includes(:person, :team, :image_caches).in_roster_order
  end

  def league_wide_at(position)
    Athlete.football.on_a_team.for_position(position)
           .includes(:person, :team, :image_caches).in_roster_order
  end
end
