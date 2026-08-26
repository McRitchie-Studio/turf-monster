class AccountsController < ApplicationController
  include UserMergeable
  include Solana::SessionAuth

  # session_state is callable by guests on purpose — if a tab's session
  # expired server-side, the client-side rehydrate (visibilitychange /
  # cross-tab broadcast) needs to GET the guest shape back to flip the
  # store. Otherwise auth-required would 302 → /login and the JS can't
  # parse the response.
  # confirm_email_change is authed by its signed token, not the session — the
  # link may be opened on a different device than the one logged in (mirrors
  # WalletExportsController#show).
  skip_before_action :require_authentication, only: [:session_state, :confirm_email_change, :apply_email_change]
  skip_before_action :require_profile_completion, only: [:show, :complete_profile, :save_profile, :session_state]

  # OPSEC-046 (Avi HIGH-2): an impersonating admin must NOT mutate the target's
  # identity / auth bindings — setting a first email, linking a wallet, changing
  # the username — because that creates PERSISTENT access that survives "Return"
  # and never appears in the ImpersonationLog. Entering contests (the intended
  # use) is unaffected. Wallet withdraw + key-export are blocked in their own
  # controllers; this covers the account-identity surface.
  before_action :block_account_mutation_while_impersonating,
                only: %i[update link_solana unlink_google set_inviter update_username confirm_username]

  def show
    @user = current_user
    # No server-side balance fetch: the render path is RPC-free by design
    # (perform_solana_preload no longer pulls wallet balances), so the
    # balance tiles render "—" placeholders. The layout's hydrateNavbar
    # fires refreshSession() (-> #session_refresh) on every page load —
    # filling the tiles' data-wallet-tile spans, the navbar, and
    # $store.session from chain — and the Refresh Wallet button re-pulls
    # the same endpoint on demand.
    #
    # Referral widget — share URL points at the canonical main contest
    # (admin-set via /admin/dashboard). SeasonConfig.main_contest masks
    # the explicit pick when it's settled/locked and falls back to the
    # most recent open contest; nil if nothing is open at all (the widget
    # then degrades to a root-path share URL).
    @referral_share_contest = SeasonConfig.main_contest
  end

  # Fresh on-chain state (USDC, free-entry tokens, seeds + level) in a
  # single JSON payload. The client-side refreshSession() helper calls
  # this after every on-chain success (entry confirm, token mint, token
  # consume, withdrawal, etc.) so the navbar balance, token badge, and
  # seeds bar can all converge to truth from one place — instead of each
  # success path having to know about three separate update mechanisms.
  #
  # This is a CLIENT-HYDRATE endpoint (refreshSession() calls it after every
  # on-chain success, and the navbar fires it on page load). Blocking RPCs are
  # acceptable here — the page already painted. perform_solana_preload covers
  # the cached token count + admin vault state; the wallet balances + seeds
  # sync are no longer preloaded (see ApplicationController), so this endpoint
  # fetches them explicitly and warms the navbar caches so subsequent renders
  # are warm.
  def session_refresh
    # fetch_navbar_hydrate does all the (blocking, off-render-path) on-chain
    # reads AND warms the navbar caches — including the entry-tokens cache the
    # navbar reads cache-first — so there's no separate perform_solana_preload
    # pass to do here.
    hydrate = current_user&.solana_connected? ? fetch_navbar_hydrate(current_user) : {}

    seeds = hydrate[:seeds].to_i
    # When the wallet-balances read flaked (nil), emit null instead of 0 so
    # the client can recognise "unknown" and preserve whatever value the
    # store last held. Tokens ride the same nil-means-flake contract now that
    # they come from the hydrate fetch (updateNavTokens leaves the prior badge
    # value on null instead of zeroing it). seeds defaults to 0.
    render json: {
      usdc:        hydrate[:usdc],
      usdt:        hydrate[:usdt],
      sol:         hydrate[:sol],
      tokens:      hydrate[:entry_token_count],
      seeds:       seeds,
      level:       User.level_for(seeds),
      toward_next: User.seeds_toward_next_level(seeds),
      progress:    User.seeds_progress_percent(seeds),
      level_up_token_pending: current_user.present? &&
        current_user.level > current_user.entry_tokens_granted_level
    }
  end

  # Lightweight session-state probe for client-side rehydration. Returns the
  # canonical wallet_context plus a fresh CSRF token so a tab returning from
  # background can detect server-side logout (verify_session_token gives 401)
  # OR get the current truth (this action returns guest/web2/web3 state) and
  # rotate its CSRF for the next POST. No DB writes; cheap to call.
  def session_state
    render json: client_session_payload.merge(csrf: form_authenticity_token)
  end

  def complete_profile
    @user = current_user
  end

  def save_profile
    @user = current_user
    avatar = params.dig(:user, :avatar)
    return render_profile_error if avatar.present? && !valid_image?(avatar)

    rescue_and_log(target: @user) do
      @user.update!(profile_params)

      # Usernames are auto-assigned at signup — this form just saves the avatar.
      target = session.delete(:return_to) || root_path

      respond_to do |format|
        format.html { redirect_to target, notice: "Profile updated!" }
        format.json { render json: { success: true, display_name: @user.display_name, redirect: target } }
      end
    end
  rescue StandardError
    render_profile_error
  end

  # Passwordless (Lazarus audit #4): changing an EXISTING email is now an
  # out-of-band confirmation, not an in-session re-auth. The old in-app
  # "confirm your current password" gate is gone (there is no password), and
  # the attack chain it left open — a hijacked session silently swapping the
  # email and then the wallet-export key — is closed by requiring the change
  # to be confirmed via a link sent to the CURRENT (pre-change) address.
  #
  #   - changing an existing email  → don't apply it; mint a signed token and
  #                                   email a confirm link to the current
  #                                   address. Other fields (name) still save.
  #   - setting the FIRST email      → apply directly (no prior address to
  #                                   protect) with email_verified_at: nil so
  #                                   the new address goes through the existing
  #                                   email_verification flow.
  #   - no email change              → apply normally.
  def update
    @user = current_user
    rescue_and_log(target: @user) do
      # Avatar saves through its own branch so the name/email update never
      # carries the attachment param (which, submitted empty, would purge it).
      if (avatar = params.dig(:user, :avatar)).present?
        if valid_image?(avatar)
          @user.avatar.attach(avatar)
          redirect_to account_path, notice: "Account updated."
        else
          redirect_to account_path, alert: "Use a PNG, JPG, or WebP under 8 MB.", status: :see_other
        end
        next
      end

      new_params = account_params
      new_email = new_params[:email].to_s.strip
      current_email = @user.email
      email_changing = new_email.present? && new_email.downcase != current_email.to_s.downcase

      if email_changing && current_email.present?
        # OOB confirm: apply every OTHER field now, but never the email itself.
        other_params = new_params.except(:email)
        @user.update!(other_params) if other_params.present?

        token = Rails.application.message_verifier(EMAIL_CHANGE_TOKEN_KEY).generate(
          { user_id: @user.id, new_email: new_email, current_email: current_email, requested_at: Time.current.to_i },
          expires_in: EMAIL_CHANGE_TOKEN_TTL
        )
        Studio::Email.deliver(UserMailer, :email_change_confirmation, @user, current_email, new_email, token, to: current_email, user: @user)

        # Signal the email-change-pending modal instead of a flash toast. The
        # /account page reads flash[:email_change_pending] into an inline JSON
        # script tag and opens the modal on load (see accounts/show.html.erb).
        # No :notice here — the modal replaces the toast for this case.
        flash[:email_change_pending] = { current_email: current_email, new_email: new_email }
        redirect_to account_path
      elsif email_changing
        # First email on the account — no prior address to protect. Apply
        # directly; the new address still has to be verified.
        @user.update!(new_params.merge(email_verified_at: nil))
        redirect_to account_path, notice: "Account updated. Verify your new email — link sent to #{@user.email}."
      else
        @user.update!(new_params)
        redirect_to account_path, notice: "Account updated."
      end
    end
  rescue StandardError => e
    flash.now[:alert] = "Failed to update account."
    render :show, status: :unprocessable_entity
  end

  # GET /account/email/confirm/:token
  #
  # Out-of-band confirmation of an email change (Lazarus audit #4). The link is
  # sent to the CURRENT (pre-change) address, so the holder of the account's
  # existing email is the one who authorizes the swap. The link may be opened
  # on a different device than the logged-in session, so authentication is
  # skipped (the signed token is the auth boundary — exactly the wallet-export
  # #show pattern).
  #
  # This GET only RENDERS the confirmation — it never mutates. A GET that
  # persisted an attacker-supplied address would let a link prefetcher / mail
  # security scanner (which issue GETs, not human clicks) auto-complete a
  # hijacked-session email takeover. The swap is the CSRF-protected POST below.
  # The token binds current_email; if the user's email has since changed (or a
  # newer change was confirmed first), the link is stale → 410.
  def confirm_email_change
    @email_change       = verify_email_change_token!(params[:token])
    @email_change_token = params[:token]
    # renders accounts/confirm_email_change
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render plain: "This email-change link is invalid or expired. Request a fresh one from your account page.", status: :gone
  rescue StandardError => e
    Rails.logger.warn "[email-change] confirm render failed: #{e.class}: #{e.message}"
    render plain: e.message, status: :gone
  end

  # POST /account/email/confirm/:token
  #
  # Applies the email change once the human confirms from the interstitial.
  # Re-verifies the token (it may have gone stale between render and submit),
  # swaps the email, and rotates the session token.
  def apply_email_change
    payload = verify_email_change_token!(params[:token])
    user = User.find(payload[:user_id])

    rescue_and_log(target: user) do
      old_email = user.email
      user.update!(email: payload[:new_email], email_verified_at: nil)
      # OPSEC-045: rotate the session token so any OTHER live session (e.g. a
      # hijacker who initiated the change) loses access the moment the legit
      # owner confirms from their inbox.
      user.regenerate_session_token!

      # OPSEC-046: heads-up to the OLD address that the change just landed — an
      # out-of-band signal if the change wasn't actually authorized.
      Studio::Email.deliver(UserMailer, :email_change_notification, user, old_email, user.email, to: old_email, user: user)

      # Reuse the existing email_verification mint + mailer so the user verifies
      # the NEW address through the established flow.
      verify_token = Rails.application.message_verifier(EmailVerificationsController::VERIFY_TOKEN_KEY).generate(
        { user_id: user.id, email: user.email, return_to: nil },
        expires_in: EmailVerificationsController::VERIFY_TOKEN_TTL
      )
      Studio::Email.deliver(UserMailer, :email_verification, user, verify_token, to: user.email, user: user)

      target = logged_in? ? account_path : signin_path
      redirect_to target, notice: "Email changed — verify your new address (link sent to #{user.email})."
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render plain: "This email-change link is invalid or expired. Request a fresh one from your account page.", status: :gone
  rescue StandardError => e
    Rails.logger.warn "[email-change] apply failed: #{e.class}: #{e.message}"
    render plain: e.message, status: :gone
  end

  def link_solana
    pubkey_b58 = verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session,
      expected_user_id: current_user.id  # OPSEC-005: session-bind the signature
    )

    rescue_and_log(target: current_user) do
      # Check if Solana wallet belongs to another user
      existing = User.from_solana_wallet(pubkey_b58)
      if existing && existing.id != current_user.id
        merge_users!(survivor: current_user, absorbed: existing)
        # The survivor now holds the wallet this request just proved, so it earns
        # the same brand stamp as the non-merge branch below.
        current_user.record_web3_authentication!(provider: params[:wallet_provider])
        # The account now holds a web3 wallet — the wallet-setup nudge is
        # satisfied, so drop it in the same breath as the link.
        clear_wallet_setup_state!
        return render json: { success: true, redirect: account_path, notice: "Accounts merged." }
      end

      current_user.update!(web3_solana_address: pubkey_b58)
      # Same stamp as the wallet LOGIN path — linking is a signature too, and a
      # user who links from /account and later signs in by email deserves the
      # same one-click step-up as one who logged in with the wallet directly.
      current_user.record_web3_authentication!(provider: params[:wallet_provider])
      clear_wallet_setup_state!
      # NO on-chain UserAccount is created here, deliberately. Creating one costs
      # ~0.00182 SOL of ADMIN rent and is PERMANENT — nothing in turf-vault closes
      # a UserAccount — while this endpoint is reachable by any signed-in user with
      # a freshly generated keypair. Keypairs are free and the user holds the key,
      # so `verify_solana_signature!` passes every time: an eager create here bills
      # admin SOL per REQUEST rather than per user, bounded only by a 5/min/IP
      # brute-force throttle (rack_attack.rb:48). That is OPSEC-044 exactly — the
      # proactive EnsureAtaJob was removed from signup for this reason (user.rb:534)
      # — and it is cheaper to abuse here, needing only a new keypair rather than a
      # new account.
      #
      # The remedy is OPSEC-044's verbatim: create it lazily, from the paths that
      # actually need it. They already do — entry.rb:302 before a contest entry,
      # stripe_deposit_job.rb:51 before a deposit, contests_controller.rb:746 and
      # :1550 in the entry preamble — which is precisely when a user starts earning
      # seeds. A user who links a wallet and never plays has no seeds to grant, and
      # Tokens::LevelUpGrant already models that cold read as first-class
      # (:user_account_missing), loudly.
      render json: { success: true, redirect: account_path }
    end
  rescue Solana::AuthVerifier::VerificationError => e
    render json: { error: e.message }, status: :unauthorized
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def unlink_google
    rescue_and_log(target: current_user) do
      current_user.update!(provider: nil, uid: nil)
      redirect_to account_path, notice: "Google account unlinked."
    end
  rescue StandardError => e
    redirect_to account_path, alert: "Failed to unlink Google."
  end

  def set_inviter
    return render json: { ok: true } if current_user.invited_by_id.present?

    inviter = User.find_by(slug: params[:inviter_slug])
    return render json: { error: "not found" }, status: :not_found unless inviter
    return render json: { error: "self" }, status: :unprocessable_entity if inviter.id == current_user.id

    rescue_and_log(target: current_user) do
      current_user.update!(invited_by_id: inviter.id)
      render json: { ok: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # OPSEC-007: removed `update_level` action. Previously accepted client-supplied
  # `seeds_total` and persisted level from it — trivial to inflate via curl. The
  # navbar already reads on-chain seeds via `seedsNavbar` localStorage written
  # by `confirm_onchain_entry`'s response (authoritative server figure). The
  # cached `users.level` column is now best-effort display only; recompute
  # server-side from `Solana::Vault#sync_balance` when truly needed.

  # On-chain username edit. Custodial (managed) wallets: the server co-signs
  # set_username immediately. Phantom wallets: returns a partial TX for the
  # wallet to co-sign, confirmed via #confirm_username.
  #
  # Wire contract is studio-engine's leveling-activity NEUTRAL contract (the modal
  # is engine studio/modals/blocks/_change_username): the request posts { value },
  # responses are { status: "saved" | "needs_step" | "error", ... }. The on-chain
  # surface is UNCHANGED — set_username / build_set_username / the managed keypair /
  # TxVerifier all still live here; the engine only ferries an OPAQUE challenge/proof
  # to TM's finalize_hook (window.tmUsernameFinalize). No signing/keys leave TM.
  def update_username
    @user = current_user
    # Engine posts { value }; accept the legacy { username } for one deploy so a
    # page loaded before this ship still renames (retryable, no funds at risk).
    new_username = (params[:value].presence || params[:username]).to_s.strip
    @user.username = new_username

    # Server-side mirror of the UI gate (modals/_username.html.erb +
    # User#can_change_username?). Belt-and-suspenders so a direct POST
    # can't bypass the "enter a contest first" lock.
    unless @user.can_change_username?
      reason = @user.solana_connected? ? "Enter a contest first to unlock username changes." : "No wallet on this account."
      return render json: { status: "error", message: reason }, status: :forbidden
    end

    unless @user.valid?
      return render json: { status: "error", message: @user.errors.full_messages.first }, status: :unprocessable_entity
    end

    # Self-custodied users (task #11) hold their own key — the server must
    # NOT auto-sign for them, even though we still have the encrypted key
    # on file as backup. Route them through the same co-sign path Phantom
    # users use; they sign the partial TX with the wallet they imported
    # into during the export flow.
    if @user.phantom_wallet? || @user.self_custodied?
      # Phantom / self-custody: hand the client a partial set_username TX to co-sign.
      # `challenge` is that base64 TX — an opaque blob the engine hands straight to
      # TM's finalize_hook; the sign/broadcast happens entirely client-side in TM.
      result = Solana::Vault.new.build_set_username(@user.solana_address, new_username)
      render json: {
        status: "needs_step",
        challenge: result[:serialized_tx],
        token: sign_username_payload(new_username)
      }
    else
      # Custodial: the server co-signs with the managed keypair, then mirrors to the DB.
      rescue_and_log(target: @user) do
        Solana::Vault.new.set_username(@user.solana_address, new_username, user_keypair: @user.solana_keypair)
        @user.save!
        seeds = grant_first_username_seeds(@user)
        render json: { status: "saved", username: @user.username }.merge(seeds || {})
      end
    end
  rescue StandardError => e
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  # Phantom username edit, step 2: the wallet co-signed + broadcast the
  # set_username TX; verify it on-chain (OPSEC-010), then mirror to the DB.
  # The engine finalize step posts { token, proof }; `proof` is the tx signature
  # TM's finalize_hook returned (legacy { tx_signature } accepted for one deploy).
  def confirm_username
    @user = current_user
    payload = verify_username_payload(params[:token])
    raise "Token issued for a different account" unless payload[:user_id] == @user.id
    new_username = payload[:username]

    user_pda_b58 = Solana::Keypair.encode_base58(
      Solana::Vault.new.user_account_pda(@user.solana_address).first
    )
    Solana::TxVerifier.verify!(
      signature: (params[:proof].presence || params[:tx_signature]),
      instruction_name: "set_username",
      signer_pubkey: @user.solana_address,
      writable_pubkey: user_pda_b58
    )

    rescue_and_log(target: @user) do
      @user.update!(username: new_username)
      seeds = grant_first_username_seeds(@user)
      render json: { status: "saved", username: @user.username }.merge(seeds || {})
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    render json: { status: "error", message: "Rename expired — please try again." }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { status: "error", message: e.message }, status: :unprocessable_entity
  end

  # POST /account/initiate_wallet_export
  #
  # Stage 1 of the self-custody export flow. Validates eligibility, stamps
  # export_initiated_at, mints a 30-min signed token, and emails the user a
  # magic link to /account/wallet/export/:token (rendered by
  # WalletExportsController#show — Stage 2).
  #
  # Eligibility:
  #   - must be a managed-wallet user (admins are blocked at sign-up; users
  #     with a Phantom wallet linked have no server-held key to export)
  #   - must not be already self_custodied? (one-way flow)
  #   - must have a verified email (we won't email a magic link to an
  #     unverified address)
  #
  # Passwordless (Lazarus audit #4): the old "entered password within the last
  # 5 min" gate is removed — there is no password. The emailed reveal token
  # IS the out-of-band lock (sent to the verified address, 30-min single-use),
  # so requiring a password here would have permanently locked passwordless
  # (magic-link / Google) managed users out of self-custody. The verified-email
  # requirement above is the standing re-auth factor.
  def initiate_wallet_export
    # OPSEC-046: never let an impersonating admin export a user's private key.
    # Hard stop before any token mint / email send — defense in depth.
    return redirect_to account_path, alert: "Wallet export is disabled while acting as another user." if impersonating?
    return render_export_error(:forbidden, "Self-custody export is only available for managed-wallet accounts.") unless current_user.managed_wallet?
    return render_export_error(:forbidden, "Wallet is already self-custodied.") if current_user.self_custodied?
    return render_export_error(:unprocessable_entity, "Add and verify an email address before exporting your wallet.") if current_user.email.blank? || current_user.email_verified_at.blank?

    current_user.update!(export_initiated_at: Time.current)

    token = Rails.application.message_verifier(WALLET_EXPORT_TOKEN_KEY).generate(
      { user_id: current_user.id, email: current_user.email, initiated_at: current_user.export_initiated_at.to_i },
      expires_in: WALLET_EXPORT_TOKEN_TTL
    )
    Studio::Email.deliver(UserMailer, :wallet_export, current_user, token, to: current_user.email, user: current_user)

    Rails.logger.info "[wallet-export] initiated user=#{current_user.id} email=#{current_user.email}"
    render json: { success: true, message: "Magic link sent. Check #{current_user.email}." }
  rescue StandardError => e
    Rails.logger.error "[wallet-export] initiate failed user=#{current_user.id}: #{e.class}: #{e.message}"
    render_export_error(:unprocessable_entity, "Could not send the export link. Please try again.")
  end

  private

  # Signed token for the wallet-export magic link. Distinct key from
  # email-verification so a stolen email-verify token can't be reused for
  # the more destructive wallet-export flow.
  WALLET_EXPORT_TOKEN_KEY = "wallet_export_v1".freeze
  WALLET_EXPORT_TOKEN_TTL = 30.minutes

  # Signed token for the out-of-band email-change confirmation (Lazarus audit
  # #4). Distinct key so it can't be cross-used with the verify / export
  # tokens. Sent to the CURRENT address; binds current_email so it goes stale
  # the moment the email actually changes. Mirrors the wallet-export token
  # encoding + route-constraint style (raw message_verifier blob, route
  # `constraints: { token: %r{[^/]+} }, format: false`).
  EMAIL_CHANGE_TOKEN_KEY = "email_change_v1".freeze
  EMAIL_CHANGE_TOKEN_TTL = 30.minutes

  def render_export_error(status, message)
    render json: { success: false, error: message }, status: status
  end

  # Verify + freshness-check an email-change token, for both the GET interstitial
  # and the POST apply. Raises MessageVerifier::InvalidSignature for a bad or
  # expired blob; raises for an unknown account or a STALE link — the account's
  # current email no longer matches the address the token was minted against
  # (already changed, or a competing confirm won first). Returns the
  # indifferent-access payload.
  def verify_email_change_token!(token)
    payload = Rails.application.message_verifier(EMAIL_CHANGE_TOKEN_KEY).verify(token).with_indifferent_access
    user = User.find_by(id: payload[:user_id])
    raise "Unknown account" unless user
    raise "This email-change link is no longer valid" unless user.email.to_s.downcase == payload[:current_email].to_s.downcase
    payload
  end

  # OPSEC-046 (Avi HIGH-2): block identity/auth-binding mutations while an admin
  # is impersonating. JSON → 403; HTML → bounce to the account page.
  def block_account_mutation_while_impersonating
    return unless impersonating?

    respond_to do |format|
      format.json { render json: { error: "Account changes are disabled while acting as another user." }, status: :forbidden }
      format.any  { redirect_to account_path, alert: "Account changes are disabled while acting as another user." }
    end
  end


  # :avatar is saved by the dedicated branch in #update and by #save_profile —
  # not permitted here, so a name/email save can never purge it (see #update).
  def account_params
    params.require(:user).permit(:name, :email)
  end

  def profile_params
    params.require(:user).permit(:avatar)
  end

  # Signed round-trip token so the username can't be swapped between the
  # prepare (#update_username) and confirm (#confirm_username) steps.
  # First MANUAL username change -> one-time 35-seed bonus. Sets
  # username_changed_at (the once-ever marker) and grants 35 seeds on-chain;
  # returns the seeds StateFanout payload, or nil if not the first change /
  # deferred. The on-chain SeedGrant[username] init-guard is the hard lock, so
  # a deferred grant (pre-deploy) is backfillable without risk of double-pay.
  def grant_first_username_seeds(user)
    return nil unless user.username_changed_at.nil?
    user.update_column(:username_changed_at, Time.current)
    return nil unless user.solana_connected?

    vault = nil
    vault = Solana::Vault.new
    result = vault.grant_seeds(
      wallet_address: user.solana_address, amount: vault.seeds_for_quest(:username), kind: :username
    )
    {
      seeds_earned: result[:seeds_earned],
      seeds_total:  result[:seeds_total],
      seeds_level:  result[:seeds_level]
    }
  rescue => e
    if seed_grant_already_exists_error?(e)
      payload = current_seed_payload(user, vault: vault)
      if payload
        Rails.logger.info "[quest][username] seed grant already existed for user=#{user.id}; returned seed snapshot"
        return payload
      end
    end

    Rails.logger.warn "[quest][username] seed grant deferred for user=#{user.id} " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    nil
  end

  def seed_grant_already_exists_error?(error)
    message = "#{error.class}: #{error.message}"
    message.match?(/custom program error:\s*0x0\b|account .*already in use|already initialized|AccountAlreadyInitialized/i)
  end

  def current_seed_payload(user, vault: nil)
    return nil unless user.solana_connected?

    vault ||= Solana::Vault.new
    seeds_total = vault.sync_balance(user.solana_address)&.dig(:seeds).to_i
    {
      seeds_total: seeds_total,
      seeds_level: User.level_for(seeds_total),
      seeds_reconciled: true
    }
  rescue => e
    Rails.logger.warn "[quest][username] seed snapshot failed for user=#{user.id} " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    nil
  end

  def sign_username_payload(username)
    Rails.application.message_verifier(:account_username_change)
         .generate({ user_id: current_user.id, username: username }, expires_in: 10.minutes)
  end

  def verify_username_payload(token)
    Rails.application.message_verifier(:account_username_change)
         .verify(token).with_indifferent_access
  end

  # Friendly (title, message) for a profile-save failure. A username
  # collision is a normal user error, so it gets a specific, non-scary toast
  # rather than the raw "Validation failed: …" exception message.
  def profile_error_toast
    username_taken = @user.errors.details[:username]&.any? { |d| d[:error] == :taken }
    if username_taken
      ["Username Taken", "Please choose a new username"]
    else
      ["Couldn't Save Profile", @user.errors.full_messages.first || "Please try again."]
    end
  end

  # Renders the complete-profile page (html) or a JSON error for the avatar /
  # profile save paths — shared by #save_profile's validation guard and rescue.
  def render_profile_error
    title, message = profile_error_toast
    respond_to do |format|
      format.html do
        @profile_error_title = title
        @profile_error_message = message
        render :complete_profile, status: :unprocessable_entity
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

end
