module Operator
  # The named, bounded contest operations the McRitchie Studio hub may ask for
  # on the owner's word (the hub's `operate` catalog, mcritchie-studio
  # docs/agents/system/agent-message-loop.md, "Operations"). Served by
  # Operator::ContestsController behind TURF_OPERATOR_TOKEN.
  #
  # WHAT IT IS NOT: a way around the admin UI. Each operation is what an admin
  # already does by hand, and stops where the admin's own wallet takes over:
  #
  #   list     a read: recent contests with their state, entry and paid-entry
  #            counts, and whether a cancel is already waiting.
  #   cancel   Contests::CancelQueue, the admin button's own build: a
  #            cancel_contest PendingTransaction for a cosign in the Treasury.
  #            Nothing is broadcast; the owner's wallet signs it there
  #            (AGENTS.md First Rule 10). With paid entries it refuses until
  #            the request names the refund-or-credit choice, which is recorded
  #            on the pending transaction for the human refund step
  #            (docs/runbooks/cancelled-contest-refunds.md).
  #   prepare  NO WRITE. Checks a week span and a format and returns the
  #            /contests/new link pre-filled the way the contest generator
  #            links it; the admin reviews it and signs the create in Phantom.
  #
  # Every refusal is a Refused with a stable code and operator copy, never an
  # exception's own message.
  class ContestOps
    LIST_LIMIT_MAX = 25
    LIST_SCOPES = %w[open all].freeze
    CHOICES = %w[none refund credit].freeze
    SEASONS = { "regular" => Slate::DEFAULT_SEASON_TYPE, "preseason" => Slate::PRESEASON_SEASON_TYPE }.freeze
    WEEK_RANGE = (1..22)
    # The /contests/new form's Weeks select offers 1 to 3.
    SPAN_RANGE = (1..3)
    TREASURY_PATH = "/admin/pending_transactions".freeze
    TEXT_MAX = 100

    class Refused < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(vault_factory: -> { Solana::Vault.new })
      @vault_factory = vault_factory
    end

    # Recent contests, newest first: open ones (pending, open, settlement
    # pending; cancelled included, flagged) or all of them.
    def list(scope: "open", limit: 10)
      scope = LIST_SCOPES.include?(scope.to_s) ? scope.to_s : "open"
      limit = limit.to_i.clamp(1, LIST_LIMIT_MAX)
      relation = Contest.includes(:slate).order(created_at: :desc).limit(limit)
      relation = relation.where(status: %w[pending open settlement_pending], onchain_closed: false) if scope == "open"
      contests = relation.to_a
      ids = contests.map(&:id)
      entries = Entry.where(contest_id: ids, status: %w[active complete]).group(:contest_id).count
      paid = Contest.paid_entries.where(contest_id: ids).distinct.group(:contest_id).count(:id)
      queued = PendingTransaction.where(target_type: "Contest", target_id: ids, tx_type: "cancel_contest",
                                        status: Contests::CancelQueue::IN_FLIGHT).distinct.pluck(:target_id)
      contests.map do |contest|
        { "slug" => contest.slug, "name" => contest.name, "status" => contest.status,
          "cancelled" => contest.onchain_cancelled?, "cancel_queued" => queued.include?(contest.id),
          "onchain" => contest.onchain?, "weeks" => contest.week_span_label, "format" => contest.contest_type,
          "locks_at" => contest.locks_at&.iso8601, "locked" => contest.locked?,
          "entries" => entries.fetch(contest.id, 0), "paid_entries" => paid.fetch(contest.id, 0),
          "max_entries" => contest.max_entries }
      end
    end

    # Queue the contest's cancel for a cosign. Returns the result Hash.
    def cancel(slug:, paid_entries: "none", requested_by: nil, request_ref: nil)
      choice = paid_entries.to_s.presence || "none"
      raise Refused.new("bad_choice", "paid_entries must be one of #{CHOICES.join(', ')}") unless CHOICES.include?(choice)

      contest = Contest.find_by(slug: slug.to_s)
      raise Refused.new("not_found", "No contest #{slug.to_s[0, 80].inspect}") unless contest

      paid = Contest.paid_entries.where(contest_id: contest.id).distinct.count(:id)
      if paid.positive? && choice == "none"
        raise Refused.new("paid_entries_need_choice",
                          "#{contest.name} has #{paid} paid #{paid == 1 ? 'entry' : 'entries'}. " \
                          "Say whether they are refunded or credited before it is cancelled.")
      end

      metadata = { "source" => "operator", "requested_by" => plain(requested_by), "request_ref" => plain(request_ref),
                   "paid_entries" => paid, "paid_entries_choice" => (choice unless choice == "none") }.compact
      pending, created = Contests::CancelQueue.new(contest, vault: @vault_factory.call).call(metadata: metadata)
      recorded = pending.parsed_metadata
      { "state" => created ? "queued" : "already_queued", "slug" => contest.slug, "name" => contest.name,
        "pending_transaction_id" => pending.id, "entries" => contest.active_entry_count, "paid_entries" => paid,
        "paid_entries_choice" => recorded["paid_entries_choice"], "treasury_path" => TREASURY_PATH }.compact
    rescue Contests::CancelQueue::Refused => e
      raise Refused.new("not_cancellable", e.message)
    end

    # Check a week span and a format; return the pre-filled create link.
    def prepare(week:, weeks: 1, season: "regular", contest_type: "medium")
      week = integer(week, WEEK_RANGE, "week")
      weeks = integer(weeks, SPAN_RANGE, "weeks")
      season_type = SEASONS[season.to_s] or raise Refused.new("bad_season", "season must be one of #{SEASONS.keys.join(', ')}")
      format = Contest.selectable_formats[contest_type.to_s]
      raise Refused.new("bad_format", "contest_type must be one of #{Contest.selectable_formats.keys.join(', ')}") unless format

      wanted = (week...(week + weeks)).to_a
      anchor = single_week(Slate.where(sport: "nfl", season_type: season_type, week: week).where.not(year: nil)
                                .order(year: :desc, id: :asc)).first
      raise Refused.new("no_slate", "No NFL #{season} slate for week #{week}") unless anchor

      found = single_week(Slate.where(sport: "nfl", season_type: season_type, year: anchor.year, week: wanted)).map(&:week)
      missing = wanted - found
      if missing.any?
        raise Refused.new("no_slate", "NFL #{anchor.year} #{season} has no slate for " \
                                      "week#{'s' if missing.size > 1} #{missing.join(', ')}")
      end

      query = { slate_id: anchor.id, contest_type: contest_type.to_s, contest: { week_span: weeks } }.to_query
      label = weeks == 1 ? "Week #{week}" : "Weeks #{week}-#{wanted.last}"
      { "state" => "ready", "path" => "/contests/new?#{query}", "year" => anchor.year, "weeks" => label,
        "anchor_slate" => anchor.name, "format" => contest_type.to_s,
        "entry_fee_cents" => format[:entry_fee_cents], "max_entries" => format[:max_entries],
        "prize_cents" => format[:payouts].values.sum }
    end

    private

    def single_week(relation) = relation.to_a.select { |slate| slate.week_range&.size == 1 }

    def integer(value, range, name)
      int = value.is_a?(Integer) ? value : (value.to_s.match?(/\A\d{1,3}\z/) ? value.to_i : nil)
      raise Refused.new("bad_#{name}", "#{name} must be between #{range.first} and #{range.last}") unless int && range.cover?(int)

      int
    end

    def plain(value) = value.to_s.gsub(/[[:cntrl:]]/, " ").squish[0, TEXT_MAX].presence
  end
end
