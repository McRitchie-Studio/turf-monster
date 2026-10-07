require "csv"

module Admin
  # The slate-drop "notify me" list (/turf-monster-v2's form): newest first, a
  # count per drop, a CSV of the full list, and the DROP ANNOUNCEMENT — a
  # preview of the email, the exact recipient count, and a Send that only an
  # admin can press, only after the drop (or with "send early" ticked), and
  # only by typing that count back (DropAnnouncement). Rows are never edited
  # here; sending stamps notified_at through each row's own atomic claim.
  class DropSignupsController < ApplicationController
    before_action :require_admin

    # The table on the page, not the export. The CSV is always the whole list.
    PAGE_LIMIT = 500

    def index
      @slate_key = params[:slate].presence || NextSlateDrop::SLATE_KEY
      scope = DropSignup.for_slate(@slate_key)
      @counts = DropSignup.group(:slate_key).count.sort_by { |key, _| key }.reverse

      respond_to do |format|
        format.html do
          @total = scope.count
          @signups = scope.recent.includes(:user).limit(PAGE_LIMIT)
        end
        format.csv do
          send_data to_csv(scope.includes(:user)),
                    filename: "drop-signups-#{@slate_key}-#{Date.current.iso8601}.csv",
                    type: "text/csv"
        end
      end
    end

    # GET /admin/drop_signups/announcement — preview, count, progress, Send.
    def announcement
      @announcement = DropAnnouncement.new
      @recipient_count = @announcement.recipient_count
      @progress = @announcement.progress
      @dropped = @announcement.dropped?
    end

    # POST /admin/drop_signups/announcement
    def send_announcement
      result = DropAnnouncement.new.send!(
        confirm_count: params[:confirm_count],
        early: params[:send_early] == "1"
      )
      message = "Queued the announcement for #{result[:queued]} #{'address'.pluralize(result[:queued])}."
      message += " #{result[:failed]} failed to queue and stay on the list; see ErrorLog." if result[:failed].positive?
      flash[result[:failed].positive? ? :alert : :notice] = message
      redirect_to admin_drop_signups_announcement_path
    rescue DropAnnouncement::Refusal => e
      redirect_to admin_drop_signups_announcement_path, alert: e.message
    end

    # GET /admin/drop_signups/announcement/preview?email=confirmation|announcement&variant=new_player|existing_player
    # The rendered HTML of one email, for the preview page's iframes. Built on
    # an UNSAVED signup, so it mints no magic link and its links read "preview".
    def announcement_preview
      kind = params[:email] == "confirmation" ? :confirmation : :announcement
      variant = DropSignupMailer::VARIANTS.include?(params[:variant]&.to_sym) ? params[:variant].to_sym : :new_player
      message = DropSignupMailer.public_send(kind, preview_signup(variant), variant: variant).message
      render html: (message.html_part || message).decoded.html_safe, layout: false # rubocop:disable Rails/OutputSafety
    end

    private

    def preview_signup(variant)
      if variant == :existing_player
        user = current_user
        DropSignup.new(email: user.email.presence || "player@example.com", user: user, slate_key: NextSlateDrop::SLATE_KEY)
      else
        DropSignup.new(email: "new-player@example.com", slate_key: NextSlateDrop::SLATE_KEY, source: "tiktok")
      end
    end

    CSV_HEADERS = %w[email slate_key source signed_up_at user notified_at confirmation_sent_at unsubscribed_at].freeze

    def to_csv(signups)
      CSV.generate do |csv|
        csv << CSV_HEADERS
        # Newest first, batched: find_each orders by id, which tracks created_at.
        signups.find_each(order: :desc) do |s|
          row = [s.email, s.slate_key, s.source, s.created_at.utc.iso8601, s.user&.email, s.notified_at&.utc&.iso8601,
                 s.confirmation_sent_at&.utc&.iso8601, s.unsubscribed_at&.utc&.iso8601]
          csv << row.map { |cell| csv_safe(cell) }
        end
      end
    end

    # CSV injection: a spreadsheet runs a cell that opens with = + - @ (or a tab
    # or CR) as a formula. `source` is client-supplied (?reference= or its
    # cookie) and an email's local part may open with = + -, so quote those.
    def csv_safe(value)
      value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
    end
  end
end
