module Live
  # WHAT THE FOCUS CARD'S RAIL LISTS: the moments that changed a drive — a score,
  # a turnover, a first down — newest first.
  #
  # It used to list scores alone, and in a 13-10 game that is five lines in
  # three hours. First downs and turnovers are what a drive is made of, so the
  # rail now moves about as often as the ball does.
  #
  # TWO TABLES, ONE ORDER. Scores come from goals, because a Goal knows what the
  # play was WORTH (ESPN folds the extra point into the touchdown, so only the
  # goal says +7); first downs and turnovers come from GamePlay. Both carry
  # ESPN's play id when the feed wrote them, and that id orders them against
  # each other exactly. A goal recorded by hand (the admin console, the dev
  # toolbar) has no id, so it is placed after the last play that existed when
  # it was written — which is where it happened.
  class RailFeed
    Item = Data.define(:kind, :team_slug, :label, :points, :order)

    # A game has roughly forty first downs. The rail is for what is happening
    # now; this is a couple of drives deep and the rest scrolls off.
    LIMIT = 20

    TURNOVER_LABELS = [
      [/intercept/i, "Interception"],
      [/fumble/i,    "Fumble"],
      [/downs/i,     "Turnover on Downs"]
    ].freeze

    def self.for(game) = new(game).items

    def initialize(game)
      @game = game
    end

    def items
      (scores + plays.map { |play| item_for(play) })
        .sort_by(&:order).reverse.first(LIMIT)
    end

    private

    # A scheduled game has no plays, and this runs once per game in the week.
    def plays
      @plays ||= @game.status == "scheduled" ? [] : @game.plays.for_rail.newest_first.limit(LIMIT).to_a
    end

    def scores
      @game.goals.map do |goal|
        Item.new(kind: "score", team_slug: goal.team_slug, label: goal.scoring_label.presence || "Score",
                 points: goal.points, order: order_for(goal))
      end
    end

    def item_for(play)
      if play.kind == "turnover"
        # The team that TOOK the ball, not the one that lost it: the row leads
        # with a team's mark, and a mark beside "Interception" reads as theirs.
        Item.new(kind: "turnover", team_slug: other_side(play.team_slug), label: turnover_label(play),
                 points: nil, order: [play.sequence, 0, 0])
      else
        Item.new(kind: "first_down", team_slug: play.team_slug, label: "First Down",
                 points: nil, order: [play.sequence, 0, 0])
      end
    end

    def turnover_label(play)
      text = "#{play.play_type} #{play.text}"
      TURNOVER_LABELS.find { |pattern, _| text.match?(pattern) }&.last || "Turnover"
    end

    def other_side(team_slug)
      return nil if team_slug.blank?

      ([@game.home_team_slug, @game.away_team_slug] - [team_slug]).first
    end

    # [sequence, 1, id]: after a play with the same sequence (the touchdown's own
    # line), and in id order among goals that share one.
    def order_for(goal)
      id = goal.external_id.to_s
      if @game.external_id.present? && id.start_with?(@game.external_id.to_s)
        return [GamePlay.sequence_for(id, @game.external_id), 1, goal.id.to_i]
      end

      before = plays.select { |play| goal.created_at && play.created_at <= goal.created_at }.map(&:sequence).max
      [before.to_i, 1, goal.id.to_i]
    end
  end
end
