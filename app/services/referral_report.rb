# The funnel behind /admin/referrals: for each reference (a `?reference=`
# name, a landing-page slug, a vanity path), how many clicked, how many left
# an email, and how many made an account, over a window of days.
#
#   clicks           ReferralVisit rows: one per visitor per reference per day
#   visitors         distinct visitor cookies among those rows
#   email signups    DropSignup.source, when that model and table exist
#   account signups  users.reference
#
# Rates are signups over visitors. They are funnel ratios, not cohort ones: an
# account created this week may have clicked last month, and is counted in the
# window it signed up in.
#
# DropSignup ships in its own task (turf-monster-v2-explainer). Until it is on
# the branch this runs against, the email column is absent rather than zero —
# "we don't collect that" and "nobody signed up" read differently.
class ReferralReport
  WINDOWS = { "7" => 7, "30" => 30, "all" => nil }.freeze
  DEFAULT_WINDOW = "30"
  TOP_PATHS = 3
  # The table lists this many references, most clicks first, and counts the
  # rest. Anyone can mint a reference by putting one in a link, so the list of
  # distinct references is not ours to bound; the table is.
  # (Admin::FreeEntriesController caps its free-text sources the same way.)
  TOP_REFERENCES = 50
  EMAIL_MODEL_NAME = "DropSignup"

  Row = Struct.new(:reference, :clicks, :visitors, :top_paths, :email_signups, :account_signups,
                   keyword_init: true) do
    def email_rate = ReferralReport.rate(email_signups, visitors)
    def account_rate = ReferralReport.rate(account_signups, visitors)
  end

  DayRow = Struct.new(:date, :clicks, :visitors, :email_signups, :account_signups, keyword_init: true)

  attr_reader :window, :email_model

  # The email-signup model when it exists and can answer by source, else nil.
  # Never raises: a missing class, table or column all read as "not here".
  def self.email_signup_model(name = EMAIL_MODEL_NAME)
    return nil unless Object.const_defined?(name)

    model = Object.const_get(name)
    return nil unless model.is_a?(Class) && model < ActiveRecord::Base
    return nil unless model.table_exists? && model.column_names.include?("source")

    model
  rescue StandardError
    nil
  end

  # Clicks per reference over everything kept (RETENTION), for just the names
  # given, in one grouped query. A name nobody clicked is absent, not zero.
  # /admin/short_links reads its click column from here.
  def self.clicks_for(references)
    refs = Array(references).filter_map { |ref| ReferralVisit.normalize_reference(ref) }.uniq
    return {} if refs.empty?

    ReferralVisit.where(reference: refs).group(:reference).count
  end

  # Percent, one decimal. nil when there is nothing to divide by.
  def self.rate(count, base)
    return nil if count.nil? || base.to_i.zero?

    (count.to_f / base * 100).round(1)
  end

  def self.normalize_window(value)
    WINDOWS.key?(value.to_s) ? value.to_s : DEFAULT_WINDOW
  end

  def initialize(window: DEFAULT_WINDOW, email_model: self.class.email_signup_model, today: Date.current)
    @window = self.class.normalize_window(window)
    @email_model = email_model
    @today = today
  end

  def emails?
    !email_model.nil?
  end

  def days
    WINDOWS[window]
  end

  # First day in the window, or nil for all time.
  def since_date
    days && (@today - (days - 1))
  end

  # The TOP_REFERENCES rows with the most clicks.
  def rows
    @rows ||= with_top_paths(all_rows.first(TOP_REFERENCES))
  end

  # How many references the table leaves out.
  def hidden_references
    [all_rows.size - TOP_REFERENCES, 0].max
  end

  # Over every reference, listed or not.
  def totals
    @totals ||= Row.new(
      reference: "All references",
      clicks: all_rows.sum(&:clicks),
      visitors: visits.distinct.count(:visitor_id),
      top_paths: [],
      email_signups: (emails? ? all_rows.sum { |r| r.email_signups.to_i } : nil),
      account_signups: all_rows.sum(&:account_signups)
    )
  end

  # Per-day rows for one reference, newest first. A bounded window lists every
  # day (zeros included, so a quiet day reads as quiet); "all" lists only days
  # with activity.
  def daily(reference)
    ref = ReferralVisit.normalize_reference(reference)
    return [] if ref.nil?

    ref_visits = visits.where(reference: ref)
    clicks = ref_visits.group(:visited_on).count
    visitors = ref_visits.group(:visited_on).distinct.count(:visitor_id)
    accounts = count_by_day(account_scope.where(normalized(User.arel_table[:reference]).eq(ref)))
    emails = emails? ? count_by_day(email_scope.where(normalized(email_model.arel_table[:source]).eq(ref))) : {}

    dates = since_date ? (since_date..@today).to_a : (clicks.keys | accounts.keys | emails.keys)

    dates.sort.reverse.map do |date|
      DayRow.new(date: date, clicks: clicks[date].to_i, visitors: visitors[date].to_i,
                 email_signups: (emails? ? emails[date].to_i : nil),
                 account_signups: accounts[date].to_i)
    end
  end

  private

  def visits
    ReferralVisit.since(since_date)
  end

  def since_time
    since_date&.beginning_of_day
  end

  def account_scope
    scope = User.where.not(reference: [nil, ""])
    since_time ? scope.where(created_at: since_time..) : scope
  end

  def email_scope
    scope = email_model.where.not(source: [nil, ""])
    since_time ? scope.where(created_at: since_time..) : scope
  end

  # The SQL twin of ReferralVisit.normalize_reference, so a raw "TikTok" on a
  # user groups with the "tiktok" clicks: LEFT(LOWER(TRIM(column)), 64), built
  # from Arel nodes so no SQL is assembled from strings.
  def normalized(attribute)
    fn = Arel::Nodes::NamedFunction
    fn.new("LEFT", [fn.new("LOWER", [fn.new("TRIM", [attribute])]),
                    Arel::Nodes.build_quoted(ReferralVisit::REFERENCE_LIMIT)])
  end

  def count_by_day(scope)
    scope.pluck(:created_at).each_with_object(Hash.new(0)) { |at, h| h[at.to_date] += 1 }
  end

  # Every reference, most clicks first, without top paths.
  def all_rows
    @all_rows ||= begin
      clicks = visits.group(:reference).count
      visitors = visits.group(:reference).distinct.count(:visitor_id)
      accounts = account_scope.group(normalized(User.arel_table[:reference])).count
      emails = emails? ? email_scope.group(normalized(email_model.arel_table[:source])).count : {}

      references = (clicks.keys | accounts.keys | emails.keys).compact
      references.map do |ref|
        Row.new(reference: ref, clicks: clicks[ref].to_i, visitors: visitors[ref].to_i,
                top_paths: [],
                email_signups: (emails? ? emails[ref].to_i : nil),
                account_signups: accounts[ref].to_i)
      end.sort_by { |r| [-r.clicks, -r.account_signups, -r.email_signups.to_i, r.reference] }
    end
  end

  # Fills top_paths for the listed rows only, in one query scoped to them.
  def with_top_paths(listed)
    paths = visits.where(reference: listed.map(&:reference)).group(:reference, :landing_path).count

    top_paths = Hash.new { |h, k| h[k] = [] }
    paths.sort_by { |(_, path), count| [-count, path.to_s] }.each do |(ref, path), count|
      top_paths[ref] << [path, count] if top_paths[ref].size < TOP_PATHS
    end

    listed.each { |row| row.top_paths = top_paths[row.reference] }
  end
end
