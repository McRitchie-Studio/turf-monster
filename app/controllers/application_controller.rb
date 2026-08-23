class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  # Detection, the geo_* helpers, and require_geo_allowed all come from the
  # engine now (studio-engine >= 0.57, docs/GEO.md). This app keeps only the
  # DECISION of what to lock — see the before_actions on ContestsController,
  # EntriesController, WalletsController and Cdp::RampSessionsController.
  include Studio::GeoDetection

  # Guard the JS-heavy *interactive* app against ancient browsers — but NOT the
  # public, shareable, crawlable pages. `allow_browser` 406s any UA it deems
  # non-modern, and link-preview fetchers (iMessage/Apple especially) present a
  # pinned OLD-Safari UA → they'd get 406 and never see the og tags, so shared
  # links never unfurl. Skipping these public GET pages lets previews work AND
  # stops bouncing a real visitor who lands on the funnel from an older phone.
  allow_browser versions: :modern, unless: :public_preview_request?

  before_action :verify_session_token  # OPSEC-045
  before_action :set_current_context
  before_action :capture_reference
  # Stamp activity right after auth resolves, BEFORE the geo/profile redirects —
  # an after_action is skipped when those before_actions halt the chain, so a
  # genuinely-active but redirected user would never get stamped.
  before_action :touch_last_seen
  before_action :require_profile_completion
  before_action :preload_navbar_solana_data
  helper_method :display_balance, :display_seeds_data, :display_entry_token_count, :onchain_session?, :wallet_context, :client_session_payload, :true_user, :impersonating?

  # OPSEC-045: extend the engine's set_app_session to also bind a per-user
  # session_token in the cookie. The verify_session_token before_action
  # compares the cookie token to user.session_token on every request —
  # mismatch → forced logout, which is how password rotation kicks out
  # stolen sessions.
  def set_app_session(user)
    super
    session[:session_token] = user.session_token
    # The onchain-session flag is a Phantom-wallet-signature privilege. Reset
    # it on every login so a stale flag from an earlier Phantom session can't
    # leak into a later email/Google login (which would make ContestsController
    # #enter demand a wallet signature). SolanaSessionsController#verify calls
    # set_app_session and then re-grants the flag for genuine wallet auth.
    session.delete(:onchain)
    # OPSEC-046: a fresh login must never inherit a prior impersonation — e.g. a
    # second admin re-authing (OAuth/wallet, which don't reset_session) over a
    # live impersonation on a shared browser. Logout already clears these.
    session.delete(:impersonated_user_id)
    session.delete(:true_admin_id)
    session.delete(:impersonation_started_at)
  end

  # Clear the onchain flag on logout too, alongside the engine's session wipe.
  def clear_app_session
    super
    session.delete(:onchain)
  end

  # Format-aware override of Studio::ErrorHandling#require_authentication.
  # The engine version unconditionally `redirect_to login_path`, which makes
  # Rails return 406 Not Acceptable for any AJAX request with
  # `Accept: application/json` (the HTML login page doesn't match the
  # requested format). The JS layer (solana_utils.authedFetch) already
  # knows how to handle a clean 401 — it opens the login modal — so emit
  # that for JSON/Turbo-Stream requests and keep the HTML redirect for
  # full-page navigations.
  def require_authentication
    return if logged_in?

    respond_to do |format|
      format.html         { redirect_to signin_path }
      format.json         { render json: { error: "unauthenticated" }, status: :unauthorized }
      format.turbo_stream { head :unauthorized }
      format.any          { head :unauthorized }
    end
  end

  # ── Age attestation (underwriting compliance, 2026-06) ────────────────────
  # Every account-creation flow (magic link, Google OAuth, Solana wallet,
  # legacy POST /signup) must carry an affirmative legal-age attestation
  # before a User row is created. Existing users grandfather (login paths
  # never check). Shown to the user when a signup arrives without it.
  AGE_ATTESTATION_ERROR = "Please confirm you are of legal age to play " \
                          "skill-based contests in your state before creating an account.".freeze

  private

  # True only for an affirmative checkbox value ("1", "true", true). Each
  # signup controller reads its own source (params, omniauth.params, or the
  # MagicLink row) and funnels through this single truthiness rule.
  def age_attestation_given?(value = params[:age_attestation])
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  # Whether account creation requires the legal-age attestation at all —
  # flag-gated (parked off for the first contest; see AppFlags). Every
  # signup-path rejection is `if age_attestation_required? &&
  # !age_attestation_given?`, and age_attested_at stamping is gated on
  # required? too, so a flag-off signup never records an attestation the
  # user wasn't shown.
  def age_attestation_required?
    AppFlags.age_attestation?
  end

  # Entry-time age gate (ENABLE_AGE_GATE). True when this user must verify their
  # date of birth before their FIRST contest entry. Once verified
  # (age_attested_at present), they pass forever. The entry controllers check
  # this BEFORE any payment; AgeVerificationsController clears it.
  def age_gate_required?
    AppFlags.age_gate?
  end

  # True iff the entry flow should block THIS user pending DOB verification.
  def age_verification_pending?
    age_gate_required? && current_user.present? && current_user.age_attested_at.blank?
  end
  helper_method :age_gate_required?, :age_verification_pending?

  # ── Wallet setup (web3-only onboarding, 2026-08) ───────────────────────────
  # Two session keys, doing two different jobs:
  #
  #   session[:wallet_setup]        — STATE. The authoritative WalletSetupPolicy
  #                                   verdict, computed ONCE at sign-in (it can
  #                                   cost a USDC balance RPC) and read for free
  #                                   on every later render.
  #   session[:wallet_setup_prompt] — ONE-SHOT. "Open the modal on the next
  #                                   render." Survives both auth shapes: the
  #                                   magic-link redirect AND the Google popup,
  #                                   whose opener reloads the page rather than
  #                                   redirecting (so flash would be a coin flip).
  #
  # Called from every auth-success path right after set_app_session.
  def record_wallet_setup_state!(user, prompt: true)
    required = WalletSetupPolicy.required_for?(user)
    session[:wallet_setup] = required
    session[:wallet_setup_prompt] = true if required && prompt
    required
  end

  # Cleared when the user actually links a wallet (SolanaSessionsController
  # #verify), so the nudge stops the moment it is satisfied.
  def clear_wallet_setup_state!
    session.delete(:wallet_setup)
    session.delete(:wallet_setup_prompt)
    session.delete(:onboarding_prompt)
    # A wallet signature IS the step-up. Dropping the armed prompt here (rather
    # than letting the layout consume it) is what stops the modal flashing on the
    # page a successful wallet login lands on — the prompt was armed by the
    # earlier web2 auth in this same browser session.
    session.delete(:web3_step_up_prompt)
  end

  # ── The post-auth onboarding chain (2026-08) ───────────────────────────────
  #
  # ONE call at every auth success, replacing the wallet-only prompt as the
  # thing that decides what the user sees next. It still records the wallet
  # STATE (session[:wallet_setup]) because the entry gate reads that on every
  # later render — the chain is about what we ASK, the state is about what we
  # ENFORCE, and they are deliberately separate.
  #
  # Signup and login arm the SAME chain: every step is outstanding-or-not on the
  # account's own state, so no caller has to say which it is. (It used to take a
  # `welcome:` flag for the celebratory first card — the one step that could not
  # be derived from the record. That card is retired, and the flag went with it.)
  # Returns the ordered steps it armed, so a caller can ask what the user is
  # about to be shown instead of re-deriving it from a boolean.
  def record_onboarding_state!(user)
    record_wallet_setup_state!(user, prompt: false)
    record_web3_step_up_state!(user)
    steps = onboarding_steps_for(user)
    # One-shot, and it carries the STEPS rather than a bare boolean so the
    # client walks exactly what the server resolved. Rides the session (not the
    # flash) because the Google popup never redirects — its opener reloads, and a
    # flash would be consumed by whichever render landed first.
    session[:onboarding_prompt] = steps.map(&:to_s) if steps.any?
    steps
  end

  # ── The web3 step-up prompt (2026-08) ──────────────────────────────────────
  #
  # Armed at the same auth-success seam as the onboarding chain, and for the
  # same reason it rides the SESSION rather than the flash: the Google popup
  # never redirects — its OPENER reloads — so a flash would be consumed by
  # whichever render landed first.
  #
  # This is NOT a chain step, and keeping it out of OnboardingFlow is deliberate.
  # That service answers "what is this ACCOUNT still missing" and its cards carry
  # a 1-of-3 progress pill; a step-up asks "what does this SESSION still owe",
  # of a user whose account is already complete. Folding it in would put a
  # returning wallet owner at "step 1 of 3" of an onboarding they finished
  # months ago. It opens FIRST and hands off to the chain on dismissal — see the
  # driver in layouts/application.html.erb.
  #
  # A fresh SessionContext, not the memoized #wallet_context: this runs
  # immediately after set_app_session swapped the session's identity, and the
  # memo may already hold the PREVIOUS viewer from earlier in the request.
  def record_web3_step_up_state!(user)
    session.delete(:web3_step_up_prompt)
    mode   = SessionContext.new(user: user, onchain_session: onchain_session?).mode
    policy = Web3StepUpPolicy.new(user, session_mode: mode)
    return false unless policy.required?

    # Carries the remembered wallet with it so the render does not have to
    # re-derive it — the same shape the modal reads as props.
    session[:web3_step_up_prompt] = policy.to_h.transform_keys(&:to_s)
    true
  end

  # Arm the step-up card for a user who is NOT (yet) signed in.
  #
  # The Google-collision case: a self-custody account presented a Google identity
  # at the front door. There is no session to inspect — the request is
  # unauthenticated by definition — so the session-mode question
  # record_web3_step_up_state! asks does not apply, and the answer it would
  # return (:guest, therefore "required") would be right for the wrong reason.
  # State the fact directly instead: this account is self-custodied and a web2
  # credential just tried to speak for it.
  #
  # Returns false and arms nothing for an account with no wallet, so a caller
  # cannot accidentally show the card to a user it makes no sense to.
  def arm_web3_step_up_for(user)
    return false unless user.respond_to?(:phantom_wallet?) && user&.phantom_wallet?

    policy = Web3StepUpPolicy.new(user, session_mode: :web2)
    session[:web3_step_up_prompt] = policy.to_h.transform_keys(&:to_s)
    true
  end

  # One-shot read: the step-up payload for the render right after a web2 auth
  # success, else nil. Deleting on read is what stops the modal re-opening on
  # every later page view of a session that chose to dismiss it.
  def consume_web3_step_up_prompt
    payload = session.delete(:web3_step_up_prompt)
    return nil if payload.blank?

    payload.symbolize_keys.slice(:provider, :providerLabel, :walletHint)
  end
  helper_method :consume_web3_step_up_prompt

  # Render-path predicate for the ADVISORY banner/CTA case: this session is web2
  # but the account is self-custodied. RPC-free (see Web3StepUpPolicy), so it is
  # safe to ask on any render — unlike the one-shot above, this stays true for
  # the whole session and is what a "Sign with your wallet" affordance keys on.
  def web3_step_up_required?
    Web3StepUpPolicy.required_for?(current_user, session_mode: wallet_context.mode)
  end
  helper_method :web3_step_up_required?

  def onboarding_steps_for(user)
    OnboardingFlow.steps_for(
      user,
      skipped_first_name: session[:onboarding_skipped_first_name] == true,
      age_gate_enabled: age_gate_required?
    )
  end

  # One-shot read: the ordered step list for the render right after auth success,
  # else nil. Deleting on read is what keeps the chain from re-opening on every
  # later page view.
  def consume_onboarding_prompt
    steps = session.delete(:onboarding_prompt)
    return nil if steps.blank?

    Array(steps).map(&:to_s) & OnboardingFlow::STEPS.map(&:to_s)
  end
  helper_method :consume_onboarding_prompt

  # RENDER-PATH SAFE — never issues a Solana RPC.
  #
  # Phantom linked and no-wallet-at-all are both decidable from columns alone.
  # Only the managed-wallet case needs a balance, and that verdict was recorded
  # at sign-in; when it is absent (a session predating this deploy, or a path
  # that never computed it) we fail OPEN and stay quiet rather than nag a user
  # who may well be funded — the entry gate still refuses them server-side.
  def wallet_setup_required?
    return false if current_user.blank?
    # Same flag gate as WalletSetupPolicy — with web3-only onboarding off,
    # nothing here fires (see the policy's comment for why that matters).
    return false unless AppFlags.web3_only_onboarding?
    return false if current_user.phantom_wallet?
    return true unless current_user.managed_wallet?

    session[:wallet_setup] == true
  end

  # One-shot read: true once, for the render right after auth success.
  def consume_wallet_setup_prompt?
    session.delete(:wallet_setup_prompt) == true
  end
  helper_method :wallet_setup_required?, :consume_wallet_setup_prompt?

  # Public, crawlable GET pages that must unfurl in link previews (and never
  # 406 a visitor). These carry og/twitter tags and are the URLs people paste
  # into Messages/Slack/social: the marketing funnel + the public contest reads.
  # The interactive/authenticated app still gets the allow_browser guard.
  def public_preview_request?
    # HEAD is a bodyless GET — link-preview scanners (SafeLinks, iMessage,
    # Slack/social unfurlers) issue HEAD, so it must clear this guard exactly
    # like GET or those previews 406. (Brakeman VerbConfusion: request.get?
    # is false for HEAD even though HEAD routes like GET.)
    return false unless request.get? || request.head?
    return true if controller_name == "landing_pages"
    # Static legal/compliance pages (terms, privacy, about, contact,
    # responsible-gaming, state-eligibility): pasted into emails, merchant
    # applications, and crawled by underwriters' site scanners — they must
    # never 406 a preview fetcher or an old browser.
    return true if controller_name == "pages"
    controller_name == "contests" && action_name.in?(%w[show world_cup index live])
  end

  # Stamp the REAL logged-in user's last activity (admin dashboard "by recent
  # session"). Throttled to one write per 5 min via update_column (no callbacks,
  # no updated_at churn) so it's cheap on the hot path; uses true_user so admin
  # impersonation never bumps the impersonated user's activity. Never raises.
  LAST_SEEN_THROTTLE = 5.minutes
  def touch_last_seen
    user = true_user
    return unless user
    return if user.last_seen_at && user.last_seen_at > LAST_SEEN_THROTTLE.ago

    user.update_column(:last_seen_at, Time.current)
  rescue => e
    Rails.logger.warn("[last_seen] #{e.class}: #{e.message}")
  end

  # ── Admin impersonation (OPSEC-046) ────────────────────────────────────────
  # An admin can "act as" a non-admin user for support / migration / a prod
  # smoke test. The admin's REAL session (Studio.session_key + :session_token)
  # is left untouched; only current_user resolution is layered on top. See
  # Admin::ImpersonationsController + the _impersonation_banner partial.
  # Truly functional ONLY for web2/managed users (the server signs with their
  # managed key); web3/Phantom targets are debug/read-only — no key to borrow.
  IMPERSONATION_MAX_MINUTES = 30

  # The real session owner — always the logged-in admin, never the impersonated
  # user. The OPSEC-045 token check + the admin gate bind to THIS.
  def true_user
    return @true_user if defined?(@true_user)
    @true_user = User.find_by(id: session[Studio.session_key])
  end

  # Overrides Studio::ErrorHandling#current_user: resolves to the impersonated
  # target while impersonating, else the true admin.
  def current_user
    return @current_user if defined?(@current_user)
    @current_user = impersonating? ? User.find_by(id: session[:impersonated_user_id]) : true_user
  end

  # Active only when a target is set, the real user is an admin, the target
  # exists + is NOT an admin + isn't the admin themselves, and the window
  # hasn't expired. Any failed guard transparently falls back to the admin.
  def impersonating?
    return @impersonating if defined?(@impersonating)
    @impersonating = compute_impersonating?
  end

  def compute_impersonating?
    imp = session[:impersonated_user_id]
    return false if imp.blank?
    return false unless true_user&.admin?

    # Fail closed: a blank/unparseable start time = expired, not "never expires".
    started = session[:impersonation_started_at]
    return false if started.blank? || Time.zone.parse(started.to_s) < IMPERSONATION_MAX_MINUTES.minutes.ago

    target = User.find_by(id: imp)
    target.present? && !target.admin? && target.id != true_user.id
  rescue
    false
  end

  # Bounce an already-authenticated viewer away from the auth-entry GET pages
  # (the /login + /signup form renders). A logged-in user landing on "Sign in
  # to play" is a dead end — send them to their account instead. Honours a
  # `?return_to` param if one is supplied (same key the login flow uses), but
  # only for in-app relative paths so it can't be used as an open-redirect.
  #
  # Apply this only to the form-render `:new` actions. It must NOT guard the
  # mid-auth callbacks (magic-link consume, OmniAuth callback, solana verify,
  # wallet-link landing, the POST create actions) — those legitimately run
  # while a session is being established and would be hijacked by a redirect.
  def redirect_if_authenticated
    return unless logged_in?

    redirect_to safe_return_to || account_path
  end

  # A `return_to` is honoured only when it's a relative, single-leading-slash
  # path (no scheme/host) — otherwise we ignore it to avoid open redirects.
  def safe_return_to
    target = params[:return_to].presence
    return nil unless target
    return nil unless target.start_with?("/") && !target.start_with?("//")

    target
  end

  # Populates Current.* for the request lifecycle so OutboundRequestLogger can
  # attribute Stripe / Solana calls back to the user without param threading.
  def set_current_context
    Current.user = current_user if logged_in?
    # OPSEC-046: real actor behind an impersonated session. Request-scoped, so
    # outbound calls in a background job spawned mid-impersonation won't carry it
    # (the in-request fund-touch — contest entry — is stamped; jobs are not).
    Current.true_admin = true_user if impersonating?
  rescue
    nil # context is best-effort; never break the request path
  end

  # Funnel/campaign attribution. Captures a `?reference=` URL param into a
  # cookie on first touch (never overwritten) so it survives the journey to
  # signup, where it's written onto the new user across all auth paths.
  # Landing pages also seed this cookie with their slug — see
  # LandingPagesController#show.
  def capture_reference
    return if params[:reference].blank?
    return if cookies[:reference].present?

    cookies[:reference] = { value: params[:reference].to_s.first(64), expires: 30.days }
  end

  # OPSEC-045: enforces session-token binding. Runs early so a stale session
  # gets cleared before any downstream code reads current_user. Binds to
  # true_user (the real session owner), NOT current_user — admin impersonation
  # leaves the admin's cookie token in place while current_user resolves to the
  # target, so checking the target's token here would force-logout every request.
  def verify_session_token
    return unless true_user
    user_token   = true_user.session_token
    cookie_token = session[:session_token]

    return if user_token.present? && user_token == cookie_token

    Rails.logger.info("[opsec-045] session_token mismatch user_id=#{true_user.id} — forcing re-login")
    @current_user = nil
    @true_user = nil
    @impersonating = false
    clear_app_session
    respond_to do |format|
      format.html { redirect_to signin_path, alert: "Your session expired. Please sign in again." }
      format.json { render json: { error: "session expired" }, status: :unauthorized }
    end
  end

  # True when the current session was authenticated via Solana wallet signature
  # (not email/password). Set by SolanaSessionsController#verify. Forced false
  # while impersonating (OPSEC-046): an admin can't produce the target's Phantom
  # signature, and this stops the admin's real :onchain flag from leaking into
  # the impersonated view — forcing the web2/managed server-sign path for entries.
  def onchain_session?
    return false if impersonating?
    session[:onchain] == true
  end

  # Canonical auth + wallet state for this request — the single source of truth
  # the whole UI branches on (web3 / web2 / guest). Serialised into the page and
  # mirrored client-side by Alpine.store('session'). See SessionContext.
  def wallet_context
    @wallet_context ||= SessionContext.new(user: current_user, onchain_session: onchain_session?)
  end

  # Payload serialised into #session-context for Alpine.store('session').
  # SessionContext stays pure (identity only); on-chain values are read
  # CACHE-FIRST here so this render path issues no Solana RPC — the client
  # hydrates them via refreshSession() after first paint.
  #
  # cents + tokensAvailable are emitted as null when the cache is cold (an
  # "unknown" state): the client's eligibility check recognises null and fails
  # OPEN (let the server-side enter enforce) instead of zero-blocking a user
  # who actually has funds/tokens. The store initializer coerces a null
  # tokensAvailable to 0, and entry funding is decided SERVER-SIDE (both paths go
  # through User#next_unconsumed_entry_token_for, scoped to the address that will
  # actually SIGN the consume), so a cold/null token hint can never mis-fund — it
  # can only mis-label. #display_entry_token_count scopes the hint to the wallet
  # that can sign in this session, matching the authoritative entry path.
  def client_session_payload
    wallet_context.to_h.merge(
      usdcCents:       wallet_field_cents(:usdc),
      usdtCents:       wallet_field_cents(:usdt),
      tokensAvailable: display_entry_token_count,
      # ENABLE_WEB2_USDC_ENTRY kill-switch — eligibilityBlocker reads this to
      # decide whether a web2 user's USDC counts as a funding method (token-first,
      # then USDC). Static per render (the flag can't change mid-session), so
      # refreshSession/refreshBalance never touch it.
      web2UsdcEntry:   AppFlags.web2_usdc_entry?,
      # Entry-time age gate (ENABLE_AGE_GATE). eligibilityBlocker reads these
      # synchronously at hold-time and pops the DOB modal BEFORE the tokens /
      # balance check when the gate is on and this user hasn't verified yet.
      ageGateRequired: age_gate_required?,
      ageVerified:     current_user&.age_attested_at.present? || false,
      # Web3-only onboarding: true when this account still has to link a
      # self-custody wallet. eligibilityBlocker reads it at hold-time and pops
      # the wallet-setup modal BEFORE the funding checks — entry is on-chain, so
      # a wallet-less account can't enter even a FREE contest. Derived
      # RPC-free (see wallet_setup_required?).
      walletSetupRequired: wallet_setup_required?,
      # The first-name ask, as an ENTRY VALIDATION (operator call, 2026-08-15).
      # eligibilityBlocker reads this FIRST — ahead of age, wallet and funding —
      # so hold-to-confirm collects the name before anything else.
      #
      # A COLUMN READ, not OnboardingFlow: the chain's first_name step drops out
      # for the rest of the session the moment the user skips it, and a skip must
      # not buy anyone past a validation. The two questions differ on purpose —
      # "should we ASK again on this page view" (the chain) vs. "is it there"
      # (here) — so this asks the column and nothing else.
      firstNameRequired: current_user.present? && current_user.first_name.blank?,
      # Does this account have ANY wallet — managed or Phantom? The wallet-setup
      # modal's card-payment link reads it to decide whether that link can work
      # at all: every entry-token rail refuses a wallet-less buyer, because a
      # token has to be minted somewhere (TokensController#stripe_checkout and
      # #coinflow_order both guard on solana_connected?).
      #
      # THE SAME PREDICATE the rails enforce, not a proxy for it. `mode` looks
      # like it would do — but a wallet-less account reads mode "web2", so
      # branching on that would show the link to exactly the people it refuses.
      walletConnected: current_user&.solana_connected? || false
    )
  end

  def wallet_field_cents(key)
    return 0 unless current_user            # guest — definitively 0

    if @wallet_balances.is_a?(Hash)
      return ((@wallet_balances[key] || 0).to_f * 100).round
    end

    # No preloaded balances on this render (the navbar preload no longer
    # blocks on the USDC/USDT RPC). Try the warm cache so a returning user
    # still gets a live eligibility hint; nil when cold → emitted as null so
    # eligibilityBlocker fails open (the server-side enter is authoritative).
    cached =
      case key
      when :usdc then Rails.cache.read(usdc_cache_key) if current_user.solana_connected?
      when :usdt then Rails.cache.read(usdt_cache_key) if current_user.solana_connected?
      end
    return nil if cached.nil?

    (cached.to_f * 100).round
  end

  # Navbar balance — on-chain USDC + USDT COMBINED for connected wallets
  # (operator request 2026-06-10: the pill shows total spendable dollars; the
  # /account tiles stay per-currency).
  # NON-BLOCKING + cache-first: the render path NEVER issues a Solana RPC.
  # Returns:
  #   - the SUM of the preloaded @wallet_balances[:usdc] + [:usdt] when a
  #     specific page populated them explicitly (e.g. /wallet)
  #   - the SUM of the cached USDC + USDT numbers (warm cache, written by the
  #     hydrate endpoint or a prior request) — Rails.cache.read, no
  #     fetch-on-miss. A nil side counts as 0 in the sum; nil only when BOTH
  #     are nil so the "loading" state is preserved.
  #   - nil when the cache is cold ("loading" — the client-side refreshBalance
  #     fills the [data-balance-display] pill once it lands)
  #   - 0 for guests / non-wallet users (definitive)
  #
  # Memoized on the controller instance: views call this multiple times
  # across the navbar, layout, and action body.
  def display_balance
    return @display_balance if defined?(@display_balance)

    @display_balance =
      if @wallet_balances.is_a?(Hash) && @wallet_balances.key?(:usdc)
        combined_balance(@wallet_balances[:usdc], @wallet_balances[:usdt]) || 0
      elsif current_user&.solana_connected?
        # Cache-only read: warm → number, cold → nil ("loading"). Never a
        # blocking RPC on the render path.
        combined_balance(Rails.cache.read(usdc_cache_key), Rails.cache.read(usdt_cache_key))
      else
        0
      end
  end

  # USDC + USDT in dollars: nil treated as 0 in the sum, but nil when BOTH
  # are nil — so an unknown-balances state stays distinguishable ("loading")
  # from a definitive $0. Shared by display_balance and the
  # /admin/usdc_balance hydrate endpoint's combined `balance` field.
  def combined_balance(usdc, usdt)
    return nil if usdc.nil? && usdt.nil?
    usdc.to_f + usdt.to_f
  end

  # Fresh onchain USDC balance from logged-in user's wallet
  def fetch_user_usdc
    vault = Solana::Vault.new
    balances = vault.fetch_wallet_balances(current_user.solana_address)
    balances[:usdc] || 0
  end

  # Shared blocking fetch for the client-hydrate endpoints (AdminController
  # #usdc_balance + AccountsController#session_refresh). Fans the two uncached
  # Helius reads — wallet balances (USDC/USDT/SOL) and the seeds sync_balance —
  # out in parallel, WRITES the navbar caches (usdc/usdt/seeds), and returns a
  # hash of the values. Blocking is fine here: these run AFTER first paint, off
  # the render path. Each field is independently nil-safe (an RPC flake yields
  # nil for balances / 0 for seeds, never raises).
  def fetch_navbar_hydrate(user)
    address = user.solana_address
    token_address = entry_token_wallet_address(user)

    balances_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.fetch_wallet_balances(address)
      rescue => e
        Rails.logger.warn("[hydrate] fetch_wallet_balances failed: #{e.message}")
        nil
      end
    end

    seeds_thread = Thread.new do
      Rails.application.executor.wrap do
        Solana::Vault.new.sync_balance(address)&.dig(:seeds)
      rescue => e
        Rails.logger.warn("[hydrate] sync_balance failed: #{e.message}")
        nil
      end
    end

    # Entry-token count. list_entry_tokens WARMS the SAME entry_tokens:<address>
    # cache the navbar reads cache-first (display_entry_token_count), so the next
    # render is a cache hit; the count feeds the client's updateNavTokens repaint
    # of the 🎟️ badge. nil on an RPC flake so the client preserves the prior
    # badge value instead of zeroing it.
    tokens_thread = Thread.new do
      Rails.application.executor.wrap do
        token_address.present? ?
          Solana::Vault.new.list_entry_tokens(token_address).count { |t| !t[:consumed] } : 0
      rescue => e
        Rails.logger.warn("[hydrate] list_entry_tokens failed: #{e.message}")
        nil
      end
    end

    balances = balances_thread.value
    seeds    = seeds_thread.value
    tokens   = tokens_thread.value

    if balances.is_a?(Hash)
      Rails.cache.write(usdc_cache_key(user), balances[:usdc] || 0, expires_in: 60.seconds)
      Rails.cache.write(usdt_cache_key(user), balances[:usdt] || 0, expires_in: 60.seconds)
    end
    unless seeds.nil?
      Rails.cache.write(seeds_cache_key(user), seeds_payload(seeds), expires_in: 60.seconds)
      # Sync the denormalized seeds/level cache on the users row (admin list
      # display + sort) from this fresh on-chain read — write-on-change only.
      LevelUpTokenMintJob.nudge(user, seeds_total: seeds)
    end

    {
      usdc:  balances.is_a?(Hash) ? (balances[:usdc] || 0) : nil,
      usdt:  balances.is_a?(Hash) ? (balances[:usdt] || 0) : nil,
      sol:   balances.is_a?(Hash) ? (balances[:sol]  || 0) : nil,
      seeds: seeds,
      entry_token_count: tokens
    }
  end

  def usdc_cache_key(user = current_user)
    "usdc_balance:#{user.id}"
  end

  def usdt_cache_key(user = current_user)
    "usdt_balance:#{user.id}"
  end

  def invalidate_usdc_cache(user = current_user)
    Rails.cache.delete(usdc_cache_key(user))
  end

  # Navbar seeds bar — on-chain seed count for the logged-in user.
  # NON-BLOCKING + cache-first, same contract as display_balance:
  #   - preloaded @user_seeds when a page populated it explicitly
  #   - the cached seeds payload (warm cache) via Rails.cache.read
  #   - nil when cold ("loading") — the seeds bar falls back to its
  #     localStorage state and refreshBalance fills it
  #   - seeds_payload(0) for guests / non-wallet users (definitive)
  #
  # Per-request memoized: the navbar + seeds_bar partials both ask for this.
  def display_seeds_data
    return @display_seeds_data if defined?(@display_seeds_data)

    @display_seeds_data =
      if defined?(@user_seeds) && !@user_seeds.nil?
        seeds_payload(@user_seeds)
      elsif current_user&.solana_connected?
        # Cache-only read: warm → payload, cold → nil ("loading"). No RPC.
        Rails.cache.read(seeds_cache_key)
      else
        seeds_payload(0)
      end
  end

  def seeds_payload(seeds)
    {
      seeds: seeds,
      level: User.level_for(seeds),
      toward_next: User.seeds_toward_next_level(seeds),
      progress: User.seeds_progress_percent(seeds),
      seeds_to_next: User::SEEDS_PER_LEVEL - User.seeds_toward_next_level(seeds)
    }
  end

  def seeds_cache_key(user = current_user)
    "user_seeds:#{user.id}"
  end

  def invalidate_seeds_cache(user = current_user)
    Rails.cache.delete(seeds_cache_key(user))
  end

  # Navbar 🎟️ entry-token count — cache-first, same contract as
  # display_balance. NON-BLOCKING: the render path NEVER issues a
  # getProgramAccounts scan.
  #   - the non-consumed count derived from the cached entry-token LIST
  #     (warm cache, written by the hydrate endpoint or a prior request) via
  #     Rails.cache.read — no fetch-on-miss
  #   - nil when the cache is cold ("loading" — the client-side updateNavTokens
  #     paints the 🎟️ badge once refreshSession lands)
  #   - 0 for guests / non-wallet users (definitive)
  #
  # Reads the SAME key Solana::Vault#list_entry_tokens writes and mint/consume
  # invalidate (entry_tokens:<address>) — including User#bust_entry_tokens_cache!,
  # which used to clear only its own outer key and left this one serving a spent
  # token for 60s. The count is DISPLAY-ONLY: entry funding is decided
  # server-side (User#next_unconsumed_entry_token_for), so a stale/nil navbar
  # count can never mis-fund.
  #
  # The address follows the SESSION signer, not User#solana_address's account-
  # level web3 preference. A combo account in a web2 session can consume only a
  # token owned by its managed wallet; a web3 session can consume only a token
  # owned by its Phantom wallet. Keeping the badge, client payload and hydrate on
  # that same address prevents the CTA from promising a token the entry path
  # cannot spend.
  #
  # Per-request memoized: the navbar + entry-token badge partials both ask for
  # this in the same render.
  def display_entry_token_count
    return @display_entry_token_count if defined?(@display_entry_token_count)

    address = entry_token_wallet_address
    @display_entry_token_count =
      if address.present?
        # Cache-only read: warm → count, cold → nil ("loading"). No RPC.
        tokens = Rails.cache.read(Solana::Vault.entry_tokens_cache_key(address))
        tokens.nil? ? nil : tokens.count { |t| !t[:consumed] }
      else
        0
      end
  end

  # Wallet whose key can authorize an entry-token consume in this session.
  # This is deliberately narrower than User#solana_address, which describes the
  # account and prefers web3 even when the current session authenticated by
  # email/Google and therefore must use the managed signer.
  def entry_token_wallet_address(user = current_user)
    return nil unless user

    onchain_session? ? user.web3_solana_address : user.web2_solana_address
  end

  # Warms the navbar's on-chain values cache-first so the view phase has zero
  # blocking Solana RPCs. Fires as a before_action on every HTML request for a
  # logged-in wallet user. Thin wrapper around perform_solana_preload — only the
  # gating logic lives here so the underlying warm-up is reusable from JSON
  # endpoints.
  def preload_navbar_solana_data
    return unless request.format.html?
    return unless current_user&.solana_connected?

    perform_solana_preload
  end

  # Cache-first navbar warm-up — issues NO Solana RPC. Every on-chain value the
  # navbar shows is now read from Rails.cache only (balance/seeds via their
  # helpers; here the entry-token count + admin vault_state). The client
  # hydrates + WRITES these caches after first paint via refreshSession() →
  # /account/session_refresh, so the next render is warm.
  #
  # On a WARM cache this memoizes the prefetched values (User#entry_token_balance
  # via @entry_token_balance, Current.vault_state) so view helpers read them
  # without any fetch. On a COLD cache it leaves them unset — the badge/navbar
  # render "loading" (display_entry_token_count → nil) and nothing lazily
  # re-fetches on the render path. Kept as a method (not inlined into the
  # before_action) so it stays reusable; no threads remain, but the name is
  # preserved to avoid churning its callers.
  def perform_solana_preload
    return unless current_user&.solana_connected?

    t_total        = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wallet_address = current_user.solana_address
    token_address  = entry_token_wallet_address
    is_admin       = current_user.admin?

    # NOTE (async-navbar-balance): NONE of the navbar's on-chain reads issue an
    # RPC on this render path anymore — all four are CACHE-FIRST.
    #
    # PR #92 moved the wallet balances (USDC/USDT) + the seeds sync_balance off
    # here (display_balance / display_seeds_data are Rails.cache.read-only). The
    # residual — the entry-token COUNT (a getProgramAccounts scan) and the admin
    # vault_state (read_vault_state) — used to block first paint on a cold 60s
    # cache by JOINING two RPC threads here. They are now cache-first too. The
    # client hydrates every piece via refreshSession() → /account/session_refresh
    # on page load (which WRITES these caches), so the very next render is warm.
    # @wallet_balances / @user_seeds stay unset (nil) so wallet_field_cents emits
    # null cents (fail-open eligibility hint) and the seeds bar uses localStorage.

    # Entry-token COUNT — cache-first, NO fetch-on-miss. The 🎟️ badge reads
    # display_entry_token_count (the same Rails.cache.read); warm @entry_token_balance
    # here ONLY when the list cache is already warm, so User#entry_token_balance
    # (/account, /wallet) stays RPC-free too, and leave it UNSET on a cold cache
    # so nothing lazily re-fetches on the render path.
    if token_address.present? &&
       (cached_tokens = Rails.cache.read(Solana::Vault.entry_tokens_cache_key(token_address)))
      current_user.instance_variable_set(:@entry_token_balance, cached_tokens.count { |tk| !tk[:consumed] })
    end

    # Admin vault_state — cache-first, NO fetch-on-miss. Warm → memoize into
    # Current so the admin hub renders it RPC-free; cold → leave
    # vault_state_fetched FALSE so ONLY the page that actually shows it (admin
    # hub / contract) lazily fetches once via Solana::Vault.cached_vault_state,
    # instead of EVERY admin HTML render paying a cold RPC here.
    if is_admin && (cached_state = Rails.cache.read(Solana::Vault::VAULT_STATE_CACHE_KEY))
      Current.vault_state         = cached_state
      Current.vault_state_fetched = true
    end

    # debug-level (not info) so this fires once per authenticated HTML
    # request without spamming prod logs. Bump to info temporarily when
    # investigating a preload regression.
    Rails.logger.debug("[BENCH] perform_solana_preload total #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_total) * 1000).round}ms")
  end

  def require_profile_completion
    return unless logged_in?
    return if current_user.profile_complete?
    return if self.class.name.in?(%w[SessionsController RegistrationsController SolanaSessionsController FaucetController])
    return if controller_name == "accounts"

    session[:return_to] = request.fullpath
    redirect_to complete_profile_account_path
  end

  # B4 / OPSEC-048: block money-moving actions when the account is frozen
  # (chargeback / refund / dispute pending review). Read-only access stays open.
  def require_unfrozen_account
    return unless logged_in?
    return unless current_user.frozen?
    msg = "Your account is on hold pending review of a recent payment. Please contact support@turfmonster.media."
    respond_to do |format|
      format.html { redirect_to account_path, alert: msg }
      format.json { render json: { error: msg }, status: :forbidden }
    end
  end

  # Shared server-side guard for user-supplied image uploads (avatars, contest
  # banners). The browser always crops to a valid PNG before posting, so this is
  # defense-in-depth against a forged/direct multipart POST — and the only
  # server-side gate, since neither User#avatar nor Contest#contest_image
  # declares an attachment validation.
  IMAGE_UPLOAD_TYPES = %w[image/png image/jpeg image/webp].freeze

  def valid_image?(file, types: IMAGE_UPLOAD_TYPES, max: 8.megabytes)
    file.respond_to?(:content_type) && file.respond_to?(:size) &&
      types.include?(file.content_type) && file.size <= max
  end
end
