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
      warn "    → each refusal is also filed durably at /admin/error_logs " \
           "(class #{Studio::SyncAthletes::CollisionRefused})."
    end
    puts "  detail:  #{cursor.detail}" if cursor.detail.present?

    # EXIT NON-ZERO ONLY ON A REAL FAILURE — which is `failed`, and only that.
    #
    # A skip (no secret) is a legitimate state on a stack that does not sync.
    #
    # A COLLIDED RUN ALSO EXITS ZERO, and that is a decision, not an oversight.
    # A refusal is the guard working as designed, and the condition is STICKY:
    # the master keeps sending the same row, so every subsequent run refuses it
    # again identically (measured — three consecutive runs, same two refusals).
    # The replica cannot resolve it; only the master can. So a non-zero exit
    # would not be a signal that something new happened, it would be a
    # permanently red cadence until a human edits another system — and a
    # permanently red cadence is one people stop reading. This repo has already
    # deleted a cron for exactly that kind of noise (the solana_reconcile note
    # in config/schedule.yml), which loses the cadence along with the signal.
    #
    # Nothing schedules this task yet, so what replaces the exit code has to be
    # durable rather than incidental: the cursor records `ok_with_collisions`
    # plus who was refused, and every refusal gets its own /admin/error_logs
    # row. LOUD AND ZERO, not silent, and not red forever.
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

    # THE WHOLE POINT OF THIS TASK. The first production run refused two rows
    # and this task reported it as "(ok)", because the cursor could not hold
    # any other answer. It can now, so say so in words rather than leaving the
    # reader to notice a suffix on the status line.
    if cursor.last_status == "ok_with_collisions"
      puts "  REFUSED:    the last run refused rows — nothing was overwritten."
      puts "              resolve in McRitchie Studio, then re-run; the refusal repeats until you do."
      puts "              durable copies: /admin/error_logs (class #{Studio::SyncAthletes::CollisionRefused})"
    end
    puts "  replica:    #{Athlete.synced.count} synced of #{Athlete.count} athletes"
  end
end
