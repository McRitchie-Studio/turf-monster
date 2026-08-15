# Newsletter subscription — the contest-card quest's second mission
# ("Join Newsletter, get 25 seeds"). Authed by the global require_authentication.
#
# Web2 users one-click (email already on file). Web3 (Phantom) users have no
# email, so the quest opens a secondary modal that POSTs the captured `email`
# here — we fill the blank account email (newsletter-only; NOT auto-verified for
# login, per the operator's call).
#
# Reward: the FIRST-EVER join mints 25 seeds on-chain via Solana::Vault#grant_seeds
# (kind: :newsletter). The on-chain [b"seed_grant", wallet, NEWSLETTER] guard PDA
# is the hard once-ever guard — leave/rejoin (left_email_list_at vs
# joined_email_list_at) never re-pays. The subscription is the durable fact; if
# the grant can't run yet (instruction not deployed / RPC blip) the join still
# succeeds and the bonus is backfillable (the guard PDA prevents any double-grant).
class NewsletterController < ApplicationController
  # POST /account/newsletter/subscribe
  def subscribe
    user = current_user
    first_join = user.joined_email_list_at.nil?

    # Web3 email capture — fill the (blank) account email, newsletter-only.
    if user.email.blank?
      email = params[:email].to_s.strip.downcase
      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        return render json: { success: false, error: "Enter a valid email address." },
                      status: :unprocessable_entity
      end
      user.email = email
    end

    rescue_and_log(target: user) do
      user.update!(joined_email_list_at: Time.current, left_email_list_at: nil)
      Studio::Email.deliver(NewsletterMailer, :welcome, user, to: user.email, user: user) if first_join && user.email.present?
      payload = first_join ? grant_newsletter_seeds(user) : nil
      render json: { success: true, subscribed: true, email: user.email }.merge(payload || {})
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, error: e.record.errors.full_messages.first || e.message },
           status: :unprocessable_entity
  rescue => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # POST /account/newsletter/unsubscribe — sets left_email_list_at (no re-pay on
  # a later rejoin; the once-ever on-chain guard already enforces that).
  def unsubscribe
    rescue_and_log(target: current_user) do
      current_user.update!(left_email_list_at: Time.current)
      render json: { success: true, subscribed: false }
    end
  rescue => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  private

  # First-ever newsletter join → 25 seeds on-chain. Returns the StateFanout
  # 'seeds' payload ({ seeds_earned, seeds_total, seeds_level }) so the client can
  # run the same tick-up + level-up animation as a contest entry, or nil if the
  # grant can't run yet (deferred + backfillable — the subscription still stands).
  #
  # MOVED TO NewsletterSeedGrant because this is no longer the only way to join.
  # The shared /profile page subscribes through the engine, which reaches this app
  # via Studio.after_newsletter_change — a lambda in an initializer, which cannot
  # call a private controller method. One implementation, two callers; see the
  # service for why a second copy would drift.
  def grant_newsletter_seeds(user)
    NewsletterSeedGrant.call(user)
  end
end
