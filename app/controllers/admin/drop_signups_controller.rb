require "csv"

module Admin
  # The slate-drop "notify me" list (/turf-monster-v2's form). Read-only:
  # newest first, a count per drop, and a CSV of the full list for whoever sends
  # the drop email. Rows are never edited here; nothing in the app sends to them
  # yet, so `notified_at` reads blank until that sender exists.
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

    private

    CSV_HEADERS = %w[email slate_key source signed_up_at user notified_at].freeze

    def to_csv(signups)
      CSV.generate do |csv|
        csv << CSV_HEADERS
        # Newest first, batched: find_each orders by id, which tracks created_at.
        signups.find_each(order: :desc) do |s|
          row = [s.email, s.slate_key, s.source, s.created_at.utc.iso8601, s.user&.email, s.notified_at&.utc&.iso8601]
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
