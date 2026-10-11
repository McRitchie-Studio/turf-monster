# The strict Content-Security-Policy for the pages that build, sign or submit
# a Solana transaction, or show a wallet's key. Every other page keeps the app
# policy (config/initializers/content_security_policy.rb).
#
# On a signing page script-src drops 'unsafe-inline' and https:, lists the
# script hosts by name, and carries a per-request nonce: every inline <script>
# in app/views renders nonce="<%= content_security_policy_nonce %>". The
# nonce rides script-src only here; nonce_directives is empty app-wide, so no
# other page's header changes. 'unsafe-eval' stays while Alpine runs
# (engine-retires-alpine removes it). Violations go to CspReportsController.
#
# Report-only first. While config.x.signing_csp_enforced is false, a signing
# page reports the strict policy in Content-Security-Policy-Report-Only and
# enforces the app policy where the app enforces it (production). Set it true
# to enforce the strict policy, in every environment.
#
# A browser applies the policy of the document it loaded, and a Turbo visit
# keeps that document, so a signing page is always its own document:
# signing_csp_meta_tags renders turbo-visit-control reload (Turbo enters it by
# a full load) and the signing-csp marker, which signing_document reads to
# leave by a full load too and to strip scripts from frames and streams.
module SigningCsp
  extend ActiveSupport::Concern

  # controller_path => actions. The HTML pages of the signing flows: contest
  # entry and settle (contests#show and #contest), contest create and its
  # lock and conclusion times (#new, #generator, #edit), the wallet section
  # (accounts#show and the engine's profile page), cash-out (wallets#show),
  # the key export (wallet_exports#show), the Phantom cosign pages (the
  # treasury queue, signer eviction, vault init and pause), and wallet
  # sign-in (solana_sessions).
  PAGES = {
    "contests" => %w[show contest new generator edit],
    "accounts" => %w[show],
    "studio/profiles" => %w[show],
    "wallets" => %w[show],
    "wallet_exports" => %w[show],
    "admin/pending_transactions" => %w[index],
    "admin/authorities" => %w[show],
    "admin/vault_init" => %w[show],
    "admin/vault_state" => %w[show],
    "solana_sessions" => %w[phantom_callback link_wallet]
  }.freeze

  NONCE_DIRECTIVES = %w[script-src].freeze
  REPORT_PATH = "/csp_reports".freeze

  included do
    after_action :apply_signing_csp, if: :signing_csp_page?
    helper_method :signing_csp_page?, :signing_csp_meta_tags
  end

  # The app policy with script-src narrowed for a signing page, reporting to
  # CspReportsController.
  def self.strict(policy)
    policy.dup.tap do |strict|
      strict.script_src(*Rails.configuration.x.signing_csp_script_src)
      strict.report_uri(REPORT_PATH)
    end
  end

  def self.enforced?
    Rails.configuration.x.signing_csp_enforced == true
  end

  private

  def signing_csp_page?
    PAGES.fetch(controller_path, []).include?(action_name)
  end

  def signing_csp_meta_tags
    return unless signing_csp_page?

    helpers.safe_join([
      helpers.tag.meta(name: "turbo-visit-control", content: "reload"),
      helpers.tag.meta(name: "signing-csp", content: "strict")
    ])
  end

  # A Turbo fetch of a signing page is never rendered: Turbo, or
  # signing_document, answers it with a full load of the same page. A form's
  # redirect lands here inside that fetch, so the flash it set would be spent
  # on a body nobody sees; keep it for the full load.
  def keep_flash_for_the_full_load
    flash.keep if request.headers["X-Turbo-Request-Id"].present?
  end

  # Writes the headers itself; the middleware then leaves them alone. Never
  # stored: Back to a signing page is a fresh load (it is never in Turbo's
  # cache), and a stored copy would show the cart as it was first rendered.
  def apply_signing_csp
    no_store
    keep_flash_for_the_full_load
    policy = request.content_security_policy or return
    nonce = request.content_security_policy_nonce
    strict = SigningCsp.strict(policy).build(self, nonce, NONCE_DIRECTIVES)

    if SigningCsp.enforced?
      response.headers[ActionDispatch::Constants::CONTENT_SECURITY_POLICY] = strict
    else
      unless request.content_security_policy_report_only
        response.headers[ActionDispatch::Constants::CONTENT_SECURITY_POLICY] = policy.build(self, nonce, [])
      end
      response.headers[ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY] = strict
    end
  end
end
