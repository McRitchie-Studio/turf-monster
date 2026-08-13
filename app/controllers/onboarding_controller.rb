# The onboarding chain's own two writes: capture a first name, or record that the
# user skipped it. Everything else in the chain already had an endpoint (age →
# AgeVerificationsController, wallet → AccountsController#link_solana).
#
# Why a controller rather than reusing the account update: this runs seconds
# after signup, from a modal, and must accept exactly ONE field. AccountsController
# #update takes the whole profile form and carries its own redirects and flash;
# pointing a modal at it would mean sending a profile form to set a first name.
class OnboardingController < ApplicationController
  # Both actions are for the freshly signed-in user, so authentication is the
  # default require_authentication — no skip_before_action here.

  MAX_FIRST_NAME = 40

  # POST /onboarding/first_name
  #
  # Writes users.first_name (the column already exists — User#set_name_parts
  # populates it from `name`), and backfills `name` when it is blank so the
  # display-name chain has something better than an email prefix to show.
  def first_name
    value = params[:first_name].to_s.strip.gsub(/\s+/, " ").first(MAX_FIRST_NAME)

    if value.blank?
      return render json: { ok: false, error: "Enter your first name, or skip for now." },
                    status: :unprocessable_entity
    end

    rescue_and_log(target: current_user) do
      # update_columns, not update!: this is a display field on an account that
      # may be mid-onboarding, and a validation failure elsewhere on the record
      # (a grandfathered reserved username, say) must not block a first name.
      # set_name_parts is a before_save that would fight us here anyway — it
      # DERIVES first_name FROM name, so writing through it would discard the
      # value we were just given.
      attrs = { first_name: value }
      attrs[:name] = value if current_user.name.blank?
      current_user.update_columns(attrs)

      render json: { ok: true, first_name: value, next: remaining_steps }
    end
  end

  # POST /onboarding/skip_first_name
  #
  # Session-scoped, deliberately: skipping means "not now", not "never". A later
  # session can ask again (the field is still blank), which is the whole reason
  # this is not a users column.
  def skip_first_name
    session[:onboarding_skipped_first_name] = true
    render json: { ok: true, next: remaining_steps }
  end

  private

  # What is left AFTER this write, so the client can keep walking the chain
  # without a second round trip. `welcome:` is false — that beat is behind us by
  # definition if we are answering a first-name call.
  def remaining_steps
    onboarding_steps_for(current_user).map(&:to_s)
  end
end
