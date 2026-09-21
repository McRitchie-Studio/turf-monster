namespace :studio do
  # The pre-season / pre-event roster refresh.
  #
  #   bin/rails studio:sync_athletes          # delta — seconds when little moved
  #   bin/rails studio:sync_athletes FULL=1   # rebuild from a nil watermark
  #
  # There is no separate "full" mode to get wrong: a nil watermark IS the full
  # rebuild, and FULL=1 only clears the stored one.
  desc "Pull the athlete projection from McRitchie Studio into this app's replica"
  task sync_athletes: :environment do
    full = ENV["FULL"].present?
    puts "studio:sync_athletes — #{full ? 'FULL rebuild' : 'delta'}"

    result = Studio::SyncAthletes.new(full: full).call
    cursor = SyncCursor.for(Studio::SyncAthletes::SOURCE)

    puts "  status:  #{result.status}"
    puts "  pages:   #{result.pages}"
    puts "  seen:    #{result.rows_seen}"
    puts "  written: #{result.rows_written}"
    puts "  cursor:  #{cursor.watermark_updated_at&.iso8601 || 'none'} (id #{cursor.watermark_id || '-'})"

    # NEVER QUIET. Each of these is a person the master and the replica disagree
    # about, and the replica deliberately refused to write rather than overwrite
    # a different human who shares the slug. Only the master can resolve it —
    # give the operator both league ids so they can.
    if result.collided?
      warn "  COLLISIONS: #{result.collisions.length} row(s) REFUSED — not written, nothing overwritten"
      result.collisions.each do |c|
        warn "    #{c[:person_slug]}: we hold gsis #{c[:ours]}, the master sent #{c[:theirs]}"
      end
      warn "    → resolve in McRitchie Studio (give one of them a disambiguated person), then re-run."
    end
    puts "  detail:  #{cursor.detail}" if cursor.detail.present?

    # Exit non-zero ONLY on a real failure. A skip (no secret) is a legitimate
    # state on a stack that does not sync, and must not redden a deploy.
    abort "studio:sync_athletes FAILED — see cursor detail above" if result.status == "failed"
  end

  desc "Show where the athlete sync got to"
  task sync_status: :environment do
    cursor = SyncCursor.find_by(source: Studio::SyncAthletes::SOURCE)
    if cursor.nil?
      puts "studio_athletes: never run"
      next
    end

    puts "studio_athletes"
    puts "  last run:   #{cursor.last_run_at&.iso8601 || 'never'} (#{cursor.last_status || '-'})"
    puts "  watermark:  #{cursor.watermark_updated_at&.iso8601 || 'none'} (id #{cursor.watermark_id || '-'})"
    puts "  last seen:  #{cursor.rows_seen} rows, #{cursor.rows_written} written"
    puts "  detail:     #{cursor.detail}" if cursor.detail.present?
    puts "  replica:    #{Athlete.synced.count} synced of #{Athlete.count} athletes"
  end
end
