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
  # What the focus card's rail lists beside the scores: the plays that changed
  # who has the ball, or kept it. Scores are not here — the rail reads those
  # from goals, which know what each was worth.
  scope :for_rail, -> { where(kind: "turnover").or(where(first_down: true)) }

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

  # ── THE PLAY SUMMARY under the focus card ────────────────────────────────
  #
  # Three things, each said once (Alex, 2026-10-05): WHAT the play was, in
  # bold — "Completion", "Interception", "Missed Field Goal"; the DETAIL under
  # it — "45 yard pass", "-2 yard rush"; and WHO, as up to three small
  # portraits. All read off what the feed already gave us.

  # The formation ESPN opens with — "(Shotgun)", "(No Huddle, Shotgun)", a
  # restated "(10:39)" — and the tacklers and coverage it closes with. All true,
  # none of it what happened.
  LEAD_IN   = /\A(?:\s*\([^)]*\))+\s*/
  TACKLERS  = /\s*\([^)]*\)\.?\s*\z/
  COVERAGE  = /\s*\[[^\]]*\]/
  # Where the play ends and its aftermath begins: the extra point after a
  # touchdown, a penalty tacked on. "St. Brown" is a name, not a full stop.
  AFTERMATH = /(?<!St)\.\s+(?=[A-Z][.A-Za-z])/
  SNAPPERS  = /,\s*Center-.*\z/
  # "J.Goff", "A.St. Brown", "T.McMillan": an initial, a dot, a surname.
  PLAYER    = /\b([A-Z])\.\s?((?:St\.\s?)?[A-Z][A-Za-z'\-]+)/

  # ESPN's play type -> the word a fan would use. First match wins, so the
  # specific cases sit above the general ones they contain.
  RESULTS = [
    # The try after a touchdown, made or missed — before "touchdown", which
    # some feeds repeat in its text.
    [/extra point|\bpat\b/i,                "Extra Point"],
    [/two-point|2pt/i,                     "Two-Point Try"],
    [/touchdown/i,                         "Touchdown"],
    [/safety/i,                            "Safety"],
    [/intercept/i,                         "Interception"],
    [/fumble recovery \(opponent\)/i,      "Fumble Recovered"],
    [/fumble/i,                            "Fumble"],
    [/blocked field goal/i,                "Blocked Field Goal"],
    [/blocked punt/i,                      "Blocked Punt"],
    [/field goal good/i,                   "Field Goal"],
    [/field goal/i,                        "Missed Field Goal"],
    [/incompletion|incomplete/i,           "Incompletion"],
    [/pass reception|completion/i,         "Completion"],
    [/sack/i,                              "Sack"],
    [/rush/i,                              "Rush"],
    [/punt/i,                              "Punt"],
    [/kickoff/i,                           "Kickoff"],
    [/penalty/i,                           "Penalty"],
    [/official timeout/i,                  "Official Timeout"],
    [/timeout/i,                           "Timeout"],
    [/two-minute warning/i,                "Two-Minute Warning"],
    [/end of half/i,                       "Halftime"],
    [/end (of )?(period|quarter)/i,        "End of Quarter"],
    [/end of (game|regulation)/i,          "End of Game"]
  ].freeze

  # What happened, in the feed's own words with the scaffolding taken off:
  # no formation, no coverage, no tacklers, and nothing after the play itself.
  def summary
    line = text.to_s.sub(LEAD_IN, "").gsub(COVERAGE, "")
    line = line.split(AFTERMATH, 2).first.to_s.sub(SNAPPERS, "")
    line = line.sub(TACKLERS, "") while line.match?(TACKLERS)
    line = line.squish.sub(/\.\z/, "")
    line.present? ? "#{line}." : text.to_s.squish.presence
  end

  # WHAT THE PLAY WAS. The type decides; the text is asked only when the type
  # is one we have not listed, and the kind's own label is the last resort.
  def result_label
    [play_type, text].each do |source|
      found = RESULTS.find { |pattern, _| source.to_s.match?(pattern) }
      return found.last if found
    end

    label || play_type.presence
  end

  # THE DETAIL: how far, or what for. nil when the result already says it all.
  def detail_label
    line = summary.to_s

    case result_label
    when "Completion"         then yards_phrase("pass")
    when "Rush"               then yards_phrase("rush")
    when "Sack"               then yards_phrase("sack")
    when "Touchdown"          then yards_phrase(line.match?(/\bpass\b/i) ? "pass" : (line.match?(/return/i) ? "return" : "rush"))
    when "Incompletion"       then line[/incomplete\s+((?:short|deep)\s+(?:left|middle|right))/i, 1]&.downcase&.then { |where| "#{where}" }
    when "Field Goal", "Missed Field Goal", "Blocked Field Goal"
      line[/(\d+)\s*yard field goal/i, 1]&.then { |yards| "#{yards} yards" }
    when "Punt"               then line[/punts\s+(-?\d+)\s*yards?/i, 1]&.then { |yards| "#{yards} yard punt" }
    when "Kickoff"            then line[/kicks\s+(-?\d+)\s*yards?/i, 1]&.then { |yards| "#{yards} yard kick" }
    when "Penalty"            then line[/PENALTY on [^,]+,\s*([^,]+,\s*\d+\s*yards?)/i, 1]
    when "Timeout"            then line[/\bby\s+([A-Z]{2,4})\b/, 1]&.then { |team| "by #{team}" }
    when "Interception", "Fumble Recovered", "Fumble"
      line[/for\s+(-?\d+)\s*yards?/i, 1]&.then { |yards| "#{yards} yard return" }
    end
  end

  # WHO, IN THE ORDER THEY MATTER — up to three names as the feed writes them.
  # The feed names the passer first; a fan looks at the catch. So on a pass the
  # TARGET leads and the passer follows, and on an interception the defender
  # who took it leads. Everything else keeps the feed's order.
  def players
    line = summary.to_s
    names = line.scan(PLAYER).map { |initial, surname| "#{initial}.#{surname}" }.uniq

    lead = line[/INTERCEPTED by\s+(#{PLAYER.source})/i, 1] ||
           line[/\bpass\b.*?\b(?:to|for)\s+(#{PLAYER.source})/i, 1] ||
           line[/RECOVERED by\s+(?:[A-Z]{2,4}-)?(#{PLAYER.source})/i, 1]
    lead = lead&.sub(/\.\s/, ".")&.then { |name| names.find { |known| known.delete(" ") == name.delete(" ") } }

    ([lead] + names).compact.uniq.first(3)
  end

  # Those names as roster athletes, in the same order, nil where we hold no
  # record. An initial and a surname is only a name inside a roster, so the
  # search is the two teams in this game and nobody else — and the play's own
  # team wins a tie, since most of a play's names are its offence.
  def athletes
    @athletes ||= begin
      sides = [team_slug, game&.home_team_slug, game&.away_team_slug].compact.uniq
      pool = players.any? && sides.any? ? Athlete.where(team_slug: sides).joins(:person).includes(:image_caches, :person) : nil

      players.map do |name|
        initial, surname = name.match(PLAYER).captures
        pool&.where("LOWER(people.last_name) = ? AND LOWER(people.first_name) LIKE ?",
                    surname.downcase, "#{initial.downcase}%")
            &.min_by { |athlete| sides.index(athlete.team_slug) }
      end
    end
  end

  private

  # "45 yard pass", "-2 yard rush", "no gain".
  def yards_phrase(noun)
    return nil if yards.nil?
    return "no gain" if yards.zero?

    "#{yards} yard #{noun}"
  end

  # ── WAITING FOR THE KICKOFF ──────────────────────────────────────────────
  #
  # After a touchdown or a field goal the next snap is a kickoff, and between
  # the two the feed fills the gap with an Official Timeout — the TV break. Shown
  # as "the latest play" that read as if the game had stopped for a reason,
  # when what the board should say is what everyone is waiting for (Alex,
  # 2026-10-05).
  #
  # Breaks that only fill time are looked past. Halftime and the end of the game
  # are not: they ARE what is happening, and the second half opens with its own
  # kickoff anyway.
  #
  # The try after a touchdown is looked past too, made or MISSED: either way the
  # next snap is still the kickoff.
  PASS_OVER = ["Official Timeout", "Timeout", "Two-Minute Warning", "End of Quarter",
               "Extra Point", "Two-Point Try"].freeze
  SCORES = ["Touchdown", "Field Goal", "Safety"].freeze

  # The score the next kickoff follows, or nil. `plays` is newest first.
  #
  # TWO MOMENTS, IN ORDER (Alex, 2026-10-05). While the score is itself the
  # newest play, the bar shows THE SCORE — "Touchdown, 12 yard rush" is the
  # news. Only once something fills the gap after it (the TV break, the try)
  # does the bar move on to what everyone is waiting for. And never for a game
  # that is over: a walk-off score has no kickoff coming.
  def self.awaiting_kickoff_after(plays, game: nil)
    return nil if game&.completed?

    plays.each_with_index do |play, index|
      next if PASS_OVER.include?(play.result_label)
      return nil unless play.kind == "score" || SCORES.include?(play.result_label)
      return nil if index.zero?

      return play
    end
    nil
  end

  # WHO SCORED, read off the score itself: each play carries the running score
  # after it, so the side whose total rose on this play is the side that
  # scored. That is right for a pick-six (the play is the offence's; the points
  # are not) and needs no goal to have been written yet. `plays` is newest
  # first and must include the play before the score. nil when the feed sent no
  # running score, and the caller falls back.
  def self.scoring_team_slug(score_play, plays:, game:)
    index = plays.index(score_play)
    before = index && plays[(index + 1)..].find { |play| !play.home_score.nil? && !play.away_score.nil? }
    return nil if score_play.home_score.nil? || score_play.away_score.nil?

    home_before = before&.home_score.to_i
    away_before = before&.away_score.to_i
    if score_play.home_score.to_i > home_before then game.home_team_slug
    elsif score_play.away_score.to_i > away_before then game.away_team_slug
    end
  end

  # WHO KICKS: the team that scored — except after a safety, where the team
  # that conceded it free-kicks. `scorer_slug` is the team the points went to
  # (see .scoring_team_slug).
  def self.kicking_team_slug(score_play, scorer_slug:, game:)
    return scorer_slug unless score_play.result_label == "Safety"

    ([game.home_team_slug, game.away_team_slug] - [scorer_slug]).first
  end
end
