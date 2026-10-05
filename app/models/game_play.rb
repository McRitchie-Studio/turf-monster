# One play of one game, as ESPN reported it: a snap, a penalty, a timeout, the
# two-minute warning. The play-by-play feed on the contest live board.
#
# NOT A SCORE. Goal is the scoring event and the only thing a contest is paid
# on; a touchdown appears here too, as the line that says how it happened, and
# deleting every row in this table would change nobody's points.
class GamePlay < ApplicationRecord
  KINDS = Nfl::Espn::Plays::KINDS

  # What the feed prints in front of a play that is not an ordinary snap.
  KIND_LABELS = {
    "score"    => "Score",
    "turnover" => "Turnover",
    "penalty"  => "Flag",
    "timeout"  => "Timeout",
    "break"    => "Break",
    "sack"     => "Sack"
  }.freeze

  # How much of a game the board renders. A game runs to about 190 plays; the
  # feed is for what is happening now, and the last few drives are that.
  FEED_LIMIT = 40

  belongs_to :game, foreign_key: :game_slug, primary_key: :slug
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true

  validates :external_id, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  scope :newest_first, -> { order(sequence: :desc) }

  # ESPN's play id is the game's event id with a counter on the end
  # ("401872978" + "4422"), so the counter alone orders a game's plays. A play
  # whose id does not start with the event id keeps the whole number, which
  # still sorts — just not against plays that do.
  def self.sequence_for(external_id, event_id)
    id = external_id.to_s
    id = id.delete_prefix(event_id.to_s) if event_id.present? && id.start_with?(event_id.to_s)
    id.to_i
  end

  def label = KIND_LABELS[kind]

  # "Q4 · 3:42". The quarter reads the way the focus card already writes it.
  def clock_label
    quarter =
      if period.to_i.between?(1, 4) then "Q#{period}"
      elsif period.to_i > 4         then "OT"
      end

    [quarter, clock.presence].compact.join(" · ").presence
  end
end
