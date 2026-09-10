module Admin
  module Nfl
    # THE OPERATOR'S FOCUS ORDER (/admin/nfl/weeks).
    #
    # /live decides which game to lead with by a ladder (Live::FocusGame) that
    # narrows the week down to the games actually eligible at that moment —
    # being played, or about to be. Inside that set the clock has nothing left
    # to say: nine games kick off at one o'clock and only a person knows which
    # one is THE game. This is where that person says so.
    #
    # ONE LIST, SEEDED CHRONOLOGICALLY. The week is a single drag-ordered
    # column whose position IS the rank, and it opens in kickoff order — which
    # is precisely what the ladder already does with no ranks at all. So the
    # untouched board is a picture of the current behaviour rather than an
    # empty form, and dragging is the only way to disagree with it.
    #
    # It also removes two whole failure modes the earlier two-column form had:
    # an ordering cannot use the same rank twice, and a list that always covers
    # the entire week cannot leave a gap when something is pulled out of it.
    #
    # EVERY CONSTANT REACHED THROUGH `::`. This module is `Admin::Nfl`, so a
    # bare `Game` or `Nfl::LiveScores` here resolves against Admin::Nfl first
    # and blows up on a name that does exist one scope out.
    class WeeksController < ApplicationController
      # The board's single column.
      FOCUS_ZONE = "focus".freeze

      before_action :require_admin
      before_action :load_slot, only: [:show, :reorder]

      # One row per season slot we hold games for, most recent first, with the
      # slot the live board is CURRENTLY showing called out — that is the week
      # an operator opening this page on a Sunday means.
      def index
        @slots = slot_rows
        @current_slot = ::Nfl::LiveScores::CurrentSlot.call
      end

      def show
        @games = slot_games.in_focus_order.includes(:home_team, :away_team).to_a
        # What the order currently DOES, computed by the same service /live
        # calls. A priority list whose effect you have to visit another page to
        # see is a priority list nobody trusts.
        @focus_now = ::Live::FocusGame.pick(@games)
      end

      # POST — the list's new order, which IS the ranking: the top game is 1.
      #
      # The board has one column covering the whole week, so every reorder
      # carries every game. A payload that does not is a payload from a stale
      # page, and writing it would rank part of the week and silently blank the
      # rest — so it is refused rather than half-applied.
      def reorder
        slugs = Array(params[:slugs]).map(&:to_s)
        week = slot_games.pluck(:slug)

        # SIZE **AND** SET. Comparing only the unique sets would let a payload
        # carrying the same game twice through — and the writer below would
        # then leave position 1 unused and rank that game second.
        unless slugs.size == week.size && slugs.uniq.sort == week.sort
          return render json: { error: "That order does not match this week's games — reload and try again." },
                        status: :unprocessable_entity
        end

        write_order!(slugs)
        render json: { ok: true, ranks: slugs.each_with_index.to_h { |slug, i| [slug, i + 1] } }
      end

      private

      # ONE TRANSACTION THAT CLEARS FIRST. Ranks are unique per week in the
      # database, so writing a new order one row at a time walks through states
      # the index refuses — two games trading 1 and 2 collide on the first
      # write. Clearing the slot inside the transaction means the index only
      # ever sees the finished arrangement.
      def write_order!(slugs)
        ::Game.transaction do
          slot_games.where.not(focus_rank: nil).update_all(focus_rank: nil)
          slugs.each_with_index do |slug, index|
            ::Game.where(slug: slug).update_all(focus_rank: index + 1)
          end
        end
      end

      def load_slot
        @slot = parse_slot(params[:id])
        if @slot
          @label = slot_label(@slot)
          return
        end

        respond_to do |format|
          format.json { render json: { error: "Unknown week." }, status: :not_found }
          format.any  { redirect_to admin_nfl_weeks_path, alert: "Unknown week “#{params[:id]}”." }
        end
      end

      def slot_games
        ::Game.nfl.in_season_slot(**@slot)
      end

      # "2026-2-12" -> { year: 2026, season_type: 2, week: 12 }. Anything that
      # is not three integers naming a season type we know is not a week.
      def parse_slot(id)
        year, season_type, week = id.to_s.split("-", 3).map { |part| Integer(part, exception: false) }
        return nil unless year && season_type && week
        return nil unless ::Game::SEASON_TYPES.key?(season_type)

        { year: year, season_type: season_type, week: week }
      end

      def slot_rows
        ::Game.nfl.where.not(season_year: nil).where.not(week: nil)
              .group(:season_year, :season_type, :week)
              .order(Arel.sql("season_year DESC, season_type DESC, week DESC"))
              .pluck(Arel.sql("season_year, season_type, week, COUNT(*), COUNT(focus_rank), MAX(kickoff_at)"))
              .map do |year, season_type, week, games, ranked, last_kickoff|
                slot = { year: year, season_type: season_type, week: week }
                { slot: slot, id: slot_id(slot), label: slot_label(slot), games: games,
                  # A week is either in the order someone dragged it into, or in
                  # the kickoff order it seeds with. Nothing in between: a
                  # reorder writes the whole list.
                  custom_order: ranked.positive?, last_kickoff: last_kickoff }
              end
      end

      def slot_id(slot)
        [slot[:year], slot[:season_type], slot[:week]].join("-")
      end

      def slot_label(slot)
        type = ::Game::SEASON_TYPES[slot[:season_type]]
        prefix = type == "regular" ? "" : "#{type.to_s.titleize} · "
        "#{slot[:year]} NFL · #{prefix}Week #{slot[:week]}"
      end
    end
  end
end
