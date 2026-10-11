require "test_helper"

# [integration] The signing pages' script policy (SigningCsp): script-src
# drops 'unsafe-inline' and https: and carries a per-request nonce, every
# inline script on the page carries that nonce, and no element carries an
# inline handler. Every other page keeps the app policy, unchanged.
class SigningCspTest < ActionDispatch::IntegrationTest
  REPORT_ONLY = ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY
  ENFORCED = ActionDispatch::Constants::CONTENT_SECURITY_POLICY
  HANDLER = /\Aon[a-z]+\z/
  NONCE = /'nonce-([^']+)'/
  # As test/views/alpine_and_inline_script_ratchet_test.rb reads a view.
  SCRIPT_TAG = /<script\b((?:<%.*?%>|[^>])*)>/mi
  NOT_INLINE = /\bsrc\s*=|type\s*=\s*["']application\/(?:ld\+)?json["']/i
  COMMENTS = [ /<%#.*?%>/m, /<!--.*?-->/m, %r{^\s*//.*$} ].freeze

  # Inline script and handlers a gem still renders without the nonce. Each
  # is excused only while the gem file named still lacks the fix, read from
  # the locked gem, so it lapses the day the lock takes a fixed release.
  Pending = Struct.new(:gem, :file, :unfixed, :script, :handler, keyword_init: true) do
    def open?
      File.read(File.join(Gem.loaded_specs.fetch(gem).full_gem_path, file)).match?(unfixed)
    end
  end
  PENDING = [
    Pending.new(gem: "solana-studio", file: "app/views/solana_studio/_phantom_deeplink.html.erb",
                unfixed: /^<script>$/, script: /window\.startPhantomDeepLink\s*=/),
    Pending.new(gem: "solana-studio", file: "app/views/solana_studio/_deeplink_assets.html.erb",
                unfixed: /^<script>$/, script: /data-studio-nacl/),
    Pending.new(gem: "studio-engine", file: "app/views/solana_sessions/phantom_callback.html.erb",
                unfixed: /^<script>$/, script: /phantom_dl_secret/),
    Pending.new(gem: "studio-engine", file: "app/views/studio/banners/_button.html.erb",
                unfixed: /onmouseover:/, handler: /\Athis\.style\.background=/)
  ].freeze

  def page = Nokogiri::HTML5(response.body)

  def script_src(header)
    header.split(";").map(&:strip).find { |directive| directive.start_with?("script-src ") }.split(" ").drop(1)
  end

  def nonce_of(header) = header[NONCE, 1]

  # The import map is inline too, and importmap-rails nonces it.
  def executable?(script)
    script["type"] == "importmap" || (script["src"].blank? && !script["type"].to_s.include?("json"))
  end

  def pending_script?(script) = PENDING.any? { |item| item.script && item.open? && script.text.match?(item.script) }

  def pending_handler?(attribute) = PENDING.any? { |item| item.handler && item.open? && attribute.value.match?(item.handler) }

  # The strict header (report-only here: the app policy is report-only
  # outside production), and the page it covers.
  def assert_signing_page(html = response.body)
    header = response.headers[REPORT_ONLY]
    assert header, "no CSP header on #{request.path}"
    sources = script_src(header)
    assert_includes sources, "'self'"
    assert_includes sources, "'unsafe-eval'"
    assert_not_includes sources, "'unsafe-inline'"
    assert_not_includes sources, "https:"
    nonce = nonce_of(header)
    assert nonce, "no nonce in script-src on #{request.path}"
    assert_page_nonced(Nokogiri::HTML5(html), nonce)
    nonce
  end

  def assert_page_nonced(doc, nonce)
    # The engine's csp_meta_tag renders an untracked one on every page.
    meta = doc.at_css('meta[name="csp-nonce"][data-turbo-track]')
    assert meta, "no tracked csp-nonce meta"
    assert_equal nonce, meta["content"]
    assert_equal "reload", meta["data-turbo-track"]

    unnonced = doc.css("script").select { |script| executable?(script) && script["nonce"] != nonce }
    assert_empty unnonced.reject { |script| pending_script?(script) }.map { |script| script.to_html[0, 160] }
    handlers = doc.css("*").flat_map { |node| node.attribute_nodes.select { |attribute| attribute.name.match?(HANDLER) } }
    assert_empty handlers.reject { |attribute| pending_handler?(attribute) }.map { |attribute| "#{attribute.parent.name}[#{attribute.name}]" }
    assert_empty doc.css("[href]").select { |link| link["href"].strip.downcase.start_with?("javascript:") }.map(&:to_html)
  end

  def app_policy
    Rails.application.config.content_security_policy.build(nil, nil, [])
  end

  test "a guest and a player each get the strict policy on the contest page" do
    get contest_path(contests(:one))
    assert_response :success
    assert_signing_page

    log_in_as(users(:jordan))
    get contest_path(contests(:one))
    assert_signing_page
    get contest_page_path(contests(:one))
    assert_response :success
    assert_signing_page
  end

  test "an admin gets the strict policy on every signing page" do
    log_in_as(users(:alex))
    [
      contest_path(contests(:one)), edit_contest_path(contests(:one)), new_contest_path,
      generator_contests_path, account_path, admin_pending_transactions_path, "/auth/phantom/callback"
    ].each do |path|
      get path
      assert_response :success, path
      assert_signing_page
    end
  end

  test "the nonce is new on every request" do
    get contest_path(contests(:one))
    first = assert_signing_page
    get contest_path(contests(:one))
    second = assert_signing_page
    assert_not_equal first, second
  end

  test "a page outside the signing group keeps the app policy" do
    log_in_as(users(:alex))
    [ contests_path, root_path, "/help" ].each do |path|
      get path
      next if response.redirect?

      assert_equal app_policy, response.headers[REPORT_ONLY], path
      assert_nil response.headers[ENFORCED], path
      assert_includes script_src(response.headers[REPORT_ONLY]), "'unsafe-inline'"
      assert_nil nonce_of(response.headers[REPORT_ONLY]), path
      assert_nil page.at_css('meta[name="csp-nonce"][data-turbo-track]'), path
    end
  end

  # The control: an un-nonced inline script on a signing page fails the check.
  test "an inline script without the nonce on a signing page fails" do
    get contest_path(contests(:one))
    nonce = assert_signing_page
    tampered = response.body.sub("</body>", "<script>window.injected = 1</script></body>")
    assert_raises(Minitest::Assertion) { assert_page_nonced(Nokogiri::HTML5(tampered), nonce) }
    handler = response.body.sub("</body>", %(<button onclick="go()">x</button></body>))
    assert_raises(Minitest::Assertion) { assert_page_nonced(Nokogiri::HTML5(handler), nonce) }
  end

  test "in production, report-only enforces the app policy and reports the strict one" do
    with_production_headers(enforced: false) do
      get contest_path(contests(:one))
      assert_equal app_policy, response.headers[ENFORCED]
      strict = response.headers[REPORT_ONLY]
      assert_not_includes script_src(strict), "'unsafe-inline'"
      assert nonce_of(strict)

      get contests_path
      assert_equal app_policy, response.headers[ENFORCED]
      assert_nil response.headers[REPORT_ONLY]
    end
  end

  test "in production, the enforce switch enforces the strict policy alone" do
    with_production_headers(enforced: true) do
      get contest_path(contests(:one))
      assert_nil response.headers[REPORT_ONLY]
      strict = response.headers[ENFORCED]
      assert_not_includes script_src(strict), "'unsafe-inline'"
      assert_not_includes script_src(strict), "https:"
      assert_page_nonced(page, nonce_of(strict))

      get contests_path
      assert_equal app_policy, response.headers[ENFORCED]
    end
  end

  # Every inline <script> in app/views renders the nonce, so a partial that
  # reaches a signing page later is covered before it does.
  test "every inline script in the app's views carries the nonce" do
    missing = Dir.glob(Rails.root.join("app/views/**/*.erb")).flat_map do |file|
      code = COMMENTS.reduce(File.read(file)) { |text, comment| text.gsub(comment, "") }
      code.scan(SCRIPT_TAG).reject { |(attributes)| attributes.match?(NOT_INLINE) }
          .reject { |(attributes)| attributes.include?('nonce="<%= content_security_policy_nonce %>"') }
          .map { |(attributes)| "#{Pathname(file).relative_path_from(Rails.root)}: <script#{attributes}>" }
    end
    assert_empty missing
  end

  private

  def with_production_headers(enforced:)
    env = Rails.application.env_config
    key = "action_dispatch.content_security_policy_report_only"
    was = [ env[key], Rails.configuration.x.signing_csp_enforced ]
    env[key] = false
    Rails.configuration.x.signing_csp_enforced = enforced
    yield
  ensure
    env[key], Rails.configuration.x.signing_csp_enforced = was
  end
end
