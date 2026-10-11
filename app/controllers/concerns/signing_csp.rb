# The strict Content-Security-Policy for the pages that build, sign or submit
# a Solana transaction. Every other page keeps the app policy
# (config/initializers/content_security_policy.rb).
#
# On a signing page script-src drops 'unsafe-inline' and https:, lists the
# script hosts by name, and carries a per-request nonce: every inline <script>
# in app/views renders nonce="<%= content_security_policy_nonce %>". The
# nonce rides script-src only here; nonce_directives is empty app-wide, so no
# other page's header changes. 'unsafe-eval' stays while Alpine runs
# (engine-retires-alpine removes it).
#
# Report-only first. While config.x.signing_csp_enforced is false, a signing
# page enforces the app policy and reports the strict one in
# Content-Security-Policy-Report-Only. Set it true to enforce the strict one.
# Outside production the app policy is report-only already, so the strict one
# replaces it there in that one header.
#
# A browser applies the policy of the document it loaded, and a Turbo visit
# keeps that document. A visit from a signing page keeps its strict policy,
# and csp_nonce_carry gives the incoming scripts the document's nonce; a
# visit into a signing page from another keeps the app policy.
module SigningCsp
  extend ActiveSupport::Concern

  # controller_path => actions. The HTML pages of the signing flows: contest
  # entry and settle (contests#show and #contest), contest create and its
  # lock and conclusion times (#new, #generator, #edit), the wallet section
  # (accounts#show), the Phantom cosign queue (admin/pending_transactions),
  # and wallet sign-in (solana_sessions).
  PAGES = {
    "contests" => %w[show contest new generator edit],
    "accounts" => %w[show],
    "admin/pending_transactions" => %w[index],
    "solana_sessions" => %w[phantom_callback link_wallet]
  }.freeze

  NONCE_DIRECTIVES = %w[script-src].freeze

  included do
    after_action :apply_signing_csp, if: :signing_csp_page?
    helper_method :signing_csp_page?
  end

  # The app policy with script-src narrowed for a signing page.
  def self.strict(policy)
    policy.dup.tap { |strict| strict.script_src(*Rails.configuration.x.signing_csp_script_src) }
  end

  def self.enforced?
    Rails.configuration.x.signing_csp_enforced == true
  end

  private

  def signing_csp_page?
    PAGES.fetch(controller_path, []).include?(action_name)
  end

  # Writes the headers itself; the middleware then leaves them alone.
  def apply_signing_csp
    policy = request.content_security_policy or return
    nonce = request.content_security_policy_nonce
    strict = SigningCsp.strict(policy).build(self, nonce, NONCE_DIRECTIVES)
    app_report_only = request.content_security_policy_report_only

    if app_report_only || SigningCsp.enforced?
      header = app_report_only ? ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY : ActionDispatch::Constants::CONTENT_SECURITY_POLICY
      response.headers[header] = strict
    else
      response.headers[ActionDispatch::Constants::CONTENT_SECURITY_POLICY] = policy.build(self, nonce, [])
      response.headers[ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY] = strict
    end
  end
end
