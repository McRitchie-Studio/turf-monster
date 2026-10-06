# One PageExperiment's results, variant by variant, over a window of days:
# the side-by-side table on /admin/experiments/:slug.
#
#   visitors         distinct visitors with a `visit` event on that variant
#   hits             visit events: one per visitor per variant per day
#   CTA taps         `cta:<name>` events, one per visitor per CTA per day
#   email signups    DropSignup rows credited to the variant
#   account signups  users credited to the variant at signup
#
# Rates are per 100 visitors, as on /admin/referrals and for the same reason:
# a signup is dated by its own day, so a window can hold a signup whose visit
# fell before it.
#
# SIGNIFICANCE IS A HINT, AND AN HONEST ONE. Each variant's email-signup rate
# is compared with the control's by a two-proportion z-test (pooled, two-sided).
# No arm is called ahead until both have MIN_VISITORS and p < ALPHA; below
# that the hint says "not significant yet", whatever the rates look like. It is
# one pre-chosen metric on purpose: testing every column and reporting the best
# would find a "winner" in noise.
class ExperimentReport
  WINDOWS = ReferralReport::WINDOWS
  DEFAULT_WINDOW = "all"
  MIN_VISITORS = 100
  ALPHA = 0.05

  Row = Struct.new(:variant, :visitors, :hits, :ctas, :email_signups, :account_signups, keyword_init: true) do
    def key = variant.key
    def email_rate = ReferralReport.rate(email_signups, visitors)
    def account_rate = ReferralReport.rate(account_signups, visitors)
    def cta_rate(name) = ReferralReport.rate(ctas[name], visitors)
  end

  # p_value is nil when there is nothing to test (an empty arm).
  Significance = Struct.new(:variant_key, :p_value, :verdict, :label, keyword_init: true)

  attr_reader :experiment, :window

  def self.normalize_window(value)
    WINDOWS.key?(value.to_s) ? value.to_s : DEFAULT_WINDOW
  end

  # Two-sided p-value of a pooled two-proportion z-test of x1/n1 against
  # x2/n2, or nil when either sample is empty. Successes are capped at their
  # sample (a window can hold more signups than visitors; see the header).
  def self.two_proportion_p_value(x1, n1, x2, n2)
    n1 = n1.to_i
    n2 = n2.to_i
    return nil if n1 <= 0 || n2 <= 0

    x1 = x1.to_i.clamp(0, n1)
    x2 = x2.to_i.clamp(0, n2)
    pooled = (x1 + x2).to_f / (n1 + n2)
    se = Math.sqrt(pooled * (1 - pooled) * ((1.0 / n1) + (1.0 / n2)))
    return 1.0 if se.zero?

    z = ((x2.to_f / n2) - (x1.to_f / n1)) / se
    Math.erfc(z.abs / Math.sqrt(2))
  end

  def initialize(experiment, window: DEFAULT_WINDOW, today: Date.current)
    @experiment = experiment
    @window = self.class.normalize_window(window)
    @today = today
  end

  def since_date
    (days = WINDOWS[window]) && (@today - (days - 1))
  end

  def ctas
    ExperimentEvent::CTAS
  end

  def rows
    @rows ||= experiment.variants.map do |variant|
      Row.new(variant: variant,
              visitors: visitors[variant.key].to_i,
              hits: event_counts[[variant.key, ExperimentEvent::VISIT]].to_i,
              ctas: ctas.keys.index_with { |name| event_counts[[variant.key, "cta:#{name}"]].to_i },
              email_signups: email_counts[variant.key].to_i,
              account_signups: account_counts[variant.key].to_i)
    end
  end

  def control_row
    control_key = experiment.control_variant&.key
    rows.find { |row| row.key == control_key }
  end

  # One hint per non-control variant, keyed by variant key.
  def significance
    @significance ||= begin
      control = control_row
      rows.reject { |row| control.nil? || row.key == control.key }.to_h do |row|
        [row.key, compare(control, row)]
      end
    end
  end

  private

  def compare(control, row)
    p_value = self.class.two_proportion_p_value(control.email_signups, control.visitors, row.email_signups, row.visitors)
    enough = [control.visitors, row.visitors].min >= MIN_VISITORS
    verdict, label =
      if !enough
        [:not_yet, "Not significant yet: needs #{MIN_VISITORS} visitors in each arm"]
      elsif p_value.nil? || p_value >= ALPHA
        [:no_difference, "No significant difference (p = #{format_p(p_value)})"]
      elsif row.email_rate.to_f > control.email_rate.to_f
        [:ahead, "Ahead of control on email signups (p = #{format_p(p_value)})"]
      else
        [:behind, "Behind control on email signups (p = #{format_p(p_value)})"]
      end
    Significance.new(variant_key: row.key, p_value: p_value, verdict: verdict, label: label)
  end

  def format_p(value)
    return "n/a" if value.nil?

    value < 0.001 ? "< 0.001" : format("%.3f", value)
  end

  def events
    ExperimentEvent.where(experiment_slug: experiment.slug).since(since_date)
  end

  def visitors
    @visitors ||= events.where(event: ExperimentEvent::VISIT).group(:variant_key).distinct.count(:visitor_id)
  end

  def event_counts
    @event_counts ||= events.group(:variant_key, :event).count
  end

  def since_time
    since_date&.beginning_of_day
  end

  def credited(scope)
    scope = scope.where(experiment_slug: experiment.slug)
    scope = scope.where(created_at: since_time..) if since_time
    scope.group(:variant_key).count
  end

  def email_counts
    @email_counts ||= credited(DropSignup)
  end

  def account_counts
    @account_counts ||= credited(User)
  end
end
