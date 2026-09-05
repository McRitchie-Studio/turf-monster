module ContestsHelper
  # Whether the current viewer is allowed to see this entry's picks.
  # While the contest is open and not yet locked, picks are private to the
  # entry owner so network-tab readers can't preview competitors' selections.
  # Once the contest locks (v0.17: DERIVED — its lock time has passed) or
  # settles, picks are public. Admins on the `/contests/:slug/admin` URL
  # bypass the guard entirely.
  def picks_visible_for?(entry, contest = @contest)
    return true unless contest&.open?   # nil or settled → public
    return true if contest.locked?      # derived: lock time passed → public
    return true if @admin_view && current_user&.admin?
    return true if logged_in? && entry.user_id == current_user.id
    false
  end

  # Serialize entries for the JSON debug block while respecting the
  # picks-visibility rule above. When picks are hidden for the viewer,
  # the selections array is stripped from the entry's payload — every
  # other field is preserved so the block stays useful for debugging.
  # Per-week breakdown for one pick in a multi-week contest, e.g.
  # "W1 2 · W2 3 · W3 — · 5 goals × 2.4 = 12.0 pts".
  #
  # Shows GOALS per week, then the single span multiplier — mirroring how the
  # score is actually computed (total goals × one multiplier), so the tooltip
  # can't imply a per-week multiplier that doesn't exist. An unplayed week (or a
  # bye, which has no matchup at all) shows a dash rather than a zero, so
  # "hasn't happened yet" reads differently from "was shut out".
  #
  # `weeks`, `by_team`, and `multiplier` are hoisted by the caller so rendering a
  # full leaderboard stays a couple of queries rather than a couple per pick.
  def weekly_points_breakdown(selection, weeks:, by_team:, multiplier: nil)
    pool = by_team[selection.slate_matchup.team_slug] || []
    total = 0
    parts = weeks.map do |week|
      matchup = pool.find { |m| m.week == week }
      if matchup&.goals.present?
        total += matchup.goals
        "W#{week || '?'} #{matchup.goals}"
      else
        "W#{week || '?'} —"
      end
    end

    tail = "#{total} goals"
    tail += " × #{multiplier}" if multiplier.present?
    "#{parts.join(' · ')} · #{tail} = #{format('%.1f', selection.points.to_f)} pts"
  end

  def contest_debug_entries(entries, contest = @contest)
    entries.map do |entry|
      if picks_visible_for?(entry, contest)
        entry.as_json(include: { user: { only: [:id, :name] }, selections: {} })
      else
        entry.as_json(include: { user: { only: [:id, :name] } })
      end
    end
  end

  # ── Contest-chat composer prompts ─────────────────────────────────────
  # The sample messages the composer TYPES into its placeholder while the "Send
  # Your First Message" quest is live (contests/_chat_panel, driven by the quest
  # card's quest-chat-active event).
  #
  # SEMI-STATIC by design: two fixed openers, then one line built from this
  # viewer's own entry. The composer types the three in order and RESTS on the
  # last one, so the line left sitting in the placeholder is the personal one —
  # the reader's own longshot, named. Three is therefore the whole deck, not a
  # truncation: every line here is one the viewer actually sees.
  CHAT_PROMPT_LIMIT = 3

  CHAT_PROMPT_OPENERS = ["Hey everyone 👋", "Good luck, everyone ⚔️"].freeze

  # The personal line RESTS in the placeholder, so it is the one line that must
  # never render broken — and the composer is narrow. Measured in Chrome at the
  # 375px breakpoint (the mobile chat tab), the textarea's content box is 206px
  # against a 20px line-height in a 22px box: a longer line WRAPS and gets sliced
  # mid-glyph rather than ellipsised. It also overflows the md two-column box
  # (223px) and only clears at 1024px+.
  #
  # So the name carries a budget — and 10, not the 14 a single measurement first
  # suggested. THE CONTENT BOX IS NOT THE SAME WIDTH EVERYWHERE: 206px measured
  # in Chrome on macOS, but 183px on the Linux CI runner, whose classic scrollbar
  # takes real width where macOS overlay scrollbars take none. A budget tuned to
  # the roomier box shipped a line that overflowed on the narrower one — CI caught
  # "United States light it up ✈️" at 187.0px in a 183.0px box. 10 is the widest
  # REAL name that clears the narrow box with margin ("Commanders", "Buccaneers",
  # "Uzbekistan"); the 11-13 character names are all countries with clean
  # three-letter short_names ("United States" -> "USA"), which read well here.
  # Above that lies "Bosnia and Herzegovina" (22) and the World Cup bracket
  # placeholders ("Runner-up Match 101"), which read badly in this sentence
  # anyway. Over budget falls back to short_name, then to the generic line.
  #
  # The character count is only a PROXY. The fact is the pixel measurement in
  # e2e/quest_chat_prompts.spec.js, which measures wherever it runs — that is
  # what found the environment difference, and it is what must stay authoritative
  # if this number is ever raised again.
  CHAT_PROMPT_NAME_BUDGET = 10

  # Where the personal line goes when no team can be resolved (a contest with no
  # slate — World Cup Survivor — or a slate with no priced matchups). Keeps the
  # deck three lines long and still ends on an invitation to type.
  CHAT_PROMPT_NO_TEAM = "Who's everyone riding?".freeze

  # `entries` is passed in where the page already loaded them with selections
  # preloaded (@my_active_entries on contests#show). Nil falls back to one
  # scoped query — contests#live has no such ivar, and the caller only asks
  # when the viewer can actually post.
  def chat_prompt_samples(contest, user, entries: nil)
    return [] if contest.blank? || user.blank?

    CHAT_PROMPT_OPENERS + [chat_prompt_longshot(contest, user, entries)]
  end

  private

  # "Chargers light it up ⚡" — the viewer's LONGEST-PRICED pick.
  #
  # turf_score is the frozen per-team multiplier, and the curve pins rank 1 at
  # x1.0 and climbs from there (SlateMatchup.turf_score_for), so the highest one
  # is the viewer's biggest swing — the pick worth talking about. A viewer with
  # no picks yet gets the contest's own longest price instead, which is still a
  # real, checkable claim about this contest.
  def chat_prompt_longshot(contest, user, entries)
    matchup = chat_prompt_priciest(chat_prompt_matchups(contest, user, entries))
    matchup ||= chat_prompt_priciest(contest.slate ? contest.pickable_matchups : [])
    team = matchup&.team
    name = chat_prompt_name_for(team)
    return CHAT_PROMPT_NO_TEAM if name.blank?

    emoji = team.emoji.presence || contest.slate&.sport_emoji || contest.sport_emoji
    "#{name} light it up #{emoji}"
  end

  # The name this line can afford: the mascot when it fits the budget, else the
  # team's short_name, else nothing (the caller falls back to the generic line).
  # short_name is an abbreviation — "BIH", "USA" — so it is always well inside.
  def chat_prompt_name_for(team)
    return nil if team.blank?

    [team.mascot, team.short_name]
      .compact_blank
      .find { |name| name.length <= CHAT_PROMPT_NAME_BUDGET }
  end

  # This viewer's picked matchups. Reads the preloaded entries when the caller
  # has them; otherwise one query with the same includes contests#show uses, so
  # this can never N+1 per selection.
  def chat_prompt_matchups(contest, user, entries)
    entries ||= user.entries
                    .where(contest: contest, status: [:active, :complete])
                    .includes(selections: { slate_matchup: :team })
                    .to_a

    entries.flat_map { |entry| entry.selections.map(&:slate_matchup) }.compact
  end

  # Highest multiplier wins; an unpriced matchup (turf_score still nil, before
  # the slate is ranked) can never win, so `to_f`'s zero is the right floor.
  def chat_prompt_priciest(matchups)
    matchups.select { |m| m.turf_score.present? }.max_by { |m| m.turf_score.to_f }
  end

  # What the live board should CALL itself, given the contest's state.
  #
  # The page renders in every state now (a link an operator has should work),
  # but its header said "Live" with a pulsing red dot unconditionally — so a
  # contest that had not kicked off, and one that had already paid out, both
  # announced themselves as in progress. The badge is the first thing read on
  # that page; a badge that is wrong is worse than no badge.
  #
  # THE STATE SPACE IS NOT AN ENUM, AND IT IS NOT THREE AXES EITHER. Two fixes
  # have now been made here by enumerating the axes their author knew about and
  # missing the next one. So enumerate them all, and say which pairings cannot
  # occur — a branch that silently assumes a state is unreachable is how both
  # earlier bugs survived review.
  #
  # FIVE PREDICATES ARE READ ABOUT A CONTEST. Only FOUR of them are free:
  #
  #   status      enum, pending/open/settled           (contest.rb:44)
  #   cancelled?  onchain_cancelled, a boolean column  (contest.rb:498)
  #   locked?     settled? || now >= starts_in_at      (contest.rb:586)
  #   concluded?  settled? || now >= concludes_at      (contest.rb:594)
  #   live?       locked? && !settled?                 (contest.rb:602)
  #
  # `live?` IS NOT AN AXIS. It is a derived reading of two others, and it carries
  # NO conclusion term — which is the whole of this bug: a contest that has
  # concluded but not been graded still satisfies `locked? && !settled?`, so it
  # answered `live?` true and the badge pulsed "Live" at results that were final.
  # The previous round of this same bug was the same shape with `cancelled?`.
  #
  # WHAT IS REACHABLE (settled forces both derived flags true, so it is listed
  # once; `pending`/`open` behave alike here — neither is read directly):
  #
  #   status         cancelled?  locked?  concluded?   label
  #   ---------------------------------------------------------------
  #   pending/open   no          no       no           Not started
  #   pending/open   no          yes      no           Live
  #   pending/open   no          yes      yes          Concluded  <- read "Live"
  #   pending/open   no          no       yes          Concluded  <- read "Not started"
  #   pending/open   yes         any      any          Cancelled
  #   settled        no          (forced) (forced)     Final
  #   settled        yes         (forced) (forced)     Cancelled
  #
  # WHAT IS NOT REACHABLE, and why — do not add a branch for these:
  #
  #   settled + !locked?     `locked?` returns true unconditionally when
  #                          `settled?` (contest.rb:587). No clock value changes it.
  #   settled + !concluded?  Same shape: `concluded?` returns true unconditionally
  #                          when `settled?` (contest.rb:595) — even with
  #                          `concludes_at` nil or in the FUTURE. Pinned by
  #                          test/models/contest_locking_test.rb:84.
  #   live? + settled?       Excluded by `live?`'s own definition.
  #   live? + !locked?       Excluded by `live?`'s own definition.
  #
  # The fourth row — concluded but NOT locked — looks contradictory and is not.
  # On chain, `set_contest_conclusion_time` requires a conclusion later than the
  # lock ONLY when a lock is set (`lock != 0`,
  # programs/turf_vault/src/instructions/set_contest_conclusion_time.rs:71-74).
  # The chain sees `starts_in_at` ONCE, at create: it is mirrored into
  # `lock_timestamp` (contest.rb:526) and passed to create_contest
  # (contest.rb:265). Nothing re-reads it afterwards, and no validation couples
  # `concludes_at` to it — confirm_conclusion_time writes `concludes_at` ALONE
  # (contests_controller.rb:1404). So the PAIR is unconstrained after create: a
  # contest made with no slate schedule (lock 0, conclusion then unconstrained)
  # that is later given one, or one whose first game is POSTPONED past a
  # conclusion that has already passed, lands concluded-and-not-locked — and
  # before this fix it read "Not started" at a contest whose results were final.
  # It cannot be created that way outright: a conclusion must be in the FUTURE
  # when set (same file, :70), so it reaches the past only by elapsed time.
  #
  # PRECEDENCE: cancelled, then final, then concluded, then live, then upcoming.
  #
  #   cancelled first  — terminal whatever else is true, and it is the fact that
  #                      changes what the viewer should do next.
  #   final next       — a settled contest is ALSO concluded and ALSO locked by
  #                      definition (above), so anything checked before `final`
  #                      would swallow every settled contest.
  #   concluded next   — this is the fix. `live?` has no conclusion term, so a
  #                      concluded, ungraded contest reaches `live` unless
  #                      `concluded?` is asked first.
  #   live, upcoming   — what is left once the terminal and final-results states
  #                      are spoken for.
  #
  # Do NOT read "Cancelled" as "refunded": cancel_contest returns the prize pool
  # to the CREATOR (Solana::Vault#build_cancel_contest), entry fees stay operator
  # revenue, and entrant compensation is a manual mint_entry_token playbook.
  # Terms promise a refund only for a contest cancelled BEFORE it locks, which is
  # not the case this branch exists for. An entrant reading "Cancelled" may still
  # be owed money — which is the reason the badge must not read "Live" at them.
  #
  # "Concluded" makes a NARROWER claim than "Final", and the difference is load
  # bearing. It says the games are over and the result will not change; it does
  # NOT say the contest is graded or that anyone has been paid.
  #
  # Do not upgrade that into "concluded always comes before final". It does not:
  # `settle_contest` requires that the lock OR the conclusion has passed
  # (turf_vault/src/instructions/settle_contest.rs:103-106), so a contest with a
  # passed lock can be settled having never concluded. Concluding is one of two
  # ways to open the settle gate, not a stage every contest passes through.
  # "Concluded" therefore means "waiting on the payout", never "paid", and never
  # "the step before Final".
  #
  # THE BADGE NO LONGER TRACKS `live?`, AND MUST NOT BE MADE TO AGAIN. It was
  # documented as carrying "the same predicate the broadcast filters on", so
  # that it told you whether an update could arrive. That is what produced the
  # bug: cancel-while-locked is deliberately supported, `live?` is
  # `locked? && !settled?`, and Contest::LiveBroadcast selects `status: [:open]`
  # then `.select(&:live?)` — neither filter excludes a cancelled contest. So a
  # cancelled, locked contest IS still in the broadcast set while this badge
  # reads "Cancelled". That divergence is deliberate: the badge is a claim about
  # what the contest IS, not about whether packets are still being pushed at the
  # games strip below it.
  #
  # MOTION IS RESERVED FOR `live`. The pulsing dot is the one animated element
  # here, and it means exactly one thing: this contest is in progress. Every
  # terminal, finished, or not-yet state is static, so "is it moving?" stays a
  # reliable read at a glance. Cancelled keeps the app's cancelled red (it
  # matches CONTEST_BADGE_STYLES["cancelled"]) but takes a solid dot, never a
  # pulse. Concluded takes the app's conclusion ORANGE — the same tone the
  # header countdown lands on when it finishes ("🏁 Concluded", tone "orange" in
  # contests/_timestamp_countdown.html.erb) — so the two places that report a
  # conclusion agree on colour, and neither can be mistaken for live's red.
  #
  # Contrast, measured on the rendered page rather than computed from the
  # palette (rasterised pixel vs the actual `bg-page`, sanity-checked against
  # white-on-black = 21:1): text-orange-400 is 7.34:1 on the dark theme and
  # 2.27:1 on the light one. The dark figure BEATS the text-red-400 that live
  # and cancelled already use (6.05:1); the light figure trails it (2.76:1).
  # Light mode is below AA for every state in this row, orange included — that
  # is a pre-existing property of the row, not something the concluded state
  # introduced, and fixing it means re-toning live and cancelled too. If you do
  # that, note text-orange-500 measures EXACTLY at red-400's parity in both
  # themes (6.05 / 2.76) and is the drop-in; it was passed over here only
  # because 400 is the house label shade (label-400 over dot-500) and is the
  # tone the countdown above already lands on.
  #
  # This badge is server-rendered at page load. Contest::LiveBroadcast replaces
  # the games strip and the focus panel, not this header, so a contest whose
  # state changes under a viewer keeps the label it was drawn with until a
  # reload. Out of scope here; do not read these labels as self-correcting.
  # Every utility below is written as a FULL LITERAL. Tailwind scans this file
  # (config/tailwind.config.js content includes ./app/helpers/**/*.rb) but it
  # only ever matches whole class names — a class assembled by interpolation
  # compiles to no rule at all and the dot renders transparent.
  LIVE_STATES = {
    cancelled: { label: "Cancelled", classes: "text-red-400", dot: "bg-red-500" },
    live: { label: "Live", classes: "text-red-400", dot: "bg-red-500 animate-pulse" },
    concluded: { label: "Concluded", classes: "text-orange-400", dot: "bg-orange-500" },
    final: { label: "Final", classes: "text-muted", dot: "bg-slate-500" },
    upcoming: { label: "Not started", classes: "text-muted", dot: "bg-slate-500" }
  }.freeze

  # Order is the precedence rule documented above. Each guard is checked before
  # any predicate it definitionally implies, so no later branch can swallow an
  # earlier state.
  def contest_live_state(contest)
    return :cancelled if contest.cancelled?
    return :final if contest.settled?
    return :concluded if contest.concluded?
    return :live if contest.live?

    :upcoming
  end

  def contest_live_badge(contest)
    LIVE_STATES.fetch(contest_live_state(contest))
  end
end
