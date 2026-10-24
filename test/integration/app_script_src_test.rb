require "test_helper"

# [unit] The app policy's script-src names every remote script source instead
# of https: (RemoteScriptSources, config/initializers/content_security_policy.rb).
#
# QA runs this policy report-only, so a host missing from the list is a block
# nobody sees until production. Three halves: the header carries exactly the
# named list on a layout page, a signing page, a slate page and a tokens page;
# every remote script the source can load is covered by the list; and the
# PayPal SDK the tokens page injects is covered when, and only when, PayPal is
# the payment provider.
class AppScriptSrcTest < ActionDispatch::IntegrationTest
  REPORT_ONLY = ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY
  ENFORCED = ActionDispatch::Constants::CONTENT_SECURITY_POLICY

  # Written out, not read from RemoteScriptSources, so a change to the list is
  # a change to this test too.
  REMOTE = %w[
    https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js
    https://unpkg.com/@solana/web3.js@1.98.4/lib/index.iife.min.js
    https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js
    https://cdn.logr-in.com
  ].freeze
  PAYPAL = %w[https://*.paypal.com https://*.paypalobjects.com].freeze
  EXPECTED = [ "'self'", *REMOTE, "'unsafe-inline'", "'unsafe-eval'" ].freeze

  setup do
    @slate = Slate.create!(name: "Script Src Test", slug: "script-src-test")
  end

  def script_src(header)
    header.split(";").map(&:strip).find { |directive| directive.start_with?("script-src ") }.split(" ").drop(1)
  end

  # A CSP source expression against a URL, as a browser matches one: a source
  # with no path matches its host (a leading *. any subdomain of it); a source
  # with a path matches that file exactly.
  def self.covers?(source, url)
    return false unless source.start_with?("https://")

    want = URI(source.sub("*.", "wildcard."))
    got = URI(url)
    host_ok = source.include?("*.") ? got.host.end_with?(want.host.delete_prefix("wildcard")) : got.host == want.host
    host_ok && (want.path.empty? || want.path == "/" || want.path == got.path)
  end

  def self.covered?(sources, url) = sources.any? { |source| covers?(source, url) }

  # name => [path, who]. Each page renders the app layout.
  def pages
    {
      "layout" => [ "/help", nil ],
      "signing" => [ contest_path(contests(:one)), users(:jordan) ],
      "slate" => [ slate_path(@slate), users(:alex) ],
      "tokens" => [ tokens_buy_path, users(:jordan) ]
    }
  end

  def with_production_headers
    env = Rails.application.env_config
    key = "action_dispatch.content_security_policy_report_only"
    was = env[key]
    env[key] = false
    yield
  ensure
    env[key] = was
  end

  test "the app policy names each remote script source and nothing broader" do
    built = script_src(Rails.application.config.content_security_policy.build(nil, nil, []))
    assert_equal EXPECTED, built
    assert_not_includes built, "https:"
    assert_equal REMOTE, RemoteScriptSources.for(paypal: false)
    assert_equal REMOTE + PAYPAL, RemoteScriptSources.for(paypal: true)
  end

  # Outside production the app policy is report-only, and a signing page
  # reports its strict policy in that header instead (SigningCsp), so the
  # signing page reads the strict list here and the app list below.
  test "the header carries the named list on the layout, signing, slate and tokens pages" do
    pages.each do |name, (path, user)|
      user ? log_in_as(user) : delete(logout_path)
      get path
      assert_response :success, name
      header = response.headers[REPORT_ONLY]
      assert header, "#{name}: no CSP header"
      expected = name == "signing" ? script_src(SigningCsp.strict(Rails.application.config.content_security_policy).build(nil, nil, [])) : EXPECTED
      assert_equal expected.reject { |source| source.start_with?("'nonce-") }, script_src(header).reject { |source| source.start_with?("'nonce-") }, name
      assert_not_includes script_src(header), "https:", name
    end
  end

  test "in production every one of those pages enforces the named list" do
    with_production_headers do
      pages.each do |name, (path, user)|
        user ? log_in_as(user) : delete(logout_path)
        get path
        assert_response :success, name
        assert_equal EXPECTED, script_src(response.headers[ENFORCED]), name
      end
    end
  end

  test "every remote script the app or its gems' views can load is named in script-src" do
    loads = RemoteScriptCensus.loads(RemoteScriptCensus.app_files + RemoteScriptCensus.gem_files)
    urls = loads.map(&:url).uniq
    # The census sees each of the four (and the sanity check that it sees anything).
    assert_operator urls.size, :>=, 4, urls.inspect
    uncovered = urls.reject { |url| self.class.covered?(RemoteScriptSources.for(paypal: false), url) }
    assert_empty uncovered, "remote scripts the app policy would block; add each to RemoteScriptSources"
  end

  test "the PayPal SDK the tokens page injects is covered only with PayPal as the provider" do
    log_in_as(users(:jordan))
    with_paypal_enabled { get tokens_buy_path }
    assert_response :success
    sdk = response.body[%r{s\.src = "(https://www\.paypal\.com/sdk/js\?[^"]+)"}, 1]
    assert sdk, "the tokens page no longer injects the PayPal SDK as this test reads it"
    assert self.class.covered?(RemoteScriptSources.for(paypal: true), sdk)
    assert_not self.class.covered?(RemoteScriptSources.for(paypal: false), sdk)
    # What the SDK itself loads (its fraud script and component bundles).
    %w[https://c.paypal.com/da/r/fb.js https://www.paypalobjects.com/upstream/bizcomponents/js/modal.js].each do |url|
      assert self.class.covered?(RemoteScriptSources.for(paypal: true), url), url
    end
  end

  test "the matcher reads a source as a browser does" do
    assert self.class.covers?("https://cdn.logr-in.com", "https://cdn.logr-in.com/logger.min.js")
    assert self.class.covers?("https://*.paypal.com", "https://www.paypal.com/sdk/js?client-id=x")
    assert_not self.class.covers?("https://*.paypal.com", "https://paypal.com.evil.test/x.js")
    assert self.class.covers?(REMOTE.first, REMOTE.first)
    assert_not self.class.covers?(REMOTE.first, "https://cdn.jsdelivr.net/npm/anything@1/x.js")
    assert_not self.class.covers?("https://unpkg.com/a.js", "https://cdn.jsdelivr.net/a.js")
  end

  def with_paypal_enabled
    was = [ Rails.application.config.x.paypal_enabled, Rails.application.config.x.payment_provider ]
    Rails.application.config.x.paypal_enabled = true
    Rails.application.config.x.payment_provider = "paypal"
    yield
  ensure
    Rails.application.config.x.paypal_enabled, Rails.application.config.x.payment_provider = was
  end
end
