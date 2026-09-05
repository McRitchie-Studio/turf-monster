class User < ApplicationRecord
  include Sluggable

  # The seeded house account's stable identity (db/seeds/users.rb). Usernames
  # can be renamed (and "turf" is itself a reserved prefix), so User.turf keys
  # on this email, never the username.
  #
  # It moved off `turf@mcritchie.studio` on 2026-09-04. That address was a Google
  # GROUP with zero members forwarding into the studio inbox; this one is a real
  # Google user on Turf's own domain (1Password `google.turf.agents`), which is
  # what lets the house account actually receive mail as itself.
  TURF_HOUSE_EMAIL = "team@turfmonster.media".freeze

  # Stable identities whose usernames are parked before the generic generator
  # runs. These are keyed by verified email or wallet ownership so a fresh DB,
  # QA reset, or unseeded wallet login does not mint a random fruit-animal name
  # for a known operator wallet/email.
  PARKED_IDENTITIES = [
    # "Alex McRitchie", not "Mr. McRitchie": the layered email banner greets by
    # the FIRST NAME TOKEN, so the old value rendered "Welcome Mr.!" in every
    # sign-in email and on /admin/emails. mcritchie-studio already names the same
    # person "Alex McRitchie" — one person, one name, across the apps.
    #
    # THE HUMAN HOLDS `alex`, as of 2026-09-04. The 2026-06-02 flip had given the
    # bare name to the shared team account and put the person on `mcritchie`;
    # this reverses it, so the username reads as the person it belongs to.
    { email: "alex@mcritchie.studio",  name: "Alex McRitchie",  username: "alex",      role: "admin", wallet: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" },
    # The shared team account — the server-side signer, not a person — now on
    # `mcritchie`. Named "Team McRitchie" here and in mcritchie-studio.
    { email: "team@mcritchie.studio",  name: "Team McRitchie",  username: "mcritchie", role: "admin", wallet: "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" },
    { email: "mason@mcritchie.studio", name: "Mason McRitchie", username: "mason",     role: "user",  wallet: "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" },
    { email: "mack@mcritchie.studio",  name: "Mack McRitchie",  username: "mack",      role: "user",  wallet: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds" },
    # THIS APP'S ADMIN ON ITS OWN DOMAIN — and it is the house account itself now.
    # Every app seeds the shared identities plus an admin on its own domain, so a
    # session can be signed in as "the operator of THIS app" without borrowing
    # Studio's identity. A separate `alex@turfmonster.media` / `alexturf` row used
    # to carry that; it was removed on 2026-09-04 because TURF_HOUSE_EMAIL now
    # satisfies the same property with one account instead of two.
    #
    # (`alex@turfmonster.media` still exists as the SUPPORT and marketing FROM
    # address — see ApplicationMailer::MARKETING_FROM and the pages/ views. Only
    # the seeded user was retired.)
    { email: TURF_HOUSE_EMAIL,         name: "Turf Monster",    username: "turf",      role: "admin", wallet: "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo" }
  ].freeze

  # SEATS THE ROSTER HAS RETIRED, email => the role their row keeps, and the only
  # thing that ever demotes one.
  #
  # Nothing in this app reconciles a user against PARKED_IDENTITIES: there is no
  # save-time callback for role or email (only `ensure_username`, and only on
  # create), the seed touches the rows it seeds, and `admin:claim_usernames`
  # writes usernames. So an identity dropped from the roster does not lose
  # anything — it simply stops being described, and keeps the admin it was seeded
  # with. `alex@turfmonster.media` is that case: retired on 2026-09-04 because
  # TURF_HOUSE_EMAIL now satisfies the same "an admin on this app's own domain"
  # property, and it remains the PUBLIC support and marketing address (see
  # ApplicationMailer::MARKETING_FROM and the pages/ views), so an app account on
  # it that still holds admin is a login anyone who reads the footer can address.
  #
  # It is demoted, not deleted: the row has entries, purchases and a managed
  # wallet, and destroying a real account is the operator's call, not a seed's.
  RETIRED_IDENTITIES = {
    "alex@turfmonster.media" => "user"
  }.freeze

  # Rails mirror of turf-vault's on-chain reserved-prefix list — keep in sync
  # with RESERVED_PREFIXES in turf-vault
  # programs/turf_vault/src/instructions/set_username.rs (v0.15.1, audit C2).
  # The program rejects any username that case-insensitively STARTS WITH one
  # of these (custom error 6020 UsernameReserved); without this mirror a user
  # can hold a Rails username that later fails on-chain with an opaque hex
  # error. Admins are exempt (they register reserved names via the on-chain
  # admin path, v0.25+).
  RESERVED_USERNAME_PREFIXES = %w[
    admin system turf vault turfmonster support mod official staff team root
  ].freeze

  # Passwordless: email auth is magic-link only (MagicLink service / MagicLinksController).
  # has_secure_password was removed in the passwordless re-auth refactor (closes Lazarus
  # audit #4 — the password re-auth → wallet-key-theft chain). The password_digest column
  # is kept dormant (no migration) but there is no longer a password= setter or #authenticate.
  has_one_attached :avatar
  has_many :entries, dependent: :destroy
  has_many :transaction_logs, dependent: :destroy
  has_many :stripe_purchases, dependent: :destroy
  has_many :cdp_ramp_transactions, dependent: :destroy
  has_many :paypal_purchases, dependent: :destroy
  has_many :coinflow_purchases, dependent: :destroy
  has_many :aeropay_purchases, dependent: :destroy
  belongs_to :inviter, class_name: "User", optional: true, foreign_key: :invited_by_id
  has_many :invitees, class_name: "User", foreign_key: :invited_by_id

  validates :email, uniqueness: true, allow_nil: true
  # Email format = URI::MailTo structure + a real dotted TLD (see User.valid_email?),
  # so dotless / 1-letter-TLD addresses can't be saved. Scoped to email changes so
  # it never blocks an unrelated save of a grandfathered record.
  validate :email_format, if: :email_changed?
  validates :web2_solana_address, uniqueness: true, allow_nil: true
  validates :web3_solana_address, uniqueness: true, allow_nil: true
  validates :username, length: { in: 3..30 }, format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "only letters, numbers, hyphens, and underscores" }, uniqueness: { case_sensitive: false }, allow_nil: true
  # Scoped to username changes so a grandfathered reserved name (e.g. the
  # house "turf" row) never blocks an unrelated save.
  validate :username_not_reserved, if: :username_changed?
  validate :has_authentication_method

  before_validation :ensure_username, on: :create
  before_save :set_name_parts, if: -> { name_changed? }
  before_create :set_initial_session_token  # OPSEC-045
  # Sluggable's before_save builds "<base>-<id>" — but on CREATE the id does not
  # exist yet, so every fresh row lands with a DANGLING "<base>-". Until now the
  # id got filled in by ACCIDENT: generate_managed_wallet! ran an update! on
  # every non-admin immediately after create, and that second save re-ran the
  # slug builder with the id present. Admins, who never get a managed wallet,
  # have always kept the dangling shape (see the seeded `alex-` / `turf-`), and
  # web3-only onboarding extends that to EVERY new account — silently changing
  # the URL shape of every new profile, and breaking anything that looks a user
  # up by the id-bearing slug.
  #
  # So finalize it explicitly rather than depending on whether some other
  # callback happens to save the row. Runs BEFORE generate_managed_wallet! so
  # the slug is settled no matter what that one does.
  after_create :finalize_slug!
  after_create :generate_managed_wallet!
  # The username's master record lives on-chain — create the UserAccount PDA
  # (with the username) right after signup. after_commit so the managed wallet
  # + username are committed before the job runs.
  after_commit :enqueue_onchain_account_setup, on: :create

  # Referral cache: keep the inviter's invitees_count + (if this user has
  # already entered a contest) invitees_in_contest_count in sync when
  # invited_by_id is set/changed. ReferralProgress.sync_invitee_attribution!
  # is a no-op when invited_by_id didn't change.
  after_save { ReferralProgress.sync_invitee_attribution!(self) }

  # Newsletter subscribers = joined at least once and not since unsubscribed.
  scope :subscribed_to_newsletter, -> {
    where.not(joined_email_list_at: nil)
         .where("users.left_email_list_at IS NULL OR users.left_email_list_at < users.joined_email_list_at")
  }

  # Most-recently-active first (admin dashboard). last_seen_at is touched
  # throttled per authenticated request (ApplicationController#touch_last_seen);
  # users never seen since the column was added sort last.
  scope :by_recent_session, -> {
    order(Arel.sql("users.last_seen_at DESC NULLS LAST, users.created_at DESC"))
  }

  # --- Class methods ---

  # Single source of email validity — shared by the model validation
  # (#email_format) and the magic-link request controller, and mirrored by the
  # client emailValidator: URI::MailTo's structure PLUS a real dotted TLD (>=2
  # letters), so dotless domains and 1-letter TLDs (which URI::MailTo accepts on
  # its own) are rejected before we email a magic link into a void.
  def self.valid_email?(str)
    str = str.to_s
    str.present? && str.match?(URI::MailTo::EMAIL_REGEXP) && str.match?(/\.[a-zA-Z]{2,}\z/)
  end

  def self.parked_identity_for(email: nil, wallet: nil)
    normalized_email = email.to_s.strip.downcase.presence
    normalized_wallet = wallet.to_s.strip.presence
    return nil if normalized_email.blank? && normalized_wallet.blank?

    PARKED_IDENTITIES.find do |identity|
      (normalized_email.present? && identity[:email].to_s.downcase == normalized_email) ||
        (normalized_wallet.present? && identity[:wallet].to_s == normalized_wallet)
    end
  end

  def self.parked_username_for(email: nil, wallet: nil)
    parked_identity_for(email: email, wallet: wallet)&.fetch(:username, nil)
  end

  def self.username_available_for?(username, user: nil)
    return false if username.blank?

    scope = where("LOWER(username) = ?", username.to_s.downcase)
    scope = scope.where.not(id: user.id) if user&.id
    !scope.exists?
  end

  # OPSEC-005: from_omniauth now refuses to silently link a freshly-arrived
  # Google identity to an unverified-email password user. Caller must pass
  # `email_verified: true` (set by GoogleOauthValidator after re-checking
  # Google's tokeninfo endpoint) for any linking to occur. If the existing
  # user hasn't proven they own the email (email_verified_at present), we
  # refuse the link and return :requires_verification — the controller
  # surfaces an explicit "this email already has an account; verify it
  # first" flow rather than auto-merging.
  #
  # Return values:
  #   - User instance         — happy path (returning Google user, or fresh signup)
  #   - :requires_verification — collision with an unverified existing user
  #   - :email_not_verified   — Google didn't verify the email (caller refused)
  def self.from_omniauth(auth, email_verified: false)
    # Returning Google user — already linked by (provider, uid)
    user = find_by(provider: auth.provider, uid: auth.uid)
    if user
      user.claim_parked_username!
      return user
    end

    return :email_not_verified unless email_verified

    # Existing user with matching email — only auto-link if THEY also
    # proved ownership of this email at some point. Otherwise refuse: the
    # incoming Google identity has proven the email, but the existing
    # account hasn't, so we don't know they're the same human.
    existing = find_by(email: auth.info.email)
    if existing
      return :requires_verification if existing.email_verified_at.blank?
      existing.update!(
        provider: auth.provider,
        uid: auth.uid,
        email_verified_at: existing.email_verified_at || Time.current
      )
      existing.claim_parked_username!
      return existing
    end

    # Brand new user via Google — email is verified by Google itself, so
    # mark verified at create-time.
    create!(
      email: auth.info.email,
      name: auth.info.name,
      provider: auth.provider,
      uid: auth.uid,
      email_verified_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    # Race condition: another request created the user between our find_by and create
    find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
  end

  def self.from_solana_wallet(address)
    find_by(web3_solana_address: address)
  end

  # The "Turf Monster" house account (seeded admin, tied to the agent.turf.solana
  # wallet). It's the display author for system chat announcements — e.g. the
  # "<name> joined the contest" line, which is posted as a reactable bubble FROM
  # Turf Monster. Returns nil only in an unseeded DB (callers fall back). Not
  # memoized: the test suite recreates users, so a process-level cache would go
  # stale; the lookup is on the unique `email` index and only fires for the
  # handful of system messages in a chat render.
  #
  # Keyed on the seeded TURF_HOUSE_EMAIL (db/seeds/users.rb) — the stable
  # identity that survives renames — with a username fallback for legacy
  # rows seeded before the email convention.
  def self.turf
    find_by(email: TURF_HOUSE_EMAIL) || find_by(username: "turf")
  end

  # Case-insensitive starts-with check against the on-chain reserved list
  # (see RESERVED_USERNAME_PREFIXES). Shared by the model validation and the
  # ensure_username generator filter.
  def self.reserved_username?(name)
    candidate = name.to_s.downcase
    RESERVED_USERNAME_PREFIXES.any? { |prefix| candidate.start_with?(prefix) }
  end

  def admin?
    role == "admin"
  end

  def inviter_slug=(slug)
    self.inviter = User.find_by(slug: slug) if slug.present?
  end

  # --- Display ---

  def display_name
    username.presence || name.presence || (email.present? ? email.split("@").first.capitalize : nil) || truncated_solana || "anon"
  end

  def avatar_initials
    (username.presence || name.presence || "?").first.upcase
  end

  AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

  def avatar_color
    key = username.presence || name.presence || email.presence || id.to_s
    AVATAR_COLORS[Digest::MD5.hexdigest(key).hex % AVATAR_COLORS.size]
  end

  def profile_complete?
    username.present?
  end

  def claim_parked_identity!
    return false unless assign_parked_identity

    save! if persisted?
    true
  end
  alias_method :claim_parked_username!, :claim_parked_identity!

  # Username changes are on-chain instructions against the UserAccount PDA,
  # so we need a connected wallet. We ALSO gate on contest_entered? — the
  # auto-generated kebab-case slug stays locked until the user has played
  # at least one contest, so accounts can't be created and immediately
  # renamed (anti-squatting + a small earn-it incentive).
  def can_change_username?
    solana_connected? && contest_entered?
  end

  def truncated_solana
    return nil unless solana_address.present?
    "#{solana_address[0..3]}...#{solana_address[-4..]}"
  end

  # --- Slate Progress ---

  def completed_slate_ids
    Entry.where(user: self, status: [:active, :complete])
         .joins(:contest)
         .where.not(contests: { slate_id: nil })
         .distinct
         .pluck("contests.slate_id")
  end

  def slate_progress(group_slates)
    completed = completed_slate_ids
    {
      completed_count: group_slates.count { |s| completed.include?(s.id) },
      total_count: group_slates.size,
      completed_slate_ids: completed,
      all_complete: group_slates.all? { |s| completed.include?(s.id) },
      slates: group_slates.map { |s| { id: s.id, name: s.name, starts_at: s.starts_at, completed: completed.include?(s.id) } }
    }
  end

  # --- Predicates ---

  def solana_connected?
    web2_solana_address.present? || web3_solana_address.present?
  end

  def managed_wallet?
    web2_solana_address.present?
  end

  def phantom_wallet?
    web3_solana_address.present?
  end

  # Canonical wallet identity — which kind of wallet this account holds,
  # independent of how the current session authenticated (see SessionContext).
  #   :phantom — has a self-custody web3 wallet (a managed wallet may also exist)
  #   :managed — custodial wallet only
  #   :none    — no wallet at all (e.g. an admin who has not linked Phantom)
  def wallet_kind
    return :phantom if phantom_wallet?
    return :managed if managed_wallet?
    :none
  end

  # --- Web3 authentication memory ---

  # Stamp that this account just proved its self-custody wallet by signature,
  # and (when the client told us) WHICH wallet brand did the proving.
  #
  # Why remember the brand at all: Web3StepUpPolicy exists to tell a wallet
  # account that its email/Google session cannot sign on-chain. Without this,
  # the only thing that modal can offer is the generic three-brand picker — so a
  # returning Phantom user is made to re-choose Phantom from a list, every time.
  # With it, the modal leads with one button that says Continue with Phantom.
  #
  # `provider` arrives from the browser (it reads the name off the Wallet
  # Standard registration), so it is UNTRUSTED and goes through
  # Solana::WalletProvider.normalize — an unknown or absent brand leaves the
  # column alone rather than storing junk that can never match again. The
  # timestamp is stamped either way: knowing WHEN the wallet last signed is
  # useful even when we never learned its name.
  #
  # update_columns, matching the funnel-attribution and age-attestation stamps
  # above it: this runs inside an auth path on a row that may be years old, and a
  # validation added since that row was written must not turn a successful
  # signature into a failed login.
  def record_web3_authentication!(provider: nil)
    return false unless persisted?

    attrs = { web3_authenticated_at: Time.current }
    normalized = Solana::WalletProvider.normalize(provider)
    attrs[:web3_wallet_provider] = normalized if normalized
    update_columns(attrs)
    true
  end

  # --- Newsletter / quest ---

  # Subscribed = joined at least once and not since unsubscribed. Mirrors the
  # subscribed_to_newsletter scope.
  def subscribed_to_newsletter?
    joined_email_list_at.present? &&
      (left_email_list_at.nil? || left_email_list_at < joined_email_list_at)
  end

  # The 25-seed bonus fires on the user's FIRST manual username change only.
  # Every account gets an auto adjective-noun name at signup (before_validation
  # :ensure_username), so "has changed it" is tracked explicitly via
  # username_changed_at, never inferred from the current name.
  def first_username_change?
    username_changed_at.nil?
  end

  # The 25-seed chat bonus fires on the user's FIRST contest-chat message only
  # (v0.23 quest). Tracked explicitly via first_chat_message_at; the on-chain
  # SeedGrant[chat] PDA is the hard once-ever guard.
  def first_chat_message?
    first_chat_message_at.nil?
  end

  # The 25-seed newsletter bonus fires on the user's FIRST-EVER join only.
  # joined_email_list_at stays set across a later unsubscribe/rejoin, so a
  # re-subscribe never re-pays (the on-chain SeedGrant[newsletter] PDA is the
  # hard once-ever guard; this keeps the UI from over-claiming seeds on a rejoin).
  def first_newsletter_join?
    joined_email_list_at.nil?
  end

  # Which quest mission the contest card shows: username -> chat -> newsletter
  # -> invite (terminal). Only meaningful once the user has entered a contest
  # (the card is gated on @has_entry upstream; can_change_username? already
  # requires it).
  def quest_step
    return :username   if first_username_change?
    return :chat       if first_chat_message?
    return :newsletter unless subscribed_to_newsletter?
    :invite
  end

  # The next step to nudge in the gear menu. Prepends the (non-technical) "join a
  # contest" step ahead of the quest_step ladder, since the quests only unlock
  # after entering: join -> username -> chat -> newsletter -> invite (terminal,
  # ongoing).
  def next_quest
    return :join unless contest_entered?
    quest_step
  end

  # Append the request IP to the per-user `ips` audit set (admin abuse review).
  # Shape: { "1.2.3.4" => { "first" => iso8601, "last" => iso8601, "count" => N } }.
  # Skips the write when the IP is already known and was seen within the last day,
  # so we don't write the users row on every request.
  def record_ip!(ip)
    ip = ip.to_s
    return if ip.blank?

    now = Time.current
    if (entry = ips[ip])
      last_seen = Time.iso8601(entry["last"]) rescue nil
      return if last_seen && last_seen > now - 1.day
      entry["count"] = entry["count"].to_i + 1
      entry["last"]  = now.iso8601
    else
      ips[ip] = { "first" => now.iso8601, "last" => now.iso8601, "count" => 1 }
    end
    update_column(:ips, ips) # audit append — skip validations/callbacks
  end

  def google_connected?
    provider == "google_oauth2" && uid.present?
  end

  # The user has completed the self-custody export flow: they've been
  # shown their encrypted_web2_solana_private_key, copied it into a wallet
  # they control, and clicked through the prove-custody confirmation. From
  # this moment the server stops auto-signing on their behalf — every
  # managed-path call site (ContestsController#enter token path,
  # Solana::Vault#build_enter_contest_with_token, etc.) MUST check this
  # predicate first and refuse to sign if true.
  #
  # We do NOT yet delete the encrypted_web2_solana_private_key (decision
  # deferred — see docs/SELF_CUSTODY.md). The column is the behavior
  # gate; the key stays as an operator-side backup until a future sweep.
  def self_custodied?
    self_custodied_at.present?
  end

  # Web2 managed-withdraw eligibility — the single source of truth shared
  # between WalletsController#withdraw, the inline /wallet card, and the
  # /account "Cash out" shortcut button.
  #
  # The flow lets the server sign an SPL transfer from the user's
  # managed-wallet ATA → off-ramp provider (Stripe / Bridge / etc.). That
  # requires three things:
  #   - managed_wallet?    — there's an encrypted key the server can sign with
  #   - !self_custodied?   — the user hasn't taken custody; we still sign
  #   - !phantom_wallet?   — Phantom users cash out from their own wallet app;
  #                          no need to route them through our queue
  def can_use_managed_withdraw?
    managed_wallet? && !self_custodied? && !phantom_wallet?
  end

  # B4 / OPSEC-048: account freeze for chargeback / dispute / refund. While
  # frozen, the user can't enter contests, buy tokens, or withdraw. Existing
  # on-chain tokens stay where they are (irreversible) but become unspendable
  # via this app. Unfreezing for v1 = rails console: `user.unfreeze!`.
  def frozen?
    frozen_at.present?
  end

  def freeze_for_payment_risk!(reason:)
    return if frozen?
    update_columns(frozen_at: Time.current, frozen_reason: reason.to_s.first(255))
    Rails.logger.error "[opsec-048] user.frozen user_id=#{id} reason=#{reason}"
  end

  def unfreeze!
    update_columns(frozen_at: nil, frozen_reason: nil)
    Rails.logger.info "[opsec-048] user.unfrozen user_id=#{id}"
  end

  # OPSEC-045: rotate the session-binding token. Call after any action
  # that should invalidate other live sessions (email change today;
  # consider hooking on 2FA disable later). Returns the new token so
  # callers can update session[:session_token] in step.
  def regenerate_session_token!
    new_token = SecureRandom.hex(32)
    update_column(:session_token, new_token)
    new_token
  end

  def set_initial_session_token
    self.session_token ||= SecureRandom.hex(32)
  end

  def has_email?
    email.present?
  end

  # --- Solana wallet ---

  # Convenience — returns "primary" address (web3 preferred, fallback web2)
  def solana_address
    web3_solana_address || web2_solana_address
  end

  # TRUE when the account holds BOTH a managed web2 wallet and a linked web3
  # one. `solana_address` above resolves that pair by always preferring web3,
  # which is fine for "where do we send things" and NOT fine for "where are this
  # user's seeds" — the seeds may sit on whichever wallet earned them. Callers
  # that read balances use this to tell a trustworthy zero from an ambiguous one
  # (Tokens::LevelUpGrant#call).
  def combo_wallets?
    web2_solana_address.present? && web3_solana_address.present?
  end

  def solana_keypair
    return nil unless encrypted_web2_solana_private_key.present?
    Solana::Keypair.from_encrypted(encrypted_web2_solana_private_key)
  end

  def generate_managed_wallet!
    return if web2_solana_address.present?
    # Web3-only onboarding (NFL 2026 operator call — AppFlags.web3_only_onboarding?):
    # no custodial wallet is minted at signup at all. The account is created and
    # signed in exactly as before; it simply has no wallet until the user links
    # Phantom through the wallet-setup modal (WalletSetupPolicy decides when to
    # show it). Same shape as the OPSEC-044 admin rule below — "no managed
    # wallet" is an already-supported state (wallet_kind :none), which is why
    # this is a one-line early return rather than a flow change.
    return if AppFlags.web3_only_onboarding?
    # OPSEC-044: admins go web3-only. Server should never hold custodial keys
    # for accounts with elevated privileges — a managed wallet for an admin
    # combines the highest-value account with the largest decryption surface.
    # Admins link Phantom via the standard flow; if they need on-chain access
    # before linking, they have none until they do.
    return if admin?
    keypair = Solana::Keypair.generate
    update!(
      web2_solana_address: keypair.to_base58,
      encrypted_web2_solana_private_key: keypair.encrypt
    )
    # OPSEC-044: removed proactive EnsureAtaJob.perform_later(keypair.to_base58).
    # Pre-creating an ATA at signup spends admin SOL rent on every signup —
    # a sybil farm via solana_sessions#verify could drain admin SOL on
    # accounts that never deposit. ATAs are now created lazily by the code
    # paths that actually need them (Vault#fund_user, #transfer_from_user,
    # #transfer_spl all call ensure_ata internally before use).
    keypair
  end

  # --- Seeds (on-chain) ---
  # Seeds live on the UserAccount PDA (on-chain). 25 seeds per contest entry.
  # Level = (seeds / 100) + 1. UI-derived, no DB column.

  # SEEDS_PER_ENTRY removed in 2026-05-18 entry-tokens-onchain epic — seeds are now
  # awarded per the on-chain Season's seed_schedule. Use Solana::Vault#seeds_for_entry.
  SEEDS_PER_LEVEL = 100

  def self.level_for(seeds)
    (seeds / SEEDS_PER_LEVEL) + 1
  end

  def self.seeds_toward_next_level(seeds)
    seeds % SEEDS_PER_LEVEL
  end

  def self.seeds_progress_percent(seeds)
    (seeds_toward_next_level(seeds).to_f / SEEDS_PER_LEVEL * 100).round
  end

  def update_level_from_seeds!(seeds_total)
    return nil if seeds_total.nil?

    computed_level = self.class.level_for(seeds_total)
    leveled_up = computed_level != level
    # Cache the seed total (admin list display + sort) and bump level on a level
    # change. Write ONLY on change, via update_column(s) — this is a denormalized
    # mirror of on-chain state, so it skips validations/callbacks/updated_at
    # (avoids RecordInvalid on legacy rows + write churn on every award).
    if leveled_up
      update_columns(seeds: seeds_total, level: computed_level)
    elsif seeds != seeds_total
      update_column(:seeds, seeds_total)
    end
    # Returns the new level on a level-up, else nil (callers fire the level-up UI).
    leveled_up ? computed_level : nil
  end

  # --- Entry tokens (on-chain EntryTokenAccount PDAs, turf-vault v0.9.0+) ---
  # Balance comes from on-chain RPC; consumption happens atomically inside the
  # enter_contest_with_token Anchor instruction (no spend_entry_token! needed).
  #
  # 60s Rails.cache layer wraps the getProgramAccounts RPC because public
  # devnet rate-limits it to ~1/sec/IP and the navbar+modal+badge can all
  # request it in the same pageview. Cache key includes the deployed
  # program ID so a program-redeploy implicitly invalidates. Writers
  # (TokenPurchaseJob mint, enter_contest_with_token consume) should call
  # `User#bust_entry_tokens_cache!` after the chain TX confirms — that ONE call
  # clears both layers (see the method), which is what makes it a safe
  # instruction to give writers.
  #
  # THERE ARE TWO LAYERS, and this one wraps the other:
  #   #cached_entry_tokens      → "entry_tokens/v1/<prog8>/<addr>"  (here)
  #     └── Vault#list_entry_tokens → "entry_tokens:<addr>"         (the RPC layer)
  # The inner key is also what the navbar badge and the hold-for-free-entry CTA
  # read directly (ApplicationController#display_entry_token_count).

  def entry_tokens_cache_key
    "entry_tokens/v1/#{Solana::Config::PROGRAM_ID[0, 8]}/#{solana_address}"
  end

  # Per-request memoized AND Rails-cached for 60s. Returns the full list
  # (including consumed) so both #entry_token_balance and
  # #next_unconsumed_entry_token can derive from one RPC call.
  def cached_entry_tokens
    return @cached_entry_tokens if defined?(@cached_entry_tokens)

    @cached_entry_tokens =
      if solana_connected?
        Rails.cache.fetch(entry_tokens_cache_key, expires_in: 60.seconds) do
          Solana::Vault.new.list_entry_tokens(solana_address)
        end
      else
        []
      end
  rescue => e
    Rails.logger.warn "cached_entry_tokens fetch failed for user=#{id}: #{e.message}"
    @cached_entry_tokens = []
  end

  # Clears BOTH entry-token cache layers plus the per-request memos.
  #
  # It used to delete only the outer (User) key. The next read then re-entered
  # Vault#list_entry_tokens, hit its STILL-WARM "entry_tokens:<addr>" key, and
  # re-served the just-spent token as unconsumed for up to 60s — so the navbar
  # badge and the "Hold for Free Entry" CTA (which read that inner key directly)
  # kept promising a free entry the wallet could no longer honour, and a second
  # #prepare_entry re-picked the CONSUMED token and built a doomed
  # enter_contest_with_token (0x177f) instead of falling back to USDC.
  #
  # Both wallet addresses are cleared, not just #solana_address: a combo account
  # (managed + Phantom) can hold tokens under either, and #solana_address returns
  # only the Phantom one. Deleting a cold key is free, so the wide bust costs
  # nothing and removes a whole class of "busted the wrong address" bug.
  def bust_entry_tokens_cache!
    Rails.cache.delete(entry_tokens_cache_key)
    [web3_solana_address, web2_solana_address].compact_blank.uniq.each do |address|
      Rails.cache.delete(Solana::Vault.entry_tokens_cache_key(address))
    end
    remove_instance_variable(:@cached_entry_tokens) if defined?(@cached_entry_tokens)
    remove_instance_variable(:@entry_token_balance) if defined?(@entry_token_balance)
  end

  # Per-request memoized — views call this from the navbar, the entry-token
  # badge, and the action body all in the same render. The User instance is
  # the same `current_user` reference across the request, so the memo holds.
  def entry_token_balance
    @entry_token_balance ||= cached_entry_tokens.count { |t| !t[:consumed] }
  end

  # Returns the first unconsumed EntryTokenAccount PDA for this user, or nil.
  # Used by ContestsController#enter to decide between USDC-funded and token-funded entry paths.
  def next_unconsumed_entry_token
    cached_entry_tokens.find { |t| !t[:consumed] }
  end

  # Like #next_unconsumed_entry_token but scoped to a SPECIFIC wallet address.
  #
  # The web2 server-sign entry path (ContestsController#resolve_web2_entry_funding!)
  # signs the consume with the managed (web2) keypair, so it must only surface a
  # token the web2 address actually OWNS. #next_unconsumed_entry_token reads
  # #solana_address — web3-preferred for a combo (web2+web3) account — and
  # would mis-detect a web3-owned token the managed keypair can NOT sign for: a
  # doomed on-chain consume (owner != signer) that also masks an available USDC
  # fallback, hard-walling a combo user who could have paid. list_entry_tokens
  # memcmp-filters on owner == `address`, so this only ever returns web2-owned
  # tokens. When `address` IS #solana_address (pure web2, or the primary) reuse
  # the per-request memo; otherwise do a scoped on-chain lookup.
  def next_unconsumed_entry_token_for(address)
    return nil if address.blank?
    return next_unconsumed_entry_token if address == solana_address
    Solana::Vault.new.list_entry_tokens(address).find { |t| !t[:consumed] }
  rescue => e
    Rails.logger.warn "next_unconsumed_entry_token_for failed for user=#{id} addr=#{address}: #{e.message}"
    nil
  end

  private

  # Every account gets an auto-generated username — signup never has a
  # "pick a username" step (the username's master record is on-chain).
  def ensure_username
    return if username.present?
    return if assign_parked_identity && username.present?

    # Studio::UsernameGenerator emits "fruit-animal(-animal)" names that can
    # exceed the model's 30-char limit (length: { in: 3..30 }) — which
    # intermittently broke signups + CI (a generated name happened to be >30).
    # Reserved-prefix draws (e.g. a fruit starting with "mod…") are rejected
    # too — they'd fail #username_not_reserved and, later, the on-chain
    # create_user_account (6020 UsernameReserved). Prefer a clean in-range
    # draw; truncate as a deterministic backstop so a create never raises on
    # username length.
    candidate = (1..5).lazy.map { Studio::UsernameGenerator.generate.to_s }
                      .find { |n| n.length.between?(3, 30) && !User.reserved_username?(n) }
    self.username = (candidate || Studio::UsernameGenerator.generate.to_s)[0, 30]
  end

  def assign_parked_identity
    identity = User.parked_identity_for(email: email, wallet: web3_solana_address.presence || web2_solana_address)
    return false unless identity

    changed = false
    parked_role = identity[:role].presence
    if parked_role.present? && role != parked_role
      self.role = parked_role
      changed = true
    end

    parked_name = identity[:name].presence
    if parked_name.present? && (name.blank? || name == "anon")
      self.name = parked_name
      changed = true
    end

    parked_email = identity[:email].presence
    if parked_email.present? && email.blank? && User.where("LOWER(email) = ?", parked_email.downcase).where.not(id: id).none?
      self.email = parked_email
      changed = true
    end

    parked_username = identity[:username].presence
    return changed if parked_username.blank?
    return changed if username.present? && username.casecmp?(parked_username)
    return changed if User.reserved_username?(parked_username) && role != "admin"
    return changed unless User.username_available_for?(parked_username, user: self)

    self.username = parked_username
    true
  end

  # Eager on-chain UserAccount creation at signup — see CreateOnchainUserAccountJob.
  def enqueue_onchain_account_setup
    CreateOnchainUserAccountJob.perform_later(id)
  end

  def has_authentication_method
    return if email.present? || web3_solana_address.present? || (provider.present? && uid.present?)
    errors.add(:base, "Must have email, Solana address, or linked social account")
  end

  # Rails mirror of the on-chain reserved-prefix check (RESERVED_USERNAME_PREFIXES
  # — see the constant's comment for the turf-vault source). Runs only when the
  # username changes (see the validate declaration), so existing reserved rows
  # save fine on unrelated updates. Admins are exempt: they register reserved
  # names through the on-chain admin path (v0.25+), like the house "turf" row.
  def username_not_reserved
    return if username.blank? || admin?
    return unless User.reserved_username?(username)

    prefix = RESERVED_USERNAME_PREFIXES.find { |p| username.downcase.start_with?(p) }
    errors.add(:username, "starts with the reserved word \"#{prefix}\" — reserved names can't be registered on-chain. Please pick a different username.")
  end

  # Delegates to the shared User.valid_email? so the model, the magic-link
  # controller, and the client emailValidator all enforce ONE rule.
  def email_format
    return if email.blank?
    errors.add(:email, "is not a valid email address") unless User.valid_email?(email)
  end

  def set_name_parts
    parts = name.to_s.strip.split(" ")
    self.first_name = parts.first
    self.last_name = parts.last if parts.size > 1
  end

  def name_slug
    base = username.presence || name.presence || email.presence || solana_address.presence || "user"
    "#{base}-#{id}".downcase.gsub(/\s+/, "-")
  end

  # Re-run the slug builder now that the row HAS an id (see the after_create
  # declaration for why this is not already true).
  #
  # update_column, deliberately: no validations, no callbacks (Sluggable's
  # before_save would recurse), no updated_at churn on a row created microseconds
  # ago. It cannot collide with the unique index either — the id in the slug is
  # unique by construction, so the value it writes is unique by construction.
  def finalize_slug!
    expected = name_slug
    return if slug == expected

    update_column(:slug, expected)
  end
end
