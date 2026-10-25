# Locals for the newsletter cards, which are the engine's
# (studio/profiles/_newsletter_modals) from studio-engine 0.114.0.
#
# This app carried its own five copies until 0.114.0 gave the engine partial a
# store, a JSON submit, a consent card, a success slot and a goodbye beat
# (turf-readopts-engine-modals). What stays here is what the engine leaves to a
# host on purpose: this app's ids, routes, copy and the success card's next step.
#
#   ids          unchanged, so every opener keeps working: the /account and
#                /profile row, the gear sidebar, the quest factory and the style
#                guide all open these by id.
#   routes       this app's JSON endpoints, not the engine's profile form. Both
#                are POST (config/routes.rb), so the unsubscribe verb is POST.
#   fetcher      authedFetch, through the "studio/host_fetchers" pin
#                (app/javascript/host_fetchers.js): a 401 opens sign-in and a 429
#                the rate-limit card, as the deleted copies did by hand.
#   event        newsletter-state-changed, the name the account card's
#                newsletter-state controller and the seeds listener in
#                shared/_alpine_factories bind to.
#   success slot modals/_newsletter_success_next: the first-join seeds bar and the
#                Next Quest or Check Out Contests button.
module NewsletterModalHelper
  NEWSLETTER_CHANGED_EVENT = "newsletter-state-changed".freeze

  def newsletter_modal_locals
    {
      user:              current_user,
      modal_store:       "modals",
      submit_mode:       :json,
      subscribe_url:     newsletter_subscribe_path,
      unsubscribe_url:   newsletter_unsubscribe_path,
      unsubscribe_method: "POST",
      fetcher:           "authedFetch",
      changed_event:     NEWSLETTER_CHANGED_EVENT,
      subscribe_card: {
        id: "newsletter-subscribe",
        title: "Join the Newsletter",
        subtitle: "Sports news and contest updates — and 25 seeds for joining.",
        consent: "Subscribe to the Turf Monster newsletter"
      },
      # Reached only through the quest factory's needsEmail branch, which passes
      # props.onSubmit: the card hands the address back and posts nothing.
      email_card: {
        id: "newsletter-email",
        title: "One more thing",
        subtitle: "Drop your email to join the list and claim your 25 seeds. We only use it for the newsletter.",
        header: { size: :md, icon_emoji: "📬" },
        button: "Join & Claim 25 Seeds",
        cancel: "Close"
      },
      success_card: {
        id: "newsletter-success",
        title: "Subscribed!",
        subtitle: "You're on the list. We'll keep the sports news and contest updates coming.",
        header: { icon_emoji: "🌱" },
        partial: "modals/newsletter_success_next"
      },
      unsubscribe_card: {
        id: "unsubscribe-confirm",
        subtitle: "Are you sure? You'll stop getting sports news and contest updates.",
        cancel: "Close"
      },
      goodbye_card: {
        id: "unsubscribe-goodbye",
        header: { icon_emoji: "✌️" },
        subtitle: "You're off the list. Change your mind anytime from your account."
      }
    }
  end
end
