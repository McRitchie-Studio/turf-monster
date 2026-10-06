# The two emails a slate-drop "notify me" signup (DropSignup) ever gets:
#
#   confirmation  — "You're on the list", queued once when the address joins
#                   (DropSignupsController#create → DropSignup#deliver_confirmation!)
#   announcement  — "The slate is live", queued once per address when an admin
#                   presses Send on /admin/drop_signups/announcement
#                   (DropAnnouncementJob → DropSignup#deliver_announcement!)
#
# TWO VARIANTS OF EACH, CHOSEN AT SEND TIME. The outbox job renders the mail
# when it runs, which can be after the visitor made an account, so the variant
# is read here and never stored on the row or passed in from the enqueue:
#
#   :new_player       no account holds this address. The primary CTA is a
#                     single-use magic link (Studio::Link, the email in its
#                     metadata) into turf's REAL create-or-login flow:
#                     MagicLinksController#sign_up_new, with its legal-age and
#                     onboarding chain (first name → age → wallet). Clicking it
#                     from this inbox proves the address. The link carries the
#                     signup's own `source` as ?reference=, so the account it
#                     creates is credited to the campaign that brought them.
#                     An EXPIRED link falls back to /signin with the address
#                     prefilled (MagicLinksController#link_login_path).
#   :existing_player  an account already holds it (the signed-in visitor's own,
#                     or a case-insensitive address match). No sign-up language.
#
# The web response to the form is identical either way; only the address's own
# inbox learns whether it has an account.
#
# Every message carries a one-click unsubscribe: a body link plus the
# List-Unsubscribe / List-Unsubscribe-Post headers (RFC 8058).
#
# PREVIEWS pass an unsaved DropSignup and a forced `variant:`. An unsaved row
# mints nothing: the magic link and the unsubscribe link read "preview".
class DropSignupMailer < ApplicationMailer
  layout "branded_mailer"

  VARIANTS = %i[new_player existing_player].freeze
  PREVIEW_TOKEN = "preview".freeze

  def confirmation(signup, variant: nil)
    prepare(signup, variant)
    @how_to_play_url = turf_monster_v2_url(anchor: "how-to-play")

    if new_player?
      @primary_label = "Finish setting up your account"
      @primary_url   = magic_link_for(signup, return_to: nil)
      @secondary_label = "Get ready: how to play"
      @secondary_url   = @how_to_play_url
    else
      @primary_label = "Get ready for #{@label}"
      @primary_url   = @how_to_play_url
      @secondary_label = "View contests"
      @secondary_url   = contests_url
    end

    mail(to: signup.email, subject: "You're on the list for #{@label}")
  end

  def announcement(signup, variant: nil)
    prepare(signup, variant)
    # The next NFL contest a visitor can still enter, else the explainer.
    # (Mailers get *_url helpers only, so the path for the magic link's
    # return_to comes from the route set directly.)
    contest = NextContest.pick.contest
    routes = Rails.application.routes.url_helpers
    play_path = contest ? routes.contest_path(contest.slug) : routes.turf_monster_v2_path

    if new_player?
      @primary_label = "Create your account and play"
      @primary_url   = magic_link_for(signup, return_to: play_path)
    else
      @primary_label = "Play Turf Monster"
      reference = { reference: NextSlateDrop::EMAIL_REFERENCE }
      @primary_url = contest ? contest_url(contest.slug, **reference) : turf_monster_v2_url(**reference)
    end

    mail(to: signup.email, from: marketing_from, subject: "#{@label} is live")
  end

  private

  def prepare(signup, variant)
    @signup  = signup
    @label   = NextSlateDrop.display_label
    @drops_at_label = NextSlateDrop.drops_at_label
    @variant = resolve_variant(signup, variant)
    @unsubscribe_url = drop_unsubscribe_url(signup.persisted? ? signup.unsubscribe_token : PREVIEW_TOKEN)

    headers["List-Unsubscribe"] = "<#{@unsubscribe_url}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
  end

  def resolve_variant(signup, forced)
    return forced.to_sym if forced && VARIANTS.include?(forced.to_sym)

    signup.existing_account? ? :existing_player : :new_player
  end

  def new_player?
    @variant == :new_player
  end

  # A fresh single-use magic link for this address, minted when the mail is
  # rendered (so it is live when it lands). `age_attested: false` on purpose:
  # nobody here attested for the recipient, so when ENABLE_AGE_ATTESTATION is
  # on, sign_up_new sends them to /signin (address prefilled) to tick the box
  # themselves — the same contract EntryGift links keep. `linkable` ties the
  # link to its signup, which is how the expired-link fallback knows to prefill.
  def magic_link_for(signup, return_to:)
    token = if signup.persisted?
              Studio::Link.create_magic_link(email: signup.email, return_to: return_to,
                                             age_attested: false, linkable: signup).token
            else
              PREVIEW_TOKEN
            end
    reference = signup.source.presence || NextSlateDrop::EMAIL_REFERENCE
    link_url(token: token, reference: reference) # the unified /l/<token> (Studio::LinksController < MagicLinksController), as UserMailer#magic_link
  end
end
