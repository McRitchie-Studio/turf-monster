# Entry-time age gate (ENABLE_AGE_GATE). The DOB modal in the contest
# hold-to-confirm flow POSTs here once; we recompute the age SERVER-SIDE
# against the user's DETECTED state (geo_state — never a client-supplied
# state), and on success stamp date_of_birth + age_attested_at so every future
# entry passes the gate. Authoritative: the entry controllers re-check
# age_verification_pending? regardless, so this endpoint is the only writer but
# not the only guard.
class AgeVerificationsController < ApplicationController
  def create
    return render json: { verified: false, error: "Sign in first." }, status: :unauthorized unless current_user

    dob = parse_dob
    return render json: { verified: false, error: "Enter a valid date of birth." }, status: :unprocessable_entity if dob.nil?

    state    = geo_state
    min_age  = AgePolicy.minimum_age(state)

    # UNDERAGE IS A VERDICT, NOT AN ERROR, and `underage: true` is the whole
    # difference. The client used to refuse an under-age date itself and never
    # POST, so this branch only ever had to explain itself in prose. The engine's
    # birthday card submits every date and routes on THIS response: it opens the
    # age-gate card (which carries "watch instead" and "fix your birthday") when
    # it sees `underage: true` or a 403, and otherwise paints a red error line.
    # Without the flag a refused player gets the red line — the dead end the two
    # cards were split up to remove.
    #
    # The status stays 422. The engine accepts either signal, and other callers
    # already key on 422 for "this DOB was not accepted"; adding the flag is the
    # smaller blast radius than moving the status under them.
    unless AgePolicy.old_enough?(dob, state)
      return render json: {
        verified: false,
        underage: true,
        minimum_age: min_age,
        error: "You must be #{min_age}+ to enter contests#{state.present? ? " in #{state}" : ''}."
      }, status: :unprocessable_entity
    end

    rescue_and_log(target: current_user) do
      current_user.update!(date_of_birth: dob, age_attested_at: Time.current)
      render json: { verified: true }
    end
  rescue StandardError => e
    render json: { verified: false, error: e.message }, status: :unprocessable_entity
  end

  private

  # Accept either an ISO date string (`date_of_birth=YYYY-MM-DD`) or discrete
  # year/month/day fields (the modal sends the latter). Returns a Date or nil.
  def parse_dob
    if params[:date_of_birth].present?
      Date.iso8601(params[:date_of_birth].to_s)
    else
      y = params[:year].to_i
      m = params[:month].to_i
      d = params[:day].to_i
      return nil if y.zero? || m.zero? || d.zero?
      Date.new(y, m, d)
    end
  rescue ArgumentError, TypeError
    nil
  end
end
