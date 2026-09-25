require "net/http"
require "json"

module Studio
  # Pulls the person/athlete projection from McRitchie Studio into this app's
  # REPLICA.
  #
  # MS masters every durable fact about a person, a team or a place; this app
  # masters everything that happened at a time. Two one-way flows — this is the
  # MS → TM half; PushGameRecap is the other.
  #
  # PULL, NEVER PUSH, and never in a request path. A runtime dependency on MS
  # would make MS's availability part of THIS app's correctness, and this app
  # settles contests people paid to enter. A stale player name is survivable; a
  # 500 on a contest page is not.
  class SyncAthletes
    SOURCE = "studio_athletes".freeze
    DEFAULT_BASE_URL = "https://mcritchie.studio".freeze
    PAGE = 200
    MAX_PAGES = 100          # 20,000 rows — a stop, not a limit we expect to reach
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20

    class Error < StandardError; end

    # The FACET a refused row files itself under in /admin/error_logs. It is
    # never raised — a refusal is this sync's POLICY, not an escaped exception —
    # but `Admin::ErrorLogsHelper.error_class_from_inspect` reads the class name
    # out of the `inspect` column, so refusals need a real class name to group
    # under. Naming it here keeps that string from being invented at the write
    # site, where a typo would silently scatter the facet into "Unknown".
    CollisionRefused = Class.new(StandardError)

    Result = Struct.new(:rows_seen, :rows_written, :pages, :status, :collisions, keyword_init: true) do
      # A row the replica REFUSED rather than wrote. Never empty silently: the
      # rake task prints every one, because each is a human the master and the
      # replica disagree about and only the master can resolve.
      def collisions = self[:collisions] || []
      def collided? = collisions.any?
    end

    def self.configured? = ENV["AGENT_API_SECRET"].present?

    def initialize(base_url: nil, secret: nil, full: false)
      @base_url = (base_url || ENV["STUDIO_API_BASE"].presence || DEFAULT_BASE_URL).chomp("/")
      @secret = secret || ENV["AGENT_API_SECRET"]
      @full = full
    end

    # Returns a Result and NEVER raises out of this method. It runs from a
    # cadence and never in a request path, and a raise there is noise somebody
    # eventually learns to ignore.
    #
    # THE THREE NON-CLEAN OUTCOMES ARE NOT INTERCHANGEABLE, and an earlier
    # version of this comment called an unreachable provider a "skip". It is
    # not, and the difference is an exit code:
    #   - SKIPPED is the no-secret path below, and ONLY that path. A stack that
    #     does not sync is a legitimate state, so the rake task exits ZERO —
    #     its own comment reads "A skip (no secret)", singular.
    #   - FAILED is a provider that could not be read. SocketError,
    #     Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    #     Timeout::Error, OpenSSL::SSL::SSLError, any non-2xx and an
    #     unparseable body all raise `Error` from `request`, are rescued below,
    #     and record `failed` — on which `studio:sync_athletes` ABORTS
    #     NON-ZERO. An outage is late data, but it is not a skip.
    #   - OK_WITH_COLLISIONS is a run that COMPLETED and refused rows. It exits
    #     zero on purpose; `record_refusal` says why.
    def call
      cursor = SyncCursor.for(SOURCE)
      return skip(cursor, "AGENT_API_SECRET not set") unless self.class.configured?

      token = authenticate
      @collisions = []
      seen = written = pages = 0
      since, after_id = start_from(cursor)

      MAX_PAGES.times do
        page = fetch(token, since, after_id)
        rows = page["data"] || []
        break if rows.empty?

        pages += 1
        seen += rows.length
        written += rows.count { |row| upsert(row) }

        meta = page["meta"] || {}
        since = meta["next_updated_since"]
        after_id = meta["next_after_id"]
        # Cumulative, not per-page: `@collisions` accumulates across pages, so
        # a refusal on page 1 still colours the cursor after a clean page 2
        # overwrites it. The cursor is written per page so a partial run
        # resumes, which means the LAST write is the one that survives.
        cursor.advance!(updated_at: since, id: after_id, rows_seen: seen, rows_written: written,
                        status: run_status, detail: collision_detail)
        break unless meta["more"]
      end

      Result.new(rows_seen: seen, rows_written: written, pages: pages,
                 status: run_status, collisions: @collisions)
    # StandardError, not just Error. A narrow rescue let any ActiveRecord
    # exception escape `call` entirely, so `record_failure!` never ran and the
    # cursor kept `last_status: "ok"` after a crashed run — a sync that died
    # looked like a sync that found nothing, which is the worst of both. The
    # message is redacted to its class for anything we did not raise ourselves:
    # a foreign exception may quote its input, and this string lands in a
    # durable column.
    rescue Error => e
      cursor&.record_failure!(e.message)
      Result.new(rows_seen: 0, rows_written: 0, pages: 0, status: "failed")
    rescue StandardError => e
      cursor&.record_failure!(e.class.to_s)
      Result.new(rows_seen: 0, rows_written: 0, pages: 0, status: "failed")
    end

    private

    def skip(cursor, reason)
      cursor.record_skip!(reason)
      Result.new(rows_seen: 0, rows_written: 0, pages: 0, status: "skipped")
    end

    # A nil watermark IS the full rebuild, so `--full` only has to clear it.
    def start_from(cursor)
      return [nil, nil] if @full

      [cursor.watermark_updated_at&.iso8601(6), cursor.watermark_id]
    end

    # THE UPSERT KEYS ON gsis_id, never on slug and never on name. A slug
    # changes the moment a namesake forces a disambiguator onto it, and names
    # collide — six namesake groups in the 2026 feed. Keyed on either of those,
    # a rename would fork one player into two rows.
    #
    # Returns true when something actually changed, so "nothing to do" is
    # distinguishable from "did not run".
    def upsert(row)
      gsis_id = row["gsis_id"].to_s.strip
      return false if gsis_id.empty?

      athlete = Athlete.find_by(gsis_id: gsis_id) || build_for(row)
      return false if athlete.nil?

      athlete.syncing = true
      athlete.assign_attributes(attributes_from(row))

      # DATA changed, not provenance touched. `synced_at` is stamped on every
      # pass by definition, so reading `changed?` after it would make every row
      # look written and the cursor's rows_written would never be able to say
      # "the feed had nothing new".
      data_changed = athlete.changed? || athlete.new_record?

      athlete.synced_at = Time.current
      athlete.source_updated_at = row["updated_at"]
      athlete.save!
      data_changed
    end

    # WHICH ATHLETE ROW THIS BELONGS TO — and when the answer is "somebody
    # else's", refusing rather than adopting.
    #
    # The lookup in `upsert` keys on gsis_id and is correct. This is the CREATE
    # fallback, reached when the master sends a person we hold under a different
    # league id. Adopting blindly here overwrote a DIFFERENT HUMAN who happens to
    # share the slug: measured on production data, MS's `00-0028946` (Aaron
    # Brewer) took over our `00-0036171`, and MS's `chris-smith` `00-0038602`
    # took over our `00-0038661` — a man the master holds NO row for, so a full
    # rebuild could not have restored him. Nothing raised: there are zero unique
    # collisions across the two tables, so the bad write simply succeeded, and
    # the Person row is untouched so the page still showed the right name.
    #
    # The replica cannot fix this itself. It cannot overwrite (that is the bug),
    # it cannot make a twin (`person_slug` is unique on athletes), and it must
    # not invent a disambiguated slug, because SLUGS ARE THE MASTER'S. So it
    # refuses, records who collided with whom, and the sweep reports it.
    #
    # THREE WRITERS REACH THESE TABLES, and all three now carry this predicate:
    # the hub's `Nflverse::SeedPlayers#resolve_athlete!` (the master), this
    # replica sync, and THIS app's own local importer of the same name. Each was
    # guarded in a separate pass, because guarding one is what made the next one
    # findable.
    #
    # They diverge only on what to do once a namesake is detected, and the
    # difference is the lane, not the taste:
    #   - a SYNC handles one row the master already named, so it must not invent
    #     a slug — SLUGS ARE THE MASTER'S — and refuses, recording who collided.
    #   - an IMPORTER reads a third-party CSV the master never sent, so there is
    #     no master slug to contradict; it mints a disambiguated one, and refuses
    #     only when it cannot derive a free slug at all.
    def build_for(row)
      person = upsert_person(row)
      return nil if person.nil?

      existing = Athlete.find_by(person_slug: person.slug)
      return Athlete.new(person_slug: person.slug, sport: row["sport"].presence || "football") if existing.nil?

      held = existing.gsis_id.to_s.strip
      incoming = row["gsis_id"].to_s.strip

      # An athlete with NO league id is an unidentified local row for this name —
      # a seed, or a hand-entered one. Adopting it is the point of the sync.
      return existing if held.empty? || held == incoming

      collision = { person_slug: person.slug, ours: held, theirs: incoming }
      (@collisions ||= []) << collision
      record_refusal(collision, existing)
      nil
    end

    # THE DURABLE HALF of refuse-and-record. Until this existed, a refusal
    # reached the operator only as stdout from whoever happened to be watching:
    # the first production run (2026-09-24) refused two rows and
    # `studio:sync_status` reported that same run as "(ok)". The cursor now
    # carries a one-line summary, but it is overwritten by the next run — an
    # ErrorLog row per refusal is what is still answerable a week later, and
    # `Admin::ErrorLogsController` already browses that table, so this
    # introduces no new home.
    #
    # NOT `rescue_and_log`. That helper is a CONTROLLER concern and it RE-RAISES
    # (studio-engine app/controllers/concerns/studio/error_handling.rb), so
    # reaching for it inside this loop would abandon every remaining row of the
    # feed at the first refusal — the exact truncation the reporting exists to
    # prevent. A refused row is this sync's policy, not an exception that
    # escaped.
    #
    # NOT `ErrorLog.capture!` either, though it IS this repo's ordinary way in
    # (16 service files write ErrorLog; most use `capture!`). Two measured
    # reasons. It fans out to SENTRY whenever a DSN is set (the
    # `defined?(::Sentry)` branch in studio-engine app/models/error_log.rb), and
    # Sentry is the PAGING layer — a refusal is this guard working exactly as
    # designed, and the condition is STICKY (the master keeps sending the same
    # row, so every run refuses it again), which would page on a schedule
    # forever for something no retry can fix. And `capture!` takes an exception
    # and nothing else, so it cannot carry `target`, which is what makes the row
    # point at the athlete we kept. THIS APP'S OWN `Nflverse::SeedPlayers`
    # importer resolved it identically, in `#record_refusal` — same shape, same
    # `update_column` slug line, same swallow. Not the hub's class of the same
    # name: the MASTER has no `record_refusal` at all. It holds refusals in
    # memory and reports them to stderr (`refuse!` / `report_refusals`), and its
    # only `ErrorLog` write is one run-level `capture!` of the whole import — so
    # a reader sent there would draw the OPPOSITE lesson. Two classes share this
    # name across the two repos; the comment above on `build_for` keeps them
    # straight, and this one did not.
    #
    # `slug` is backfilled because `Admin::ErrorLogsController#show` looks rows
    # up BY slug (`ErrorLog.find_by!(slug: params[:slug])`) and `ErrorLog#to_param`
    # returns it — a row without one is written but UNREACHABLE in the only UI
    # that reads it, which would make a recorded refusal invisible to the person
    # meant to find it. The `update_column` is a deliberate copy of `capture!`'s
    # own slug line: the price of stepping outside the convention is that if the
    # engine ever changes that scheme, this is a site that must follow by hand.
    def record_refusal(collision, existing)
      log = ErrorLog.create!(
        message: "studio sync refused #{collision[:person_slug]}: " \
                 "we hold gsis #{collision[:ours]}, the master sent #{collision[:theirs]}",
        inspect: "#<#{CollisionRefused}: #{collision.to_json}>",
        target: existing,
        target_name: collision[:person_slug]
      )
      log.update_column(:slug, "error-log-#{log.id}")
      log
    rescue StandardError => e
      # A BOOKKEEPING ROW MUST NEVER KILL THE RUN IT ONLY DESCRIBES. Swallowing
      # is right here and nowhere else: the refusal is already counted in
      # `@collisions`, already bound for the cursor, and already on its way to
      # the rake task's stderr.
      Rails.logger.warn("[SyncAthletes] could not record refusal for " \
                        "#{collision[:person_slug]}: #{e.class}")
      nil
    end

    def run_status = @collisions.to_a.any? ? "ok_with_collisions" : "ok"

    # The operator needs BOTH league ids to resolve it, because only the master
    # can: give them the slug, what we hold, and what was sent.
    def collision_detail
      return nil if @collisions.to_a.empty?

      summary = @collisions.map { |c| "#{c[:person_slug]} (ours #{c[:ours]} / master #{c[:theirs]})" }
      "#{@collisions.length} row(s) REFUSED — #{summary.join('; ')}"
    end

    def upsert_person(row)
      slug = row["person_slug"].to_s.strip
      return nil if slug.empty?

      person = Person.find_by(slug: slug)
      return person if person

      Person.create!(first_name: row["first_name"].presence || "Unknown",
                     last_name: row["last_name"].presence || slug,
                     athlete: true,
                     disambiguator: row["disambiguator"].presence,
                     synced_at: Time.current,
                     source_updated_at: row["updated_at"])
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Person.find_by(slug: slug)
    end

    def attributes_from(row)
      {
        sport: row["sport"].presence || "football",
        position: row["position"],
        team_slug: row["team_slug"],
        height_inches: row["height_inches"],
        weight_lbs: row["weight_lbs"],
        espn_headshot_url: row["espn_headshot_url"],
        gsis_id: row["gsis_id"],
        espn_id: row["espn_id"],
        nflverse_id: row["nflverse_id"],
        pff_id: row["pff_id"],
        otc_id: row["otc_id"],
        pfr_id: row["pfr_id"],
        sleeper_id: row["sleeper_id"]
      }.compact
    end

    def authenticate
      body = request(:post, "/api/v1/auth", { secret: @secret }, token: nil)
      body["token"].presence || raise(Error, "no token in auth response")
    end

    def fetch(token, since, after_id)
      query = { limit: PAGE }
      query[:updated_since] = since if since.present?
      query[:after_id] = after_id if after_id.present?
      qs = query.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join("&")

      request(:get, "/api/v1/athletes?#{qs}", nil, token: token)
    end

    def request(method, path, body, token:)
      uri = URI("#{@base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri.request_uri, { "Content-Type" => "application/json", "Accept" => "application/json" })
      req["Authorization"] = "Bearer #{token}" if token
      req.body = body.to_json if body

      res = http.request(req)
      raise Error, "studio #{path.split('?').first} -> #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body.to_s)
    rescue JSON::ParserError
      # Never echo the body — the auth request's body IS the shared secret.
      raise Error, "studio #{path.split('?').first} returned unparseable JSON"
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET,
           Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError => e
      raise Error, "studio unreachable: #{e.class}"
    end
  end
end
