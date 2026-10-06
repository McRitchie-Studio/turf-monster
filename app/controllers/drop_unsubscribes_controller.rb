# One-click unsubscribe from the slate-drop emails (DropSignupMailer). No login:
# the signed token (DropSignup#unsubscribe_token) IS the authority, it names
# exactly one row, and it cannot be forged or repurposed.
#
#   GET  /drop-signups/unsubscribe/:token  renders a page that AUTO-SUBMITS the
#        POST below, so a person's single click unsubscribes them while a mail
#        scanner's prefetch (Outlook SafeLinks and friends GET every link and
#        run no script) changes nothing — the same reason
#        MagicLinksController#confirm is inert.
#   POST /drop-signups/unsubscribe/:token  sets unsubscribed_at and says so.
#        It is also the List-Unsubscribe-Post target (RFC 8058): the mail
#        client's own one-click button POSTs here with no session and no CSRF
#        token, which is why forgery protection is off for this one action.
#        The token is the credential, so a forged POST needs a token it cannot
#        make.
#
# An unknown or tampered token gets the same page with a "not valid" message
# and a 404, never a 500 and never a hint about which addresses are listed.
class DropUnsubscribesController < ApplicationController
  skip_before_action :require_authentication
  skip_forgery_protection only: :create

  def show
    @signup = DropSignup.find_by_unsubscribe_token(params[:token])
    response.set_header("Referrer-Policy", "strict-origin")
    return render(:invalid, status: :not_found) unless @signup

    @token = params[:token]
    render(@signup.unsubscribed? ? :done : :show)
  end

  def create
    @signup = DropSignup.find_by_unsubscribe_token(params[:token])
    response.set_header("Referrer-Policy", "strict-origin")
    return render(:invalid, status: :not_found) unless @signup

    rescue_and_log(target: @signup.user) { @signup.unsubscribe! }
    render :done
  end
end
