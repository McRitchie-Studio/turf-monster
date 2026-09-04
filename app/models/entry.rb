class Entry < ApplicationRecord
  after_create :update_slug_with_id

  # Referral cache: when an entry lands in a confirmed status (active or
  # complete), flip the user's contest_entered flag and, if they were
  # invited by someone, bump the inviter's invitees_in_contest_count
  # cache + queue the nudge email. ReferralProgress.mark_entered! is
  # idempotent, so re-firing on status churn is a no-op past the first
  # transition. after_commit (not after_save) so the email job sees the
  # committed entry if it touches the row.
  after_commit :sync_user_contest_entered, on: %i[create update]

  belongs_to :user
  belongs_to :contest
  has_many :selections, dependent: :destroy
  has_many :survivor_picks, dependent: :destroy

  enum :status, { cart: "cart", active: "active", complete: "complete", abandoned: "abandoned" }

  # The recurring "real entry" filter: submitted (active) or settled (complete) —
  # not a half-built cart or an abandoned entry. Counts toward leaderboards,
  # per-user entry limits, and "contests I've entered".
  scope :confirmed, -> { where(status: [:active, :complete]) }

  # Single-use signatures (Lazarus audit #1/#8, 2026-05-31). A finalized
  # on-chain signature may credit at most one entry — one real `enter_contest`
  # tx must never be replayed to activate a second paid entry. `allow_nil`
  # keeps cart / off-chain / comped entries (which have no signature)
  # unconstrained. The partial unique DB index added in
  # 20260531000001_add_unique_index_to_entries_onchain_tx_signature is the
  # race-safe backstop; this validation gives a clean error message.
  validates :onchain_tx_signature, uniqueness: true, allow_nil: true

  private

  def sync_user_contest_entered
    return unless active? || complete?
    ReferralProgress.mark_entered!(user)
  end

  public

  def toggle_selection!(slate_matchup)
    raise "Game has already started" if slate_matchup.locked?
    # v0.17: locking is derived (no status flip), so guard the contest lock
    # time here too — otherwise picks stay editable after lock until kickoff.
    raise "Contest has locked — entries closed" if contest.locks_at && Time.current >= contest.locks_at

    existing = selections.find_by(slate_matchup: slate_matchup)

    if existing
      existing.destroy!
    elsif selections.count < contest.picks_required
      selections.create!(slate_matchup: slate_matchup)
    else
      # Replace oldest selection
      selections.order(created_at: :asc).first.destroy!
      selections.create!(slate_matchup: slate_matchup)
    end

    reload
    if selections.empty?
      destroy!
      return nil
    end

    selections.each_with_object({}) { |s, h| h[s.slate_matchup_id.to_s] = true }
  end

  # Replace this entry's selections atomically while the contest is still open.
  # DB-only — the on-chain ContestEntry PDA is a pure ticket (no pick hash), so
  # editing picks here doesn't desync any on-chain state. Picks that are not
  # being added or removed (i.e. unchanged across the edit) are not re-checked
  # for lock state — mirrors the existing confirm! behavior where only the
  # picks being committed are validated.
  def update_picks!(matchup_ids)
    raise "Editing is not supported for this contest type" if survivor?
    raise "Contest is not open" unless contest.open?
    # v0.17: derived lock — block edits once the contest lock time has passed
    # (status stays `open`, so `open?` alone no longer closes this window).
    raise "Contest has locked — entries closed" if contest.locks_at && Time.current >= contest.locks_at

    new_ids = matchup_ids.map(&:to_i).uniq
    raise "Exactly #{contest.picks_required} selections required" unless new_ids.size == contest.picks_required

    new_matchups = contest.slate.slate_matchups.where(id: new_ids).includes(:team, :game).to_a
    raise "Invalid matchup selection" unless new_matchups.size == contest.picks_required

    current_ids = selections.pluck(:slate_matchup_id)
    changed_ids = current_ids.to_set ^ new_ids.to_set

    changed_ids.each do |id|
      m = new_matchups.find { |nm| nm.id == id } ||
          contest.slate.slate_matchups.includes(:team).find_by(id: id)
      raise "#{m.team.name}'s game has already started" if m&.locked?
    end

    transaction do
      selections.destroy_all
      new_matchups.each { |m| selections.create!(slate_matchup: m) }
    end
  end

  # Read-only entry-eligibility gates. These MUST run BEFORE any irreversible
  # on-chain side effect — the token consume in ContestsController#enter and the
  # cosign+broadcast in #confirm_onchain_entry both call this as a PRE-FLIGHT
  # check (backend discipline #2: validate before irreversible side effects). A
  # failure here leaves the token UNCONSUMED and the entry in `cart` — nothing
  # burned. `confirm!` / `confirm_onchain!` also invoke it as a serialized
  # backstop so the two call sites can never drift and the post-broadcast path
  # stays safe.
  #
  # Incident 2026-06-08 (entry #133): the managed-token path consumed the token
  # on-chain and THEN ran confirm!, whose selection-count gate raised AFTER the
  # irreversible burn — stranding the user (paid + entered on-chain, app showed
  # `cart`). A reconciler can't heal a genuine validation failure (re-running the
  # gate fails the same way); the only correct fix is to gate BEFORE the consume.
  #
  # PURE READS ONLY — no writes, and NO payment gate. The tx_signature-presence
  # check belongs in confirm!/confirm_onchain! (after the broadcast), because the
  # signature does not exist yet when this pre-flight runs.
  #
  # `comped: true` is the admin-seed escape hatch (Contest#fill! only): it exempts
  # the lock-time gate so admin seeding may legitimately happen after lock.
  def assert_enterable!(comped: false)
    raise "Contest is not open" unless contest.open?

    # H7 prelaunch audit (2026-05-24): enforce contest-wide lock time. Closes
    # the staggered-kickoff information-edge attack — a user could otherwise
    # wait until 30 min after the contest's stated lock, read live scores from
    # already-kicked games, then submit picks drawn from later-kickoff matchups
    # whose individual `locked?` is still false. `comped: true` (admin fill via
    # Contest#fill!) is exempt; admin seeding may legitimately happen after lock.
    if contest.locks_at && Time.current >= contest.locks_at && !comped
      raise "Contest has locked — entries closed"
    end

    raise "Exactly #{contest.picks_required} selections required" unless selections.count == contest.picks_required

    # Check no locked games
    selections.includes(slate_matchup: :game).each do |s|
      raise "#{s.slate_matchup.team.name}'s game has already started" if s.slate_matchup.locked?
    end

    # Contest capacity. This entry is still `cart`, so it is not double-counted.
    active_count = contest.entries.where(status: [:active, :complete]).count
    raise "Contest is full" if contest.max_entries && active_count >= contest.max_entries

    # Per-user entry limit
    user_active_count = contest.entries.where(user: user, status: [:active, :complete]).count
    raise "Maximum #{contest.max_entries_per_user} entries per contest" if user_active_count >= contest.max_entries_per_user

    # Sybil / duplicate-exact-combo check
    my_combo = selections.map(&:slate_matchup_id).sort
    contest.entries.where(user: user, status: [:active, :complete]).find_each do |other|
      other_combo = other.selections.map(&:slate_matchup_id).sort
      raise "You already have an entry with this exact selection combination" if other_combo == my_combo
    end
  end

  # Activate a cart entry. A paid contest's entry may only be activated with
  # proof of payment: `tx_signature` is the on-chain signature returned by a
  # consumed entry token or a vault entry, set server-side in
  # ContestsController#enter. Without it we refuse rather than hand out a free
  # entry — this is the gate that closes the off-chain-paid-contest hole.
  #
  # `comped: true` is the admin-seed escape hatch (Contest#fill! only): it
  # activates entries for seeded users without payment. Real user entries
  # always pass through the gate.
  def confirm!(tx_signature: nil, onchain_entry_id: nil, comped: false)
    user.with_lock do
      # Backstop the read-only gates under the user row lock so the per-user
      # limit / sybil checks stay race-safe. ContestsController#enter already
      # ran assert_enterable! as a PRE-FLIGHT before the irreversible consume;
      # this re-runs the SAME method (no drift) as the serialized backstop.
      assert_enterable!(comped: comped)

      transaction do
        # Payment gate: never activate a paid entry without proof of payment —
        # a tx_signature from a consumed entry token or a vault entry. Lives
        # here (NOT in assert_enterable!) because the signature only exists
        # AFTER the broadcast. `comped` exempts admin-seeded fills. This closes
        # the free-entry hole where an off-chain paid contest skipped every
        # payment branch in #enter.
        if contest.entry_fee_cents.to_i.positive? && tx_signature.blank? && !comped
          raise "Entry payment required — no entry token consumed or on-chain payment recorded"
        end

        if contest.entry_fee_cents > 0
          TransactionLog.record!(user: user, type: "entry_fee", amount_cents: contest.entry_fee_cents, direction: "debit", source: contest, description: "Entry fee for #{contest.name}")
        end
        update!(status: :active, onchain_tx_signature: tx_signature, onchain_entry_id: onchain_entry_id)
      end
    end

    # Score immediately against any already-decided games. Entry scoring is
    # otherwise purely reactive (Goal create/destroy → Game#score_affected_contests!,
    # plus grade!/jump!), so an entry confirmed onto a slate whose games are
    # ALREADY completed never gets scored — it sits at 0 with no event to wake it.
    # This is routine in practice: one World Cup slate is shared across many
    # contests, and a game can be `completed` (simulated/final result) while its
    # kickoff_at is still in the future, so SlateMatchup#locked? is false and the
    # confirm lock-check lets the entry through. See Contest#score_entries!.
    score!

    # Attempt onchain entry (non-blocking) — skip if already transferred on-chain
    enter_onchain! unless tx_signature
  end

  # Recompute this entry's score from its selections' current points.
  def score!
    selections.each(&:compute_points!)
    update!(score: selections.reload.sum { |s| s.points || 0 })
  end

  def selection_data
    selections.includes(slate_matchup: :team).map do |s|
      { slate_matchup_id: s.slate_matchup_id, team_slug: s.slate_matchup.team_slug }
    end
  end

  private

  def release_slot_if_abandoned
    return unless status_changed? && abandoned?
    return if entry_number.nil?
    return if onchain_tx_signature.present?

    self.entry_number = nil
  end

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  public

  # --- Onchain ---

  # Confirm entry via direct onchain payment (Phantom wallet users).
  # No DB balance deduction — USDC was transferred onchain directly.
  def confirm_onchain!(tx_signature:, entry_pda:)
    # Lock user row to prevent concurrent entry-limit bypass, then re-run the
    # read-only gates as the serialized backstop. ContestsController#
    # confirm_onchain_entry already ran assert_enterable! as a PRE-FLIGHT before
    # the irreversible cosign+broadcast (validate before side effects). No
    # `comped:` here — the on-chain path is user-initiated only (admin fills go
    # through #confirm!).
    user.with_lock do
      assert_enterable!

      # Fail-closed payment gate (Lazarus audit #1/#7, 2026-05-31). The caller
      # (ContestsController#confirm_onchain_entry and #recover_pending_entry)
      # verifies the signature semantically via Solana::TxVerifier before
      # reaching here. This assertion is defense-in-depth: a future caller that
      # forgets to verify still cannot activate a paid entry without a
      # signature — mirroring the gate Entry#confirm! already carries. It lives
      # here (not in assert_enterable!) because the signature only exists after
      # the broadcast.
      if contest.entry_fee_cents.to_i.positive? && tx_signature.blank?
        raise "Entry payment required — no verified on-chain signature recorded"
      end

      update!(
        status: :active,
        onchain_tx_signature: tx_signature,
        onchain_entry_id: entry_pda
      )
    end

    # Seeds (25 per entry) are awarded on-chain by the turf_vault Anchor program
  end

  # RELEASE THE SLOT WHEN AN ENTRY IS ABANDONED.
  #
  # Two places decide what "taken" means and they used to disagree:
  # #assign_onchain_entry_number! builds its `taken` list from
  # cart/active/complete, deliberately ignoring abandoned rows, while
  # index_entries_on_user_contest_entry_number is partial on `entry_number IS
  # NOT NULL` and does not. So an abandoned row kept a number the allocator
  # would hand out again, and the insert died on the index.
  #
  # The visible cost was a player locked out of a contest: reach the Phantom
  # prompt (which stamps the number), tap "Clear picks" (which abandons the
  # row), build picks again — and every attempt from then on raised a raw
  # PG::UniqueViolation at them.
  #
  # Releasing here rather than in ContestsController#clear_picks is deliberate:
  # clear_picks is one of the paths that abandons an entry, and a fix that
  # lived there would leave the disagreement intact for every other one.
  #
  # THE EXCEPTION IS NOT OPTIONAL. An entry that carries an on-chain signature
  # has a real ContestEntry PDA at that index whatever the database says.
  # Releasing its number would let a later entry be built against an occupied
  # PDA, which fails on-chain — a worse failure than the one being fixed, and
  # one that costs a broadcast to discover.
  before_save :release_slot_if_abandoned

  # Assign (or re-assign) this entry's on-chain slot to the lowest index whose
  # Entry PDA isn't already allocated for `wallet_address`, and isn't claimed by
  # another of this user's live entries in the contest. Probes the chain (not a
  # DB count) because on-chain Entry PDAs outlive DB rows — a contest Reset
  # destroys entries but not their PDAs, so a count-derived index collides with
  # an orphaned PDA ("Allocate ... already in use" / custom program error 0x0 at
  # EnterContest). No-op once this entry is confirmed on-chain (it keeps the slot
  # it was created under). Raises when the user has used every slot.
  def assign_onchain_entry_number!(wallet_address, vault = Solana::Vault.new)
    return entry_number if onchain_tx_signature.present?

    max = contest.max_entries_per_user
    taken = contest.entries.where(user_id: user_id)
                   .where.not(id: id)
                   .where(status: [:cart, :active, :complete])
                   .where.not(entry_number: nil)
                   .pluck(:entry_number)

    free = vault.next_free_entry_index(contest.slug, wallet_address, max: max, skip: taken)
    raise "You've already used all #{max} of your entry slots for this contest." if free.nil?

    update!(entry_number: free) if entry_number != free
    free
  end

  def enter_onchain!
    return unless contest.onchain? && user.solana_connected?

    vault = Solana::Vault.new

    # Assign entry slot by probing the chain for a free index (see
    # #assign_onchain_entry_number! — guards against orphaned-PDA collisions).
    assign_onchain_entry_number!(user.solana_address, vault)

    # Ensure user's onchain account exists before entering.
    # v0.16 requires a valid username (>= 3 chars) at PDA creation.
    vault.ensure_user_account(user.solana_address, username: user.username)

    # v0.16: unified enter_contest requires the user's keypair to sign the
    # SPL transfer from their ATA. This convenience method is only safe for
    # managed wallets (server holds the keypair); Phantom users must go
    # through ContestsController#prepare_entry → build_enter_contest path.
    raise "enter_onchain! requires a managed wallet" unless user.solana_keypair

    result = vault.enter_contest(
      user.solana_address,
      contest.slug,
      entry_number,
      currency_idx: 0,
      user_keypair: user.solana_keypair,
      season_id: contest.season_id
    )
    update!(
      onchain_entry_id: result[:entry_pda],
      onchain_tx_signature: result[:signature]
    )
  rescue => e
    ErrorLog.capture!(e)
    # Don't block DB entry — onchain can be retried
  end

  def onchain?
    onchain_entry_id.present?
  end

  # --- Survivor ---

  def survivor?
    contest.world_cup_survivor?
  end

  def eliminated?
    eliminated_round.present?
  end

  def alive?
    survivor? && !eliminated?
  end

  # Rounds successfully survived — every round before elimination, or every
  # surviving pick so far for an entry still alive.
  def rounds_survived
    eliminated_round ? eliminated_round - 1 : survivor_picks.survived.count
  end

  def pick_for(survivor_round)
    survivor_picks.find_by(survivor_round: survivor_round)
  end

  # Team slugs already used — no team may be picked twice across the tournament.
  def used_team_slugs
    survivor_picks.pluck(:team_slug)
  end

  def to_param
    slug
  end

  def name_slug
    "#{user.display_name.parameterize}-#{contest.name_slug}-#{id}"
  end
end
