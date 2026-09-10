# Minimum-age policy for entering skill-based contests, by US state.
#
# Mirrors the legal-age copy that the old signup attestation surfaced
# (studio/modals/shared/_age_attestation, studio-engine): 18+ in most
# states, 19+ in AL/NE, 21+ in
# IA/MA/VA. This is the authoritative server-side source — the entry gate
# (ContestsController) and AgeVerificationsController both compute against it;
# the client modal only renders the number for display.
#
# Age is computed in whole years against the user's DETECTED state (geo_state),
# never a client-supplied state — a VPN/spoof can't lower the bar.
module AgePolicy
  DEFAULT_MINIMUM_AGE = 18

  MINIMUM_AGE_BY_STATE = {
    "AL" => 19, "NE" => 19,
    "IA" => 21, "MA" => 21, "VA" => 21
  }.freeze

  # Minimum legal age for the given 2-letter state code (defaults to 18 for
  # unknown / nil — the most permissive bar, matching "most states").
  def self.minimum_age(state)
    MINIMUM_AGE_BY_STATE.fetch(state.to_s.strip.upcase, DEFAULT_MINIMUM_AGE)
  end

  # Whole-years age as of `today` (birthday-aware).
  def self.age_in_years(dob, today: Date.current)
    return nil if dob.nil?
    age = today.year - dob.year
    had_birthday = today.month > dob.month ||
                   (today.month == dob.month && today.day >= dob.day)
    age -= 1 unless had_birthday
    age
  end

  # True iff `dob` clears the state's minimum age. A nil/future DOB is never old
  # enough.
  def self.old_enough?(dob, state, today: Date.current)
    return false if dob.nil? || dob > today
    age = age_in_years(dob, today: today)
    age.present? && age >= minimum_age(state)
  end
end
