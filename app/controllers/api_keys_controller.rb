# The agent API keys card: list, mint and revoke (docs/AGENT_API.md).
#
# EVERY ACTION ANSWERS WITH THE CARD. The card on /account is a Turbo Frame
# (accounts/_api_keys_section), and each response here carries that same frame,
# so creating a key, revoking one, or passing the age gate updates the card
# where it stands instead of reloading the page. A request made without Turbo
# gets the same card on a page of its own.
#
# THIS IS WHERE ELIGIBILITY IS DECIDED. An API request arrives from an agent's
# servers, so nothing about it says where the player is or how old they are.
# The one moment we can know is here: the player's own browser, signed in,
# asking for a key. #create asks ApplicationController#api_key_mint_blocker —
# the same question the card asked when it chose what to render — and stamps
# the verdict on the key (ApiKey#eligibility). Not offering the form is a
# courtesy; the check in #create is the boundary.
class ApiKeysController < ApplicationController
  GENERIC_FAILURE = "We couldn't create that key. Please try again.".freeze
  REVOKE_MISSING  = "That key is no longer on your account. Nothing was changed.".freeze
  REVOKE_FAILURE  = "We couldn't revoke that key. Please try again.".freeze

  # `adding` asks for the form already open: the link a card restored by Back
  # offers (accounts/_api_keys_section). It changes what is shown, never what
  # is allowed; a blocked or capped player still gets the explanation.
  def index
    render_card(form_open: params[:adding].present?)
  end

  # The 201 response is the ONE place the raw key appears. It is not put in the
  # flash (that would write it to the session cookie) and there is no URL that
  # renders it again.
  def create
    return render_card(status: :forbidden) if api_key_mint_blocker

    api_key = nil
    form_error = nil
    rescue_and_log(target: current_user) do
      api_key = ApiKey.mint!(
        user: current_user,
        name: params[:name],
        geo_country: geo_country,
        geo_state: geo_state,
        age_result: age_gate_required? ? "passed" : "not_required"
      )
    rescue ActiveRecord::RecordInvalid => e
      # A blank name or a player at their cap is a form error, not an incident:
      # answer it inline and keep it out of error_logs.
      form_error = e.record.errors.full_messages.first
    rescue ApiKey::LimitReached => e
      form_error = e.message
    end

    if form_error
      return render_card(status: :unprocessable_entity, form_error: form_error, form_name: params[:name])
    end

    response.headers["Cache-Control"] = "no-store"
    render_card(status: :created, new_key: api_key)
  rescue StandardError
    render_card(status: :internal_server_error, form_error: GENERIC_FAILURE, form_name: params[:name])
  end

  # Scoped through current_user, so another player's key id is a 404, not a
  # revoke. Allowed while impersonating: it only ever removes access.
  #
  # A refusal is answered WITH THE CARD, at the status it earned. The stock 404
  # and 500 pages carry no frame, and the card would show Turbo's "Content
  # missing" in their place.
  def destroy
    api_key = current_user.api_keys.find_by(id: params[:id])
    return render_card(status: :not_found, card_error: REVOKE_MISSING) if api_key.nil?

    rescue_and_log(target: current_user) do
      api_key.revoke!
    end
    redirect_to account_api_keys_path, status: :see_other
  rescue StandardError
    render_card(status: :internal_server_error, card_error: REVOKE_FAILURE)
  end

  private

  def render_card(status: :ok, **card)
    render :index, status: status, locals: { card: card }
  end
end
