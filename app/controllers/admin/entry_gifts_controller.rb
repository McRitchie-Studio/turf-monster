module Admin
  # "Send my friend a free entry." One form, one ledger.
  #
  # ADMIN-ONLY, and that is a product decision rather than a convenience: every
  # gift mints a real on-chain EntryTokenAccount and spends admin SOL rent on it.
  # A player-facing version of this page needs per-user caps, an abuse story and
  # a spend budget; an operator-facing one needs none of those, because the
  # operator IS the budget. Mr. McRitchie's call, 2026-09-08.
  class EntryGiftsController < ApplicationController
    before_action :require_admin

    PER_PAGE = 50

    def index
      @gifts    = EntryGift.recent.includes(:sender, :contest, :claimed_by).limit(PER_PAGE)
      @contests = Contest.order(created_at: :desc).limit(25)
      @default_contest = Contest.featured
      @counts = {
        sent:    EntryGift.count,
        claimed: EntryGift.where.not(claimed_at: nil).count,
        minted:  EntryGift.where.not(minted_at: nil).count
      }
    end

    def create
      gift = EntryGift.new(
        recipient_email: params[:recipient_email],
        contest:         Contest.find_by(slug: params[:contest_slug].presence),
        note:            params[:note].to_s.strip.presence,
        sender:          current_user
      )

      # Bad form input is not an incident — bounce with a flash, don't 500.
      unless gift.save
        flash[:alert] = "Could not send: #{gift.errors.full_messages.to_sentence}"
        return redirect_to admin_entry_gifts_path
      end

      rescue_and_log(target: gift) do
        deliver_invite(gift)
        flash[:notice] = "Free entry sent to #{gift.recipient_email}."
      end
      redirect_to admin_entry_gifts_path
    rescue StandardError => e
      # The row survives a delivery failure ON PURPOSE — it is the record that
      # this gift was attempted, and #resend is what finishes it. Destroying it
      # here would lose that, and would also lose the mint_ref, which is the one
      # value that must never be re-rolled for a gift that may already be part
      # way out the door.
      flash[:alert] = "Saved the gift but could not send the email: #{e.message}"
      redirect_to admin_entry_gifts_path
    end

    # Re-send an UNCLAIMED gift. Mints a FRESH link and lets the old one die:
    # magic links are single-use, so reusing the previous token would hand out a
    # second live credential for the same address rather than replacing it.
    def resend
      gift = EntryGift.find(params[:id])
      if gift.claimed?
        flash[:alert] = "#{gift.recipient_email} already claimed this gift."
        return redirect_to admin_entry_gifts_path
      end

      rescue_and_log(target: gift) do
        gift.link&.destroy
        deliver_invite(gift.reload)
        flash[:notice] = "Re-sent to #{gift.recipient_email} with a fresh link."
      end
      redirect_to admin_entry_gifts_path
    end

    # Re-run the mint for a claimed gift whose token never landed. Safe to press
    # repeatedly: EntryGift#mint_source_ref is deterministic, so the program's
    # `init` refuses a duplicate and EntryGiftMintJob reads the chain back rather
    # than treating that refusal as a failure.
    def retry_mint
      gift = EntryGift.find(params[:id])
      if !gift.claimed?
        flash[:alert] = "#{gift.recipient_email} hasn't claimed this gift yet — nothing to mint."
      elsif gift.minted?
        flash[:alert] = "Already minted for #{gift.recipient_email}."
      else
        gift.update_columns(mint_error: nil, updated_at: Time.current)
        EntryGiftMintJob.perform_later(gift.id)
        flash[:notice] = "Re-queued the mint for #{gift.recipient_email}."
      end
      redirect_to admin_entry_gifts_path
    end

    private

    # Mint the link, then mail it. The link is minted HERE rather than in the
    # model because its return_to is a ROUTE, and a model that builds paths is a
    # model that cannot be tested without the router.
    #
    # `age_attested: false` is honest and deliberate. The operator cannot attest
    # to a stranger's age, and this app's standing rule is that it never records
    # an attestation the user was not actually shown (see AppFlags
    # .age_attestation?). The cost is real and named on the form: while
    # ENABLE_AGE_ATTESTATION is on, a gift link cannot CREATE an account — it
    # bounces to /signin for a self-requested link. The flag is off by default.
    def deliver_invite(gift)
      contest = gift.landing_contest
      link = ::Studio::Link.create_magic_link(
        email:        gift.recipient_email,
        return_to:    (contest ? contest_path(contest) : nil),
        linkable:     gift,
        ttl:          EntryGift::LINK_TTL,
        age_attested: false
      )

      Studio::Email.deliver(EntryGiftMailer, :gift_invite, gift, link.token,
                            to: gift.recipient_email)
    end
  end
end
