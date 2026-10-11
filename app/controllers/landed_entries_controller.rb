# The player's answer to the landed-entry prompt (Entry::LandedHold).
#
#   POST /entries/:slug/landed/reauthorize   keep the entry; the verdict runs now
#   POST /entries/:slug/landed/decline       do not; the row waits for a person
#
# Neither sends, refunds or transfers anything. An admin impersonating the
# player is refused: the answer is the player's own.
class LandedEntriesController < ApplicationController
  before_action :require_authentication
  before_action :refuse_impersonated_answer
  before_action :set_entry

  def reauthorize
    @entry.answer_landed!("reauthorized")
    settled = @entry.resolve_landed!
    redirect_back_or_to root_path, notice: reauthorized_message(settled), status: :see_other
  rescue Entry::LandedHold::Refused => e
    redirect_back_or_to root_path, alert: e.message, status: :see_other
  end

  def decline
    @entry.answer_landed!("declined")
    redirect_back_or_to root_path, status: :see_other,
                                   notice: "Got it. This entry stays out, and you will not be charged again. " \
                                           "With any question, contact #{Entry::Payment::SUPPORT_EMAIL}."
  rescue Entry::LandedHold::Refused => e
    redirect_back_or_to root_path, alert: e.message, status: :see_other
  end

  private

  def refuse_impersonated_answer
    return unless impersonating?

    redirect_back_or_to root_path, alert: "Only the player can answer for their entry.", status: :see_other
  end

  def set_entry
    @entry = current_user.entries.find_by(slug: params[:slug])
    redirect_back_or_to(root_path, alert: "That entry was not found.", status: :see_other) unless @entry
  end

  def reauthorized_message(settled)
    name = @entry.contest.name
    if settled.confirmed?
      "You're in. Your entry for #{name} is live, and you were not charged again."
    elsif settled.pending?
      "Thanks. Your payment for #{name} is still confirming on Solana, so the entry is not live yet. " \
        "You will not be charged again."
    else
      "Thanks. Your entry for #{name} still did not go through. You will not be charged again. " \
        "With any question, contact #{Entry::Payment::SUPPORT_EMAIL}."
    end
  end
end
