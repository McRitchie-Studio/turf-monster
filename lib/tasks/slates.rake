namespace :slates do
  desc "Recompute stored turf scores from each slate's sport curve (ranks preserved)"
  task recompute_turf_scores: :environment do
    Slate.where.not(name: "Default").find_each do |slate|
      n = slate.slate_matchups.distinct.count(:team_slug)
      next if n.zero?

      # A two-line slate cannot be recomputed from its stored ranks: a rank
      # frozen under the old summed-total rule, scaled onto the two-game line,
      # overprices every bye team. Re-rank it with slates:reprice_span instead.
      if slate.two_line_pricing?
        puts "#{slate.slug || slate.name}: SKIPPED — a bye span prices on two lines; " \
             "use bin/rails \"slates:reprice_span[#{slate.slug}]\""
        next
      end

      updated = 0
      slate.slate_matchups.where.not(rank: nil).find_each do |matchup|
        matchup.update!(turf_score: SlateMatchup.turf_score_for(matchup.rank, n, sport: slate.sport))
        updated += 1
      end
      puts "#{slate.slug || slate.name}: #{updated} matchups recomputed (#{slate.sport}, n=#{n})"
    end
  end

  # Moves one span slate onto the current pricing rule (per-game rank, two
  # lines for bye teams). DRY RUN unless APPLY=1. A slate carrying paid picks
  # also needs REPRICE_PAID_PICKS=<the same slug> — naming the slate is the
  # operator's decision on record, not a flag to be carried over by habit.
  #
  #   bin/rails "slates:reprice_span[nfl-2026-weeks-7-9]"
  #   APPLY=1 bin/rails "slates:reprice_span[nfl-2026-weeks-7-9]"
  #   APPLY=1 REPRICE_PAID_PICKS=nfl-2026-weeks-4-6 bin/rails "slates:reprice_span[nfl-2026-weeks-4-6]"
  desc "Reprice a span slate onto the two-line bye rule (dry run unless APPLY=1)"
  task :reprice_span, [:slug] => :environment do |_task, args|
    slug = args[:slug].to_s
    abort "usage: bin/rails \"slates:reprice_span[<slate-slug>]\"" if slug.empty?

    slate = Slate.find_by(slug: slug) || abort("no slate with slug #{slug}")
    apply = ENV["APPLY"] == "1"
    result = Nfl::RepriceSpanSlate.call(
      slate: slate,
      apply: apply,
      reprice_paid_picks: ENV["REPRICE_PAID_PICKS"] == slate.slug
    )

    puts "#{slate.name} — #{apply ? 'APPLY' : 'DRY RUN'}"
    puts format("%-4s %-26s %5s %9s %11s %6s", "rank", "team", "games", "was", "now", "picks")
    result.changes.each do |change|
      picks = change.paid_picks.positive? ? "#{change.paid_picks} paid" : ""
      picks += " #{change.unpaid_picks} unpaid" if change.unpaid_picks.positive?
      puts format("%-4s %-26s %5s %9s %11s %s%s",
                  change.new_rank, change.team_slug, change.games,
                  "##{change.old_rank || '-'} #{change.old_turf_score || '-'}x",
                  "#{change.new_turf_score}x", picks.strip, change.changed? ? "" : "  (unchanged)")
    end
    puts "#{result.changed.size} of #{result.changes.size} teams change price; " \
         "#{result.paid_picks} paid pick#{'s' unless result.paid_picks == 1} on this slate"

    if result.refusal
      abort "REFUSED: #{result.refusal}"
    elsif result.applied
      puts "APPLIED."
    elsif apply
      puts "Nothing to write — every team already carries its two-line price."
    else
      puts "Dry run only. Re-run with APPLY=1 to write."
    end
  end
end
