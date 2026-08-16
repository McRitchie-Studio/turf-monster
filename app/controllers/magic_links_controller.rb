# Unified create-or-login email magic link (replaces the password UI).
#
#   POST /magic_link        — request a link (email [, contest, picks, return_to])
#   GET  /magic_link/:token — "Confirm sign-in" interstitial (does NOT consume —
#                             scanner-safe; see #confirm)
#   POST /magic_link/:token — consume it: log in OR create the account
#
# create-or-login: clicking the link IS proof of email ownership, so an email
# that collides with a Google/wallet-only account that was never email-verified
# is safely logged in here and stamped email_verified_at (unlike from_omniauth,
# which refuses that collision precisely because it lacked this proof).
class MagicLinksController < ApplicationController
  # The shared click flow (studio-engine >= 0.31): preview_magic_link for the
  # inert GET, consume_magic_link for the burning POST, and the decision table
  # behind them (Studio::LinkResolution). Turf keeps its own rich behavior by
  # overriding the HOOKS below — the age gate, the toasts, the contest landing —
  # never by re-deciding what a click means.
  #
  # The rule that made this worth adopting: a DEAD link must not touch the
  # session, and a re-click on your OWN live link must not either. Before this,
  # every consume ran reset_prior_session! and every failure bounced to
  # /signin — so clicking your own link twice logged you out of a session that
  # was perfectly valid.
  include Studio::LinkConsumption

  skip_before_action :require_authentication

  # The confirm interstitial is a transient loading screen (just a spinner that
  # auto-submits) — render it on the minimal bare layout, not the full app shell,
  # so it paints instantly with no navbar/app-CSS/Solana-preload.
  layout "loading", only: :confirm

  # Respond uniformly for any well-formed email. Under create-or-login every
  # address is "valid" (it logs in or signs up), so there is nothing to
  # enumerate — but staying uniform keeps it that way if invite-only is ever
  # added. A malformed email gets the same response with no mail sent.
  def create
    email = params[:email].to_s.strip.downcase
    if User.valid_email?(email)
      # The legal-age checkbox is checked at request time; the attestation
      # rides in the link row because the ACCOUNT is created at consume time
      # (possibly in a different browser). sign_up_new enforces it.
      token = Studio::Link.create_magic_link(email: email, return_to: resolved_return_to,
                                             age_attested: age_attestation_given?).token
      Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email, contest: @magic_contest)
    end
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to signin_path, notice: "Check your inbox — we just emailed you a sign-in link." }
    end
  end

  # GET /magic_link/:token — the "Confirm sign-in" interstitial.
  #
  # This action is DELIBERATELY INERT: it does NOT consume the token. It only
  # renders a one-button page whose button POSTs back to #consume. This is the
  # scanner-safe core of the flow: email link-scanners (Outlook SafeLinks,
  # Mimecast, corporate AV), the Gmail image proxy, and link-preview prefetchers
  # all issue a GET/HEAD against the emailed URL. If that GET consumed the
  # single-use token, the burn would land BEFORE the human's first real click,
  # and the human would see "link already used" on a link they never used — the
  # operator's "hard time creating an account" symptom and a real tester risk.
  # Because the GET is inert, a scanner's pre-fetch is a no-op; only the human's
  # POST burns the token.
  #
  # The token never leaves the URL here, so keep it out of Referer on this
  # page's subresource loads (logo, fonts, analytics).
  def confirm
    # strict-origin (NOT no-referrer): still strips the path so the single-use
    # token never leaks in the Referer of subresource loads, but unlike
    # no-referrer it leaves the Origin header intact on the consume form POST.
    # no-referrer makes the browser send `Origin: null`, which Rails' origin-based
    # CSRF check (forgery_protection_origin_check) rejects with 422 — the human's
    # button press then silently fails to sign in. (Tests miss this: forgery
    # protection is off in the test env.)
    response.set_header("Referrer-Policy", "strict-origin")
    @token = params[:token]
    # preview_magic_link is INERT — it never burns. It returns :live when the
    # link is still good (we render the spinner, which auto-POSTs to #consume),
    # and otherwise settles the click here and returns :handled. A dead link
    # therefore stops going through a spinner that only POSTs to learn what a
    # read already knew — and a visitor clicking their own spent link is
    # redirected on the spot, session untouched.
    render :confirm if preview_magic_link(::Studio::Link.magic_links.find_by(token: params[:token])) == :live
  end

  # POST /magic_link/:token — the authoritative consume. This is the ONLY place
  # the single-use token is burned, and it only runs on the human's button press
  # (a scanner won't POST a CSRF-protected form). Mirrors the prior GET behavior.
  # consume_magic_link burns first — winning the atomic burn IS the proof the
  # link was live — then routes through Studio::LinkResolution to one of three
  # outcomes: authenticate (sign_in_existing / sign_up_new below), continue (the
  # viewer's own live link: burn it, keep the session exactly as it stands), or
  # dead (never touch the session at all).
  def consume
    response.set_header("Referrer-Policy", "strict-origin")
    consume_magic_link(::Studio::Link.magic_links.find_by(token: params[:token]))
  end

  private

  # Hard-reset any prior session BEFORE establishing the magic-link user's.
  # A magic link is a fresh WEB2 (email) login: if the browser already held a
  # web3/Phantom-linked session, its state (onchain flag, sso_* awareness,
  # geo override, return_to, etc.) must not bleed into the new session — that
  # bleed is what made a web2 magic-link user still look phantom-linked and
  # triggered the Phantom unlock probe on the landing. reset_session rotates
  # the session id and drops every key; we then explicitly clear the onchain
  # privilege flag (set_app_session also deletes it, but be belt-and-braces
  # in case the engine helper changes) and Current so no request-scoped
  # identity from the old session lingers. The layout's user-change cleanup
  # (compares data-user-id) clears stale phantom_dl_* + wallet localStorage on
  # the landing render, completing the client side.
  def reset_prior_session!
    reset_session
    session.delete(:onchain)
    Current.reset
  end

  # Reached ONLY when the identity actually changes — a signed-out visitor, or a
  # link belonging to someone other than the current user. That is what makes
  # reset_prior_session! safe to keep here: the concern routes a re-click by the
  # SAME user to link_continue instead, which never reaches this method. Before
  # the adoption this ran on every consume, so a second click cost the visitor
  # their whole session (onchain flag, geo override, picks in flight) to
  # re-establish the identity they already had.
  def sign_in_existing(user, result)
    reset_prior_session!
    user.claim_parked_username!
    set_app_session(user)
    # Web3-only onboarding: a RETURNING web2 user is nudged to link Phantom
    # unless their managed wallet still holds an entry's worth of USDC — those
    # users are useable as-is (operator call) and see nothing new.
    # A returning login gets no welcome beat, but may still owe a step (a blank
    # first name, an unverified DOB, a wallet). Any armed step means a modal is
    # about to open, and a toast underneath it would just talk over it.
    onboarding_steps = record_onboarding_state!(user)
    needs_wallet = onboarding_steps.any?
    # rescue_and_log because the session is already established above: a User
    # validation failing here would otherwise 500 a signed-in visitor with
    # nothing in ErrorLog to attribute it to.
    rescue_and_log(target: user) do
      user.update!(email_verified_at: Time.current) if user.email_verified_at.blank?
    end
    # Returning login: a quiet "welcome back" toast — no celebratory modal and no
    # token upsell (they already have an account). Land on the contest they came
    # from, else the featured contest. When wallet setup is due, the toast is
    # dropped: the setup modal (auto-opened from the session prompt) IS the
    # message, and a toast underneath it would just talk over it.
    return redirect_to landing_path_for(result) if needs_wallet

    redirect_to landing_path_for(result),
                flash: { auth_toast: { title: "Welcome back", message: "Signed in as #{user.username}." } }
  end

  # Mirrors RegistrationsController#create: build → configure_new_user → save!
  # (fires generate_managed_wallet! + enqueue_onchain_account_setup) → land on
  # the entry-tokens upsell. There is no password — email auth is magic-link
  # only across the whole app (the password_digest column is dormant).
  def sign_up_new(result)
    # Underwriting compliance: a brand-new account requires the legal-age
    # attestation that rode in with the link request. Without it the account
    # is NOT created — the user re-requests a link with the box checked.
    # (Existing users take sign_in_existing above and never hit this.)
    # Flag-gated, parked for the first contest — see age_attestation_required?.
    if age_attestation_required? && !result.age_attested
      return redirect_to signin_path, alert: AGE_ATTESTATION_ERROR
    end

    reset_prior_session!
    user = User.new(email: result.email,
                    age_attested_at: (Time.current if age_attestation_required?),
                    reference: cookies[:reference].presence&.to_s&.first(64))
    Studio.configure_new_user.call(user)
    rescue_and_log(target: user) do
      user.save!
      cookies.delete(:reference)
      user.update!(email_verified_at: Time.current)
      set_app_session(user)
      # The onboarding chain owns this moment now: first name → age → wallet,
      # resolved server-side and walked by the layout's driver wherever the user
      # lands. Both branches below only decide whether to ALSO say something in a
      # toast/modal, and anything the chain is about to show wins — two greetings
      # on one render reads as a bug.
      onboarding_steps = record_onboarding_state!(user)
      if contest_return_to?(result)
        # New user landing on a SPECIFIC contest: confirm auth with a toast and
        # let the board's existing post-login flow open the get-entry-tokens
        # picker (a web2 magic-link user needs a token to play). No celebratory
        # modal here — the toast + tokens picker carry the moment.
        #
        # Wallet setup pending: no toast promising an entry token, because a
        # wallet-less account can't buy one. Land on the contest (picks intact)
        # and let the setup modal carry the next step.
        redirect_to result.return_to, **(onboarding_steps.any? ? {} : { flash: { auth_toast: {
                      title:   "You're signed in",
                      message: "Grab an entry token to lock in your picks."
                    } } })
      else
        # A GENERIC /signin signup: the onboarding chain owns this moment. Its
        # first card here is the first-name ask, outstanding by definition for an
        # account created in this request (nothing has set a first name yet), so
        # there is no second greeting to add — a flash welcome modal would stack
        # on the chain's opening card. The old flash[:magic_link_welcome] branch
        # that used to live here was unreachable for exactly that reason and has
        # been retired.
        redirect_to landing_path_for(result)
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # Two valid tokens for the same brand-new email consumed near-simultaneously
    # both miss the find_by and race to save!; the loser hits the unique index.
    # That's benign — the account now exists, so just log the winner in.
    existing = User.find_by(email: result.email)
    return sign_in_existing(existing, result) if existing

    redirect_to signin_path, alert: "We couldn't finish creating your account. Please try again."
  rescue StandardError => e
    Rails.logger.error("[MagicLinksController#consume] signup failed #{e.class}: #{e.message}")
    redirect_to signin_path, alert: "We couldn't finish creating your account. Please try again."
  end

  # Derives the post-consume landing path server-side (so it rides inside the
  # signed token and can't be tampered). A contest slug becomes the contest
  # page; validated picks ride along as ?picks= so the board can rehydrate a
  # guest's lineup even across a different browser/tab (where localStorage is
  # unavailable).
  def resolved_return_to
    @magic_contest = Contest.find_by(slug: params[:contest].presence)
    if @magic_contest
      picks = sanitized_picks
      picks.present? ? "#{contest_path(@magic_contest)}?picks=#{picks.join(',')}" : contest_path(@magic_contest)
    else
      safe_path(params[:return_to])
    end
  end

  # Digits only, max 6, intersected with the contest's real matchups so a
  # tampered query can't smuggle arbitrary ids back into the board.
  def sanitized_picks
    ids = params[:picks].to_s.split(",").map(&:to_i).select(&:positive?).first(6)
    return [] if ids.empty? || @magic_contest.nil?

    valid = @magic_contest.matchups.where(id: ids).pluck(:id)
    ids & valid
  end

  def safe_path(path)
    p = path.to_s
    p.start_with?("/") && !p.start_with?("//") ? p : nil
  end

  # --- Studio::LinkConsumption hooks -----------------------------------------

  # Turf's sign-in page is /signin, not the engine's /login.
  def link_login_path
    signin_path
  end

  # "Home" for turf is the root board (contests#world_cup) — the same place
  # landing_path_for sends a link with no destination, so both halves of a link
  # click agree on where "the app" is.
  def link_home_path
    root_path
  end

  # The concern's default treats a bare "/" as a real destination; turf treats it
  # as "no destination" and lands on the root instead (landing_path_for, which
  # says the same of the auth pages). Overridden rather than reimplemented so the
  # login/home cases keep coming from the hooks above.
  def link_destination(destination, result)
    return super unless destination == :return_to

    landing_path_for(result)
  end

  # A used, expired, or unrecognized link. The concern guarantees this never
  # touches the session; this override only chooses HOW the message is shown.
  #
  # It is a PRESENTATION choice, not a necessity. An earlier version of this
  # comment claimed turf renders auth_toast and nothing else, and that plain
  # flash[:notice]/[:alert] appear in no layout or view. That was FALSE: both
  # application.html.erb and landing.html.erb render layouts/studio/flash, and
  # the engine partial selects exactly notice+alert. The proof was in this very
  # file — #create ships `notice: "Check your inbox…"`, the most important
  # message in the flow. The override is kept because the bespoke title reads
  # better than a bare sentence, and because it lets the outcome's severity ride
  # through to the toast; inheriting the default would have worked too.
  def link_dead(outcome, result)
    path = link_destination(outcome.destination, result)
    return redirect_to(path) if outcome.silent?

    redirect_to path, flash: { auth_toast: {
      # `type` is the SEVERITY, and it has to ride along: the layout's toast
      # dispatch used to hard-code 'notice', so "Sign-in link expired" painted
      # the green success check. The engine toast reads this to pick between
      # --color-success and --color-danger.
      type:    outcome.level == :alert ? "alert" : "notice",
      title:   dead_link_title(outcome),
      message: outcome.message
    } }
  end

  def dead_link_title(outcome)
    outcome.level == :alert ? "Sign-in link expired" : "Still signed in"
  end

  # True when the link carried a specific contest (resolved_return_to bakes the
  # contest path — and any validated picks — in at request time).
  def contest_return_to?(result)
    result.return_to.to_s.start_with?("/contests/")
  end

  # Paths that are NOT destinations. A link requested from the sign-in card
  # carries return_to: "/signin", and honoring that lands a freshly signed-in
  # user back on the sign-in page — where SessionsController#new's
  # redirect_if_authenticated bounces them to /account. That is how clicking a
  # magic link put the operator on their account page instead of the app
  # (2026-08-15). The auth pages are a WAY IN, never a place to arrive.
  # Written WITHOUT trailing slashes, and matched as "the path itself, or a
  # segment under it" — so /l matches /l/abc but never /login, and /login is
  # listed on its own rather than being swallowed by a sloppier prefix test.
  NON_DESTINATION_PREFIXES = ["/signin", "/login", "/magic_link", "/l"].freeze

  def non_destination?(path)
    p = path.to_s.split("?").first.to_s.chomp("/")
    return true if p.empty? # a bare "/"

    NON_DESTINATION_PREFIXES.any? { |prefix| p == prefix || p.start_with?("#{prefix}/") }
  end

  # Where a login lands: honor any explicit (already-sanitized) return_to — a
  # contest, or e.g. /account — and otherwise drop them on the ROOT (operator
  # call, 2026-08-15). "Otherwise" covers no destination, a bare "/", and the
  # auth pages above, which used to be honored literally.
  #
  # Root is contests#world_cup, the app's home board. It replaces a redirect to
  # `Contest.featured` here: same intent, one destination, and it cannot resolve
  # to nil the way the featured lookup could (which is why the contests-index
  # fallback beside it is gone too).
  def landing_path_for(result)
    # `result` is nil for an unrecognized token — the dead path calls this too.
    rt = result&.return_to
    return rt if rt.present? && !non_destination?(rt)

    root_path
  end
end
