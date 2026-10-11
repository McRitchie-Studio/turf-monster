# The landed-entry prompt's rows and words (Entry::LandedHold,
# shared/_landed_entry_prompt). Read once per render, and never while an admin
# impersonates the player.
module LandedEntryPromptHelper
  # Why the entry could not be finished, by refusal code. Anything else gets
  # the general sentence.
  LANDED_REASONS = {
    "contest_full" => "the contest filled before we could finish your entry",
    "entry_limit_reached" => "this contest's entry limit was reached before we could finish your entry"
  }.freeze
  LANDED_REASON_DEFAULT = "we could not finish your entry".freeze

  def landed_entry_prompts
    return [] unless logged_in? && !impersonating?

    @landed_entry_prompts ||= Entry.landed_prompts_for(current_user)
  end

  def landed_entry_reason(entry)
    LANDED_REASONS.fetch(entry.payment_refusal_code.to_s, LANDED_REASON_DEFAULT)
  end

  # "Sun, Oct 11 at 9:00 AM ET"
  def landed_entry_deadline(entry)
    entry.landed_hold_expires_at.in_time_zone(Entry::LandedHold::ZONE).strftime("%a, %b %-d at %-l:%M %p ET")
  end
end
