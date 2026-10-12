# The strict Content-Security-Policy for the pages that build, sign or submit
# a Solana transaction, or show a wallet's key. Every other page keeps the app
# policy (config/initializers/content_security_policy.rb).
#
# On a signing page script-src drops 'unsafe-inline' and https:, names each
# third-party script by file, and carries a per-request nonce: every inline <script>
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
#
# A failed save re-renders a signing template (accounts#update renders :show,
# contests#update renders :edit). Its form posts natively (data-turbo false),
# so the re-render is a document of its own under the nonce it was rendered
# with. The action is listed here so that document gets the strict policy,
# and so a Turbo submission of it reloads rather than rendering in place
# under the old document's nonce. test/integration/signing_csp_test.rb holds
# both halves: every action that renders a signing template is listed, and
# every form on a signing page that posts to a listed action is not Turbo.
#
# WHAT AN ACTION LIST CANNOT COVER. The layout renders the wallet modals
# (wallet_op_runner, wallet_setup, the contest and username intents) on every
# page, and they sign from whatever page opens them. Off this list they run
# under the app policy, as they do today; only a layout-wide policy would
# cover them.
module SigningCsp
  extend ActiveSupport::Concern

  # controller_path => actions. The HTML pages of the signing flows: contest
  # entry and settle (contests#show, #contest and the admin view #admin, the
  # three that carry the Phantom-signed Lock buttons), the live board (#live:
  # #show sends everyone there once a game starts, so it is the contest's page
  # during play; its compact leaderboard has no Lock buttons), contest create
  # and its lock and conclusion times (#new, #generator, #edit, and #update,
  # which re-renders #edit on a failed save), the wallet section
  # (accounts#show, #update for its failed save, and the engine's profile page),
  # cash-out (wallets#show, #sync, which renders it, and the Coinbase offramp
  # return, cdp/returns#offramp, where the send modal opens), the key export
  # (wallet_exports#show), the Phantom cosign pages (the treasury queue,
  # signer eviction, vault init and pause), and wallet sign-in
  # (solana_sessions).
  PAGES = {
    "contests" => %w[show contest admin live new generator edit update],
    "accounts" => %w[show update],
    "studio/profiles" => %w[show],
    "wallets" => %w[show sync],
    "cdp/returns" => %w[offramp],
    "wallet_exports" => %w[show],
    "admin/pending_transactions" => %w[index],
    "admin/authorities" => %w[show],
    "admin/vault_init" => %w[show],
    "admin/vault_state" => %w[show],
    "solana_sessions" => %w[phantom_callback link_wallet]
  }.freeze

  # Inline script a gem still renders without the nonce on a signing page.
  # Each is open only while the LOCKED gem's file still matches `unfixed`, so
  # it lapses the day the lock takes the fixed release. Enforcing the strict
  # policy while one is open refuses that script (today: the wallet picker
  # loses its mobile Phantom row), so the enforce switch must stay off until
  # none is open: test/controllers/concerns/signing_csp_test.rb fails
  # otherwise. test/integration/signing_csp_test.rb excuses an open item's
  # script and nothing else.
  PendingGemFix = Struct.new(:gem, :file, :unfixed, :script, :handler, :fixed_by, keyword_init: true) do
    def open?
      File.read(File.join(Gem.loaded_specs.fetch(gem).full_gem_path, file)).match?(unfixed)
    end
  end

  # `unfixed` spells the tag <[s]cript> so test/views/alpine_and_inline_script_ratchet_test.rb
  # does not count this pattern as an inline script of the app's own.
  PENDING_GEM_FIXES = [
    PendingGemFix.new(gem: "solana-studio", file: "app/views/solana_studio/_phantom_deeplink.html.erb",
                      unfixed: /^<[s]cript>$/, script: /window\.startPhantomDeepLink\s*=/,
                      fixed_by: "the solana-studio release after 0.12.4 (the deep-link nonce)")
  ].freeze

  NONCE_DIRECTIVES = %w[script-src].freeze
  # signing_document sets it on every Turbo fetch a signing page makes.
  DOCUMENT_HEADER = "X-Signing-Document".freeze
  REPORT_PATH = "/csp_reports".freeze

  included do
    after_action :apply_signing_csp, if: :signing_csp_page?
    after_action :keep_flash_for_the_full_load, if: :fetched_by_a_signing_document?
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

  # The gem fixes still open in the locked gems.
  def self.pending_gem_fixes
    PENDING_GEM_FIXES.select(&:open?)
  end

  # What enforcing would break: the open gem fixes, when the switch is on.
  def self.enforce_blockers(enforced: enforced?, pending: pending_gem_fixes)
    enforced ? pending : []
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
  #
  # The same holds for any page a signing page's form redirects to (contest
  # edit's save lands on /contests): the redirect is followed inside the
  # fetch, and signing_document then leaves by a full load of that page. The
  # header marks the fetch; only a GET is the followed redirect.
  def keep_flash_for_the_full_load
    flash.keep if request.headers["X-Turbo-Request-Id"].present?
  end

  def fetched_by_a_signing_document?
    request.get? && request.headers[DOCUMENT_HEADER] == "strict" && !signing_csp_page?
  end

  # Writes the headers itself; the middleware then leaves them alone. No
  # no-store: it would keep a signing page out of the back/forward cache,
  # which the wallet handoff's swipe back relies on.
  def apply_signing_csp
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
