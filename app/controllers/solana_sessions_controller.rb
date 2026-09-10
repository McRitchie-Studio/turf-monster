class SolanaSessionsController < ApplicationController
  include Solana::SessionAuth
  skip_before_action :require_authentication

  def nonce
    session[:solana_nonce] = SecureRandom.hex(16)
    session[:solana_nonce_at] = Time.current.to_i
    render json: { nonce: session[:solana_nonce] }
  end

  def phantom_callback
    # Client-side only — JS handles decryption and verify POST
  end

  # Landing page for a Google sign-in that collided with a wallet account
  # (OmniauthCallbacksController#create stashed the Google identity). Explains
  # the situation and prompts a wallet login; #verify then completes the link.
  def link_wallet
    pending = session[:pending_google_link]
    return redirect_to signin_path unless pending

    @pending_email = pending["email"]
  end

  def verify
    pubkey_b58 = verify_solana_signature!(
      message: params[:message],
      signature_b58: params[:signature],
      pubkey_b58: params[:pubkey],
      session: session
    )

    # Find or create user with this Solana address
    user = User.from_solana_wallet(pubkey_b58)
    is_new = user.nil?

    # Underwriting compliance: a brand-new wallet signup must carry the
    # legal-age attestation (checkbox in the Connect Wallet modal). Existing
    # wallet users are a plain login and skip this.
    # Flag-gated, parked for the first contest — see age_attestation_required?.
    if is_new && age_attestation_required? && !age_attestation_given?
      return render json: { error: AGE_ATTESTATION_ERROR }, status: :unprocessable_entity
    end

    # NO PLACEHOLDER NAME. This used to seed `name: "anon"`, and User#set_name_parts
    # copies `name` into `first_name` — so every wallet account was born already
    # "holding" a first name, and the onboarding chain's first-name card could
    # never fire for it (Studio.first_name_outstanding? reads exactly that
    # column). Leaving both blank is what lets the chain ask. Nothing downstream
    # wants the placeholder back: display_name falls through username → wallet →
    # "anon" on its own, and #assign_parked_identity already treats a blank name
    # the same as the old "anon".
    user ||= User.new(
      web3_solana_address: pubkey_b58,
      age_attested_at: (Time.current if age_attestation_required?),
      reference: cookies[:reference].presence&.first(64) # first-touch funnel attribution
    )

    rescue_and_log(target: user) do
      user.save! if user.new_record?
      user.claim_parked_username!
      cookies.delete(:reference) if is_new
      set_app_session(user)
      # Remember WHICH wallet just signed, so a later web2 login by this same
      # account can be met with one "Continue with Phantom" button instead of
      # the generic picker. Untrusted client string — the model normalises it
      # through Solana::WalletProvider and ignores anything unknown.
      user.record_web3_authentication!(provider: params[:wallet_provider])
      # The SET bookend, and the one that also covers a wallet SWITCH — a switch
      # re-auths through this same endpoint, so remembering the brand here means
      # the session follows the wallet without a second seam to keep in step.
      # record_web3_authentication! writes the DURABLE column on the user; the
      # call below writes the per-session facts. Both normalise through the same
      # registry. SHARED with AccountsController#link_solana — a wallet LINK is
      # the same proof as a wallet LOGIN, and keeping the two session writes in
      # one method is what stops the two paths drifting apart again.
      promote_to_onchain_session!(provider: params[:wallet_provider])
      # A wallet login IS the wallet setup — drop any nudge a prior email login
      # left in this browser's session.
      clear_wallet_setup_state!
      linked = apply_pending_google_link!(user)
      # Arm the post-auth chain here too — a wallet login is an auth success like
      # any other, and until this call it was the ONE that armed nothing. The cost
      # of that omission was not a missing card but a WRONG ORDER: a brand-new
      # wallet account was asked for its birthday by the contest entry gate
      # whenever it first tried to enter, and was never asked its first name at
      # all. OnboardingFlow resolves what is actually outstanding, so a user who
      # just proved wallet ownership walks first name → age and never the wallet
      # step (WalletSetupPolicy: a linked Phantom has nothing to set up).
      #
      # AFTER clear_wallet_setup_state! above, which deletes the very session key
      # this writes — arming first would hand the user an empty chain.
      record_onboarding_state!(user)
      # New signups land on the entry-tokens page (post-signup upsell);
      # a completed Google link goes to /account; everyone else to the root.
      redirect = linked ? account_path : (is_new ? tokens_buy_path : "/")
      render json: { success: true, redirect: redirect, new_user: is_new }
    end
  rescue Solana::AuthVerifier::VerificationError => e
    render json: { error: e.message }, status: :unauthorized
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Record a wallet failure that happened ENTIRELY in the browser.
  #
  # THE GAP THIS CLOSES. `window.solanaConnectAndVerify` and the modals around it
  # handle their own rejections — caught, mapped through `parseSolanaError`,
  # painted into an `x-text` paragraph — so the server never heard about them and
  # error_logs never held one. On 2026-09-06 a user whose Phantom held no keypair
  # was told to check their USDC balance seven times in one production session
  # before an operator noticed by hand. Every OTHER user-facing failure in this
  # app lands in error_logs; this class of failure was the exception, and the
  # reason was that nobody was listening, not that nobody could tell.
  #
  # ── THE FAIL-OPEN CONTRACT ───────────────────────────────────────────────────
  #
  # This endpoint is OBSERVATION. It runs after the user has already been told
  # what went wrong, and it must not be able to change that, delay it, or add a
  # second failure on top of the first. So:
  #
  #   * it answers 204 whether it recorded anything or not. The client is given
  #     nothing to branch on, because a client that branches on this is a client
  #     that can be broken by it;
  #   * every fault inside it is swallowed into the Rails log. The reporting of a
  #     failure must never become a failure;
  #   * it is never awaited on the client (see window.reportWalletFailure in
  #     app/javascript/solana_errors.js) and every call site guards on `typeof`.
  #
  # THE COST OF THAT CONTRACT, NAMED. A 204-on-everything endpoint is exactly the
  # shape whose test passes while the endpoint does nothing at all, so the test
  # that guards it asserts the ROW, never the status —
  # test/controllers/solana_client_failure_report_test.rb.
  #
  # UNAUTHENTICATED BY NECESSITY: the failure this exists to see happens BEFORE
  # sign-in. It is throttled in config/initializers/rack_attack.rb instead.
  def report_failure
    begin
      record_client_wallet_failure(Solana::ClientFailureReport.from_params(client_failure_params))
    rescue StandardError => e
      # The reporter's own fault, and the only place it may ever surface. Not an
      # ErrorLog: the write path is what just failed, so asking it to record its
      # own failure is the one request guaranteed to fail the same way.
      Rails.logger.error("[solana][client-failure] report dropped: #{e.class}: #{e.message}")
    end

    head :no_content
  end

  private

  # Layer 1 of the PII rule (Solana::ClientFailureReport has the whole rule).
  # FOUR KEYS — but read what this layer does and does not do, because a mutant
  # proved the obvious reading wrong. Widening this list to permit :signature,
  # :nonce and :message left the whole suite green: permitting a key STORES
  # nothing by itself, because Solana::ClientFailureReport.from_params reads four
  # keys by name and never looks at the rest of the hash.
  #
  # So this is the OUTER layer — it keeps a credential out of the params object,
  # out of a log of them, and out of anything downstream that iterates the hash.
  # The load-bearing constraint is `from_params`. The two are asserted as one set
  # by test/controllers/wallet_failure_reporter_wiring_test.rb, so neither can be
  # widened alone.
  def client_failure_params
    params.permit(:provider, :stage, :raw_message, :mapped_message)
  end

  # WHY A RAISE. `rescue_and_log` is the app's one persistence path for a logged
  # failure — it captures, attaches target/parent with the same slug rules
  # everything else uses, and fans out to Sentry. But it is built to CATCH a
  # raise, and a client-side failure arrives as data: nothing here has thrown.
  # Raising it one line deep is what puts this failure on that shared path
  # instead of on a second, hand-rolled one that would drift from it — and it is
  # what gives the row a real backtrace and Sentry a real event.
  #
  # `rescue_and_log` then RE-RAISES by contract, and the re-raise is caught and
  # dropped right here. That is the whole trick, and it is deliberate: the raise
  # exists to reach the logger, never to reach the response.
  #
  # WHAT THE ROW TARGETS, stated because the answer is routinely assumed wrong:
  # the USER, when there is one — a wallet LINK or a step-up is performed by
  # somebody already signed in. A guest sign-in failure has no user to target, by
  # definition, and its row carries none; it is found by class and stage. (This
  # app's other on-chain rows target the Entry, so a user-keyed search of
  # error_logs comes back empty and reads as "nothing was logged". These rows are
  # the exception on purpose: the subject of the failure is a person's wallet.)
  def record_client_wallet_failure(report)
    rescue_and_log(target: current_user) do
      raise Solana::ClientWalletFailure, report.summary
    end
  rescue Solana::ClientWalletFailure
    nil
  end

  # A Google sign-in that collided with this wallet account stashed its
  # (already GoogleOauthValidator-checked) identity in the session. Now that
  # the user has proven wallet ownership by signature, BOTH factors are proven
  # for the same account — so complete the Google link. One-shot, 15-minute
  # TTL, and only for the exact account the stash named.
  def apply_pending_google_link!(user)
    pending = session.delete(:pending_google_link)
    return false unless pending
    return false unless pending["user_id"] == user.id
    return false if pending["at"].to_i < 15.minutes.ago.to_i

    user.update!(
      provider: pending["provider"],
      uid: pending["uid"],
      email_verified_at: user.email_verified_at || Time.current
    )
    flash[:notice] = "Google account linked — you can sign in with your wallet or Google."
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end
end
