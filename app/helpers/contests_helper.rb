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
  # So the name carries a budget. 14 characters is where the real corpus splits:
  # the longest genuine team name is "United States" (13), while everything above
  # is a World Cup bracket placeholder ("Winner Match 102", "Runner-up Match 101")
  # or "Bosnia and Herzegovina" (22) — all of which read badly in this sentence
  # anyway. Over budget falls back to the team's short_name ("BIH"), then to the
  # generic line. Pinned by a MEASURED check at 375px in
  # e2e/quest_chat_prompts.spec.js — the character count is a proxy, the pixel
  # measurement is the fact.
  CHAT_PROMPT_NAME_BUDGET = 14

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
end
