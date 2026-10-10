# OPSEC-005: email verification for password + wallet signups.
#
# Three actions:
#   - new     GET  /email_verification/new
#             Render a "you need to verify your email" page (post-signup or
#             post-email-change).
#   - create  POST /email_verification
#             Generate a fresh token + send the verification mail.
#   - verify  GET  /email_verification/:token
#             Consume the token; if valid, set users.email_verified_at = now
#             and redirect to /account with a success flash.
#
# Token is generated via Rails.application.message_verifier(VERIFY_TOKEN_KEY)
# with a 24h expiry. The payload includes user.id + the email it was issued
# for, so a user who changes their email before verifying invalidates the
# pending token. Throttling is intentionally not implemented at this layer —
# add rack-attack rules on `/email_verification` if/when abuse appears.
class EmailVerificationsController < ApplicationController
  VERIFY_TOKEN_KEY = "email_verification_v1"
  VERIFY_TOKEN_TTL = 24.hours

  skip_before_action :require_authentication, only: [:verify]

  def new
    @user = current_user
  end

  def create
    @user = current_user
    return render_verification_result(false, "Email already verified.", root_path) if @user.email_verified_at.present?
    return render_verification_result(false, "No email on file.", account_path) if @user.email.blank?

    # Optional contest context — the verify link returns the user there to
    # finish their entry once their email is confirmed.
    contest = Contest.find_by(slug: params[:contest].presence)
    token = Rails.application.message_verifier(VERIFY_TOKEN_KEY).generate(
      { user_id: @user.id, email: @user.email, return_to: contest && contest_path(contest) },
      expires_in: VERIFY_TOKEN_TTL
    )
    Studio::Email.deliver(UserMailer, :email_verification, @user, token, to: @user.email, user: @user, contest: contest)

    render_verification_result(true, "Verification email sent. Check your inbox.", email_verifications_new_path)
  rescue StandardError => e
    Rails.logger.error("[EmailVerificationsController#create] #{e.class}: #{e.message}")
    render_verification_result(false, "Could not send the verification email.", email_verifications_new_path)
  end

  def verify
    payload = Rails.application.message_verifier(VERIFY_TOKEN_KEY).verify(params[:token]).with_indifferent_access
    user = User.find_by(id: payload[:user_id])
    raise "Unknown account" unless user
    # If the user's email changed after the token was minted, refuse the
    # verification — the token is bound to the original email.
    raise "Token issued for a different email" unless user.email.to_s.downcase == payload[:email].to_s.downcase

    # The click may be made by someone other than whoever asked for the mail.
    raise "Contact support to finish verifying this address" unless user.accept_mailbox_proof!

    # If the token carried a contest return path, send the user there to
    # finish the entry. The path comes from a signed token, but guard against
    # anything that isn't a plain local path regardless.
    return_to = payload[:return_to].to_s
    return_to = nil unless return_to.start_with?("/") && !return_to.start_with?("//")

    if return_to
      redirect_to return_to, notice: "Email verified — finish entering your contest!"
    elsif logged_in?
      redirect_to account_path, notice: "Email verified. Thanks!"
    else
      redirect_to signin_path, notice: "Email verified. You can sign in now."
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to root_path, alert: "Verification link is invalid or expired. Request a fresh one from your account page."
  rescue StandardError => e
    Rails.logger.error("[EmailVerificationsController#verify] #{e.class}: #{e.message}")
    redirect_to root_path, alert: "Verification failed: #{e.message}"
  end

  private

  # Respond to both the inline auth modal (JSON) and the standalone
  # /email_verification/new page (HTML redirect + flash).
  def render_verification_result(ok, message, html_redirect)
    respond_to do |format|
      format.json do
        if ok
          render json: { success: true }
        else
          render json: { success: false, error: message }, status: :unprocessable_entity
        end
      end
      format.html do
        redirect_to html_redirect, (ok ? { notice: message } : { alert: message })
      end
    end
  end
end
