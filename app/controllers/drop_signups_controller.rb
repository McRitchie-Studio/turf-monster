# POST /drop-signups — "Notify me when Weeks 7-9 drops" on /turf-monster-v2.
#
# OPEN TO ANYONE. The explainer is the top of the funnel, so most visitors have
# no account; signed-in visitors are welcome too and their row carries the user.
# CSRF stays ON (the page renders the token; the Alpine form sends it), and the
# rate limits are in config/initializers/rack_attack.rb (drop_signups/*).
#
# THE SLATE IS THE SERVER'S CHOICE. The row is filed under
# NextSlateDrop::SLATE_KEY, never a client-supplied key, so nobody can open a
# list for a drop that does not exist.
#
# WHAT A VISITOR CAN LEARN FROM THIS ENDPOINT: nothing about other people. A new
# address and an address already on the list get the same 200 and the same
# copy, and the honeypot (a field no human sees) gets that 200 too while writing
# nothing, so a bot cannot tell it was caught. Only a malformed address is
# refused (422), because that is about the visitor's own typing.
#
# JSON for the Alpine form; a plain form post (no JS) redirects back to the
# section with a flash the page reads to draw its success or error state.
class DropSignupsController < ApplicationController
  skip_before_action :require_authentication

  # The field bots fill and people never see. Named like a real field on
  # purpose; an obviously-named trap is one a bot learns to skip.
  HONEYPOT_PARAM = :website

  def create
    return respond_ok if params[HONEYPOT_PARAM].present?

    signup = rescue_and_log(target: current_user) do
      DropSignup.register(
        email: params[:email],
        slate_key: NextSlateDrop::SLATE_KEY,
        source: params[:reference].presence || params[:source],
        ip: request.remote_ip,
        user_agent: request.user_agent,
        user: current_user
      )
    end

    if signup.persisted?
      respond_ok
    else
      respond_invalid
    end
  end

  private

  def respond_ok
    respond_to do |format|
      format.json { render json: { ok: true } }
      format.html do
        flash[:drop_signup] = "ok"
        redirect_to turf_monster_v2_path(anchor: "notify"), status: :see_other
      end
    end
  end

  def respond_invalid
    message = "Enter a valid email address."
    respond_to do |format|
      format.json { render json: { ok: false, error: message }, status: :unprocessable_entity }
      format.html do
        flash[:drop_signup] = "invalid"
        redirect_to turf_monster_v2_path(anchor: "notify"), status: :see_other
      end
    end
  end
end
