# Local override of the engine RegistrationsController. Identical to the engine
# version except new signups land on the entry-tokens page (the post-signup
# upsell) instead of the app root.
class RegistrationsController < ApplicationController
  skip_before_action :require_authentication
  # Already authenticated? The signup form is a dead end — send them to their
  # account. Guards only the GET form render (:new), never the POST create.
  before_action :redirect_if_authenticated, only: [:new]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    # First-touch funnel attribution from the cookie, as the other signup paths do.
    @user.reference = cookies[:reference].to_s.first(64) if @user.reference.blank? && cookies[:reference].present?
    # And the page experiment variant the visitor was shown (PageExperimentTracking).
    @user.assign_attributes(experiment_attribution) if @user.experiment_slug.blank?
    # Underwriting compliance: account creation requires the legal-age
    # attestation, same as every other signup flow (magic link / Google /
    # wallet). This POST has no live UI (GET /signup redirects to /signin),
    # but the engine still draws the endpoint — keep the boundary enforced.
    # Flag-gated, parked for the first contest — see age_attestation_required?.
    if age_attestation_required? && !age_attestation_given?
      flash.now[:alert] = AGE_ATTESTATION_ERROR
      return render :new, status: :unprocessable_entity
    end

    @user.age_attested_at = Time.current if age_attestation_required?
    Studio.configure_new_user.call(@user)
    rescue_and_log(target: @user) do
      @user.save!
      set_app_session(@user)
      redirect_to tokens_buy_path, notice: Studio.welcome_message.call(@user)
    end
  rescue StandardError => e
    # Surface validation failures via the standard toast system instead
    # of an inline red box on the form — keeps the signup card visually
    # clean and matches the rest of the app's error UX. flash.now (not
    # flash) because we render-not-redirect on failure; flash would
    # leak into the next request.
    msgs = @user.errors.any? ? @user.errors.full_messages.join(", ") : e.message
    flash.now[:alert] = msgs
    render :new, status: :unprocessable_entity
  end

  private

  def user_params
    params.require(:user).permit(*Studio.registration_params)
  end
end
