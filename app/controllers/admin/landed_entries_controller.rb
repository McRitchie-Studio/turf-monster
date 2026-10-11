module Admin
  # The operator's queue of paid entries an app gate refused (Entry::LandedHold).
  #
  #   GET  /admin/landed_entries                every landed row, with its hold
  #                                             and the player's answer
  #   POST /admin/landed_entries/:slug/replace  the operator's go: the verdict
  #                                             activates the row from its own
  #                                             ticket, with no new payment
  #
  # Replace is refused inside the hold (unless the player re-authorized) and on
  # a declined row. Nothing here sends, refunds or transfers.
  class LandedEntriesController < ApplicationController
    before_action :require_admin

    def index
      @entries = Entry.where(status: "cart", payment_state: "landed").includes(:user, :contest).order(:id)
    end

    def replace
      entry = Entry.find_by(slug: params[:slug])
      return redirect_to(admin_landed_entries_path, alert: "No such entry.", status: :see_other) unless entry

      entry.authorize_landed_replacement!(true_user)
      settled = entry.resolve_landed!
      redirect_to admin_landed_entries_path, status: :see_other, **replace_flash(entry, settled)
    rescue Entry::LandedHold::Refused => e
      redirect_to admin_landed_entries_path, alert: e.message, status: :see_other
    end

    private

    def replace_flash(entry, settled)
      if settled.confirmed?
        { notice: "#{entry.slug} is live. Nothing was paid again." }
      elsif settled.pending?
        { notice: "#{entry.slug}: the chain could not be read; the settle job is asking again." }
      else
        { alert: "#{entry.slug} is still held: #{settled.code || entry.reload.payment_refusal_code}." }
      end
    end
  end
end
