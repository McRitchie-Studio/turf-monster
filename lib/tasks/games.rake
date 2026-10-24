namespace :games do
  # Fills `games.week` on NFL rows written before every writer set it.
  # See Games::BackfillWeek for the sources and their precedence.
  #
  #   bin/rails games:backfill_week            # dry run: reports, writes nothing
  #   bin/rails games:backfill_week APPLY=1    # writes
  #
  # Declared as the games-week-backfill task's post_deploy_cmd (with APPLY=1), so
  # bin/release runs it on QA at prepare and on production at ship. Idempotent:
  # a second run finds no null-week NFL game to fill.
  desc "Fill games.week (and a null season slot) from slate matchups, else ESPN; dry run unless APPLY=1"
  task backfill_week: :environment do
    apply = ENV["APPLY"] == "1"
    result = Games::BackfillWeek.call(apply: apply)

    mode = apply ? "APPLY" : "DRY RUN (set APPLY=1 to write)"
    verb = apply ? "filled" : "would fill"
    puts "games:backfill_week — #{mode}"
    puts "  NFL games with week NULL: #{result.candidates}"
    puts "  #{verb}: #{result.changes.size} (#{result.by_source.map { |source, n| "#{source} #{n}" }.join(', ').presence || 'none'})"
    result.by_week.each { |week, count| puts "    week #{week}: #{count}" }
    puts "  unresolved (left NULL): #{result.unresolved.size}"
    result.unresolved.each { |row| puts "    #{row.slug}: #{row.reason}" }
    if result.failed.any?
      puts "  FAILED to write: #{result.failed.size}"
      result.failed.each { |row| puts "    #{row.slug}: #{row.reason}" }
    end

    # A failed write is a real failure and must redden the post-deploy hook,
    # whose green proves only exit 0. An unresolved row is a report, not a
    # failure: it is printed by slug for an operator to read.
    abort "games:backfill_week: #{result.failed.size} write(s) failed" if result.failed.any?
  end
end
