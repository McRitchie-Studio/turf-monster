class Contest
  # A COMING-SOON CONTEST OPENS ITSELF. `coming_soon` advertises a contest that
  # takes no entries yet (Entries::ApiSubmission refuses it, the card sashes
  # it). Until this existed the only way back to open was an admin remembering
  # to flip the flag, and on 2026-10-22 nobody did: the NFL weeks 7-9 contest,
  # on chain and priced, locked at its starts_at still sashed COMING SOON, with
  # zero entries, and nobody noticed for two days.
  #
  # So the flag now has a date. `reveal_at` defaults to REVEAL_LEAD before the
  # lock when a contest is created, the admin edit form can move it, and
  # Contests::RevealSweepJob turns `coming_soon` off once it has passed — but
  # only for a contest that is ready to take money: open, not cancelled, not
  # locked, on chain (it has its PDA) and priced (every team on its slate has
  # a rank and a Turf Score). A contest that is due but not ready stays coming
  # soon and the sweep names why in its log.
  #
  # HOLD IS THE DELIBERATE STATE. `coming_soon_hold` says "advertised, and
  # closed on purpose". The sweep never reveals a held contest and never alerts
  # on one, and the 24-hour refusal below steps aside for it. Without it, the
  # only way to say "not yet" was the same flag a forgotten contest carries.
  #
  # THE GUARD BEHIND THE CONSTRUCTION. A contest still coming soon within
  # ALERT_WINDOW of its lock, and not held, is about to close without taking an
  # entry. Saving one in that state is refused (#coming_soon_clear_of_lock),
  # and the sweep raises ONE alert per contest for any that reach it anyway
  # (#alert_coming_soon_at_lock!).
  #
  # A LEGACY CONTEST (reveal_at nil) IS NEVER REVEALED AUTOMATICALLY. Before
  # `coming_soon_hold` existed, `coming_soon: true` was the only way to say
  # "deliberately not open", so the sweep cannot tell a forgotten flag from an
  # intended one on a row written before this shipped. Computing a date for it
  # would publish contests, at deploy, by inference. The alert still covers
  # those rows, and giving one a reveal_at on the edit form opts it in.
  #
  # Included at the foot of Contest: docs/workflows cites contest.rb by line.
  module Reveal
    extend ActiveSupport::Concern

    REVEAL_LEAD = 7.days
    ALERT_WINDOW = 24.hours

    # The alert, as a named class so /admin/error_logs tells it apart at a
    # glance (house convention: Contests::PendingReconciler#flag!).
    class ComingSoonAtLockError < StandardError; end

    included do
      before_validation :default_reveal_at, on: :create
      before_save :rearm_coming_soon_alert, if: :will_save_change_to_starts_at?
      validate :coming_soon_clear_of_lock
      validate :reveal_before_lock

      # Coming soon and not held: the contests the sweep looks at.
      scope :coming_soon_unheld, -> { where(coming_soon: true, coming_soon_hold: false) }
    end

    # Why a contest that is due would not be revealed, or nil when it is ready.
    def reveal_blocker
      return "not open" unless open?
      return "cancelled" if cancelled?
      return "locked" if locked?
      return "not on chain" unless onchain?
      return "unpriced" unless priced?

      nil
    end

    # Every team on the slate carries a rank and a Turf Score. An empty slate
    # is not priced: there is nothing to pick.
    def priced?
      return false unless slate

      matchups = slate.slate_matchups
      matchups.exists? && !matchups.where(rank: nil).or(matchups.where(turf_score: nil)).exists?
    end

    # The reveal a reader can count on: reveal_at while the contest is coming
    # soon and not held, else nil (already open, held, or a legacy row with no
    # scheduled reveal). The public API's `reveal_at`.
    def scheduled_reveal_at
      reveal_at if coming_soon? && !coming_soon_hold?
    end

    def reveal_due?(now = Time.current)
      coming_soon? && !coming_soon_hold? && reveal_at.present? && reveal_at <= now
    end

    # The reveal, when the contest is due and ready; returns true when this
    # call turned the flag off. Idempotent and race-safe: the UPDATE is
    # conditioned on the row still being coming soon and unheld, so a second
    # run, or an admin turning Hold on a moment earlier, changes nothing.
    def reveal!(now = Time.current)
      return false unless reveal_due?(now)
      return false if reveal_blocker

      flipped = Contest.coming_soon_unheld.where(id: id).update_all(coming_soon: false, updated_at: now)
      return false unless flipped == 1

      self.coming_soon = false
      clear_attribute_changes([:coming_soon])
      Rails.logger.info("[contest_reveal][revealed] #{slug} reveal_at=#{reveal_at.iso8601} locks_at=#{locks_at&.iso8601}")
      true
    end

    # Coming soon, not held, and its lock is within ALERT_WINDOW (or already
    # past, while ungraded): it will close, or has closed, without an entry.
    def coming_soon_at_lock?(now = Time.current)
      return false unless coming_soon? && !coming_soon_hold?
      return false if graded? || cancelled?

      at = locks_at
      at.present? && at <= now + ALERT_WINDOW
    end

    # ONE ALERT PER CONTEST, not one per sweep tick. The claim on
    # `coming_soon_alerted_at` is taken by a conditional UPDATE first, so two
    # overlapping runs cannot both page; if the page itself fails the claim is
    # released and the next tick tries again. Moving the lock re-arms it
    # (#rearm_coming_soon_alert). Returns the ErrorLog, or nil when nothing
    # was raised.
    def alert_coming_soon_at_lock!(now = Time.current)
      return unless coming_soon_at_lock?(now)

      claimed = Contest.where(id: id, coming_soon_alerted_at: nil).update_all(coming_soon_alerted_at: now)
      return unless claimed == 1

      begin
        log = ErrorLog.capture!(ComingSoonAtLockError.new(coming_soon_at_lock_message(now)))
        log.target = self
        log.target_name = slug
        log.save!
      rescue StandardError
        Contest.where(id: id).update_all(coming_soon_alerted_at: nil)
        raise
      end
      self.coming_soon_alerted_at = now
      clear_attribute_changes([:coming_soon_alerted_at])
      Rails.logger.warn("[contest_reveal][alert] #{slug} locks_at=#{locks_at&.iso8601}")
      log
    end

    # The admin edit form's field: reveal_at as a datetime-local value in the
    # house zone (Contest::LockRule::ZONE), since the app itself runs in UTC and
    # an operator reading a UTC wall clock would set it seven hours off. Blank
    # clears it, which means no automatic reveal.
    LOCAL_FORMAT = "%Y-%m-%dT%H:%M".freeze

    def reveal_at_local
      reveal_at&.in_time_zone(Contest::LockRule::ZONE)&.strftime(LOCAL_FORMAT)
    end

    def reveal_at_local=(value)
      self.reveal_at = value.presence && ActiveSupport::TimeZone[Contest::LockRule::ZONE].parse(value.to_s)
    end

    private

    def coming_soon_at_lock_message(now)
      tense = locks_at <= now ? "locked at" : "locks at"
      "Contest #{slug} is still Coming Soon and #{tense} #{locks_at.iso8601} with " \
        "#{entries.count} entr#{entries.count == 1 ? 'y' : 'ies'}, so it takes no entries " \
        "before it closes. #{reveal_blocker ? "It is not ready to reveal (#{reveal_blocker}). " : ''}" \
        "Turn Coming Soon off, or turn Hold on if it is closed on purpose: #{admin_edit_url}"
    end

    def admin_edit_url
      Rails.application.routes.url_helpers.edit_contest_url(self)
    rescue StandardError
      "/contests/#{slug}/edit"
    end

    def default_reveal_at
      return if reveal_at.present?

      at = locks_at
      self.reveal_at = at - REVEAL_LEAD if at
    end

    def rearm_coming_soon_alert
      self.coming_soon_alerted_at = nil
    end

    # Refused only when this save is the one that puts the contest in that
    # state: a create, or a change to the flag, the hold or the lock. Every
    # other write (grading, settlement, a tagline edit on a contest already in
    # this state) is left alone, so a legacy row cannot jam a money path.
    def coming_soon_clear_of_lock
      return unless new_record? || will_save_change_to_coming_soon? ||
                    will_save_change_to_coming_soon_hold? || will_save_change_to_starts_at?
      return unless coming_soon? && !coming_soon_hold?

      at = locks_at
      return unless at.present? && at <= Time.current + ALERT_WINDOW

      errors.add(:base, "Coming Soon is on and this contest locks within 24 hours, so it would close " \
                        "without taking an entry. Turn Coming Soon off, or turn Hold on to keep it " \
                        "advertised and closed on purpose.")
    end

    def reveal_before_lock
      return unless will_save_change_to_reveal_at? && reveal_at.present?

      at = locks_at
      return unless at.present? && reveal_at >= at

      errors.add(:reveal_at, "must be before the lock time")
    end
  end
end
