# The invitation Mr. McRitchie sends when he gifts a friend a free entry.
#
# Email type: TRANSACTIONAL in mechanism (one message, sent because a specific
# person typed a specific address into /admin/entry_gifts) but PERSONAL in
# voice, which is why it goes out from `marketing_from` — "Alex from Turf
# Monster" — rather than the house "Turf Monster" address. It is a note from a
# friend, and it should look like one in the inbox.
#
# Replies go to the SENDER, not to team@. Somebody who answers "wait, what is
# this?" should reach the person who invited them.
class EntryGiftMailer < ApplicationMailer
  layout "branded_mailer"

  def gift_invite(gift, token)
    @gift      = gift
    @sender    = gift.sender
    @note      = gift.note.presence
    @contest   = gift.landing_contest
    # The unified short link (Studio::LinksController) — the same /l/<token>
    # entry point the sign-in magic link uses, so the click flow's
    # scanner-safe GET → human POST consume applies here unchanged.
    @claim_url = link_url(token: token)

    # THE USERNAME, AS IT WAS WHEN THE GIFT WAS SENT.
    #
    # Two deliberate choices. It is the USERNAME and not `name` (operator call,
    # 2026-09-09) — the handle is who a player is on this platform, and the real
    # name is not what a friend would recognise in a lobby. And it is the
    # SNAPSHOT taken at send time, not a live read: usernames change, and a live
    # read would rewrite the greeting of every invite already sitting in an inbox
    # the moment someone renames. A gift is a fact about a moment.
    #
    # The live fallback is only for rows sent before the column existed. Still
    # never display_name — that falls back to the email local part, so an account
    # without a handle would introduce itself as a fragment of an address.
    @sender_name = gift.sender_username.presence ||
                   @sender.username.presence ||
                   "A friend"

    @banner_url = Studio::EmailCatalog.resolved_url(:entry_gift_invite)
    @banner_alt = "You've been given a free entry"

    mail(to: gift.recipient_email,
         from: marketing_from,
         reply_to: @sender.email.presence,
         subject: "#{@sender_name} sent you a free entry to Turf Monster ✨")
  end
end
