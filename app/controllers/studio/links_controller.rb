module Studio
  # turf-monster's OWN /l/<token> handler — overrides the engine's
  # Studio::LinksController so account creation stays on turf's single audited,
  # GATED path. Inherits MagicLinksController for the rich create-or-login flow
  # (legal-age attestation, reset_prior_session!, contest landing, picks, welcome
  # modal). The engine's version would consume magic links through its generic,
  # gateless sign_up_new — never use it here.
  #
  #   GET  /l/:token  magic_link → scanner-safe confirm interstitial (auto-POSTs)
  #                   referral   → attribution cookie + redirect to target (reusable)
  #                   else       → old /l/:slug landing link → 301 /lp/:slug, or invalid
  #   POST /l/:token  magic_link → turf's gated consume (sign in / create account)
  class LinksController < ::MagicLinksController
    # GET is inert for magic links (scanner-safe — see MagicLinksController#confirm).
    def show
      response.set_header("Referrer-Policy", "strict-origin")
      link = ::Studio::Link.find_by(token: params[:token])

      case link&.kind
      when "magic_link"
        @token = params[:token]
        @consume_path = link_consume_path(token: @token) # confirm view posts here
        # Inert, exactly as on /magic_link/:token — preview_magic_link never
        # burns. A live link gets the spinner; a dead one is settled here with
        # the session left alone, instead of spinning to a POST that only
        # rediscovers it is dead.
        if preview_magic_link(link) == :live
          render "magic_links/confirm", layout: "loading"
        end
      when "referral"
        capture_referral(link)
        redirect_to(safe_path(link.target) || root_path, allow_other_host: false)
      else
        # Back-compat: pre-cutover marketing links were /l/:slug. Send them to /lp.
        landing = LandingPage.find_by(slug: params[:token])
        return redirect_to(landing_page_path(landing.slug), status: :moved_permanently) if landing

        redirect_to signin_path, alert: "That link is invalid or has expired. Request a fresh one below."
      end
    end

    # POST burns the single-use magic-link token + signs in/up through turf's
    # GATED MagicLinksController#consume.
    #
    # The kind check that used to live here now rides on the lookup there
    # (Studio::Link.magic_links.find_by), so a referral token resolves to nil and
    # takes the dead path. That is the SAME refusal, and it matters: without it a
    # referral link burns as a reusable kind, exposes no email, and consume falls
    # through to User.find_by(email: nil) — which matches a real row here,
    # because users.email is nullable for wallet-only accounts. It is pinned by
    # magic_link_reclick_test.rb's referral case, which asserts the dead path was
    # taken and includes a nil-email account so the takeover is reachable if the
    # scope is ever removed.
    #
    # (An earlier note here said the old guard's flash[:alert] "turf renders
    # nowhere". That was wrong — the engine's layouts/studio/flash partial, which
    # both turf layouts render, shows notice and alert. It was visible, as a red
    # error toast.)
    def consume
      super # MagicLinksController#consume — gated create-or-login
    end

    private

    # Attribution cookie the signup flow reads (same :reference cookie the legacy
    # ?ref= / /i path used). Value = inviter slug when available, else the token.
    def capture_referral(link)
      inviter = link.linkable
      ref = (inviter.respond_to?(:slug) && inviter.slug.presence) || link.token
      cookies[:reference] = { value: ref.to_s.first(64), expires: 30.days, same_site: :lax }
    end
  end
end
