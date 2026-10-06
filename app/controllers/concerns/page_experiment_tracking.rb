# Puts a visitor into a PageExperiment's variant, keeps them there, and counts
# what they see. The page's action calls #assign_page_experiment; a short link
# bound to an experiment calls #resolve_experiment_assignment on its /l/ hop so
# the URL it redirects to names the variant (?v=<key>).
#
# STICKY PER VISITOR: the variant is stored in a first-party cookie per
# experiment, exp_<slug>, for PageExperiment::COOKIE_TTL. The visitor id the
# counts dedupe on is ReferralVisitTracking's referral_visitor cookie, set here
# when the visitor has none.
#
# COUNTING A VISIT (an ExperimentEvent "visit") needs what a ReferralVisit
# needs: a GET for an HTML page that is not a prefetch, from a client that is
# not a bot, carrying a visitor cookie that CAME BACK (only that proves the
# client keeps cookies; ReferralVisitTracking explains why). A visitor whose
# first request is the page itself has no returned cookie yet, so the page's
# own script sends the visit as a beacon (page_experiments.js), which carries
# the cookie this response set; the unique index folds the two into one row.
#
# Bots and link unfurlers see the control (or an explicit ?v=, so a shared
# variant link unfurls with that variant's title), get no cookie, and are
# never counted.
#
# NEVER BREAKS A PAGE: every path here rescues, reports through
# ReferralVisit.report_failure, and leaves the page on its default copy.
module PageExperimentTracking
  extend ActiveSupport::Concern

  VARIANT_PARAM = "v".freeze

  included do
    helper_method :page_experiment_assignment
  end

  private

  def page_experiment_assignment
    @page_experiment_assignment
  end

  # The variant this request renders on `path`'s page, or nil when no
  # experiment is running there. Records the visit when it can.
  def assign_page_experiment(path = request.path)
    experiment = PageExperiment.for_page(path)
    return nil unless experiment

    assignment = resolve_experiment_assignment(experiment)
    record_experiment_visit(assignment) if assignment
    @page_experiment_assignment = assignment
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment assignment skipped")
    nil
  end

  # The visitor's variant of `experiment`, stored in the sticky cookie when it
  # was drawn or named by ?v=. nil only on a failure.
  def resolve_experiment_assignment(experiment)
    explicit = params[VARIANT_PARAM]
    assignment = experiment.assign(
      param: (explicit if explicit.is_a?(String)),
      cookie: cookies[experiment.cookie_name],
      bot: ReferralVisit.bot?(request.user_agent)
    )
    if assignment.store?
      cookies[experiment.cookie_name] = { value: assignment.key, expires: PageExperiment::COOKIE_TTL,
                                          httponly: true, same_site: :lax }
      set_referral_visitor_cookie
    end
    assignment
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment assignment failed exp=#{experiment&.slug.inspect}")
    nil
  end

  def record_experiment_visit(assignment)
    return false unless assignment.counted?
    return false unless request.get? && referral_html_request? && !request.xhr? && !referral_prefetch_request?

    record_experiment_event(assignment.experiment.slug, assignment.key, ExperimentEvent::VISIT)
  end

  # One ExperimentEvent for this visitor, if the visitor cookie came back and
  # the client is under the per-address write cap. The reference is the one
  # this request names, else the visitor's first touch.
  def record_experiment_event(experiment_slug, variant_key, event)
    visitor_id = returned_referral_visitor_id
    return false if visitor_id.nil?
    return false unless Rack::Attack.referral_visit_allowed?(request)

    ExperimentEvent.record(experiment_slug: experiment_slug, variant_key: variant_key, event: event,
                           visitor_id: visitor_id, reference: attribution_param || cookies[:reference])
  end

  # The experiment and variant a conversion (a DropSignup, a new account) is
  # credited to: the newest experiment the visitor holds a valid variant
  # cookie for, running or not (the visitor saw it either way). {} for a
  # visitor in none. Spread into the create call: `**experiment_attribution`.
  def experiment_attribution
    slugs = request.cookies.keys.filter_map do |name|
      name.delete_prefix(PageExperiment::COOKIE_PREFIX) if name.start_with?(PageExperiment::COOKIE_PREFIX)
    end
    return {} if slugs.empty?

    PageExperiment.where(slug: slugs).includes(:variants).order(created_at: :desc, id: :desc).each do |experiment|
      variant = experiment.variant_for(request.cookies[experiment.cookie_name])
      return { experiment_slug: experiment.slug, variant_key: variant.key } if variant
    end
    {}
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment attribution skipped")
    {}
  end
end
