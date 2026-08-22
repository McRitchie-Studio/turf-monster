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
      session[:onchain] = true
      # Remember WHICH wallet just signed, so a later web2 login by this same
      # account can be met with one "Continue with Phantom" button instead of
      # the generic picker. Untrusted client string — the model normalises it
      # through Solana::WalletProvider and ignores anything unknown.
      user.record_web3_authentication!(provider: params[:wallet_provider])
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

  private

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
