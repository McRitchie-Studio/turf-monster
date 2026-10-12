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

  # Inline script a gem still renders without the nonce: SigningCsp's open
  # PENDING_GEM_FIXES, read from the locked gems, so each lapses the day the
  # lock takes the fixed release.
  def pending = SigningCsp.pending_gem_fixes

  # The signing pages an admin reaches, each by GET.
  def admin_signing_paths
    contest = contests(:one)
    [
      contest_path(contest), admin_contest_path(contest), live_contest_path(contest), edit_contest_path(contest),
      new_contest_path, generator_contests_path, account_path, admin_pending_transactions_path,
      "/auth/phantom/callback", profile_path, wallet_path, admin_vault_init_path, admin_vault_state_path,
      admin_authorities_path
    ]
  end

  def page = Nokogiri::HTML5(response.body)

  def script_src(header)
    header.split(";").map(&:strip).find { |directive| directive.start_with?("script-src ") }.split(" ").drop(1)
  end

  def nonce_of(header) = header[NONCE, 1]

  # The import map is inline too, and importmap-rails nonces it.
  def executable?(script)
    script["type"] == "importmap" || (script["src"].blank? && !script["type"].to_s.include?("json"))
  end

  def pending_script?(script) = pending.any? { |item| item.script && script.text.match?(item.script) }

  def pending_handler?(attribute) = pending.any? { |item| item.handler && attribute.value.match?(item.handler) }

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
    assert_includes header, "report-uri /csp_reports"
    nonce = nonce_of(header)
    assert nonce, "no nonce in script-src on #{request.path}"
    assert_page_nonced(Nokogiri::HTML5(html), nonce)
    nonce
  end

  def assert_page_nonced(doc, nonce)
    # The engine's csp_meta_tag. Turbo gives this nonce to every script it
    # activates, which is why signing_document strips frame and stream scripts.
    meta = doc.at_css('meta[name="csp-nonce"]')
    assert meta, "no csp-nonce meta"
    assert_equal nonce, meta["content"]
    # Its own document: Turbo enters it by a full load, and signing_document
    # leaves by one.
    assert doc.at_css('meta[name="turbo-visit-control"][content="reload"]'), "no turbo-visit-control reload"
    assert doc.at_css('meta[name="signing-csp"][content="strict"]'), "no signing-csp marker"

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
    admin_signing_paths.each do |path|
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
      assert_nil page.at_css('meta[name="signing-csp"]'), path
      assert_nil page.at_css('meta[name="turbo-visit-control"]'), path
    end
  end

  # A signing page's form whose redirect lands off the signing pages: Turbo
  # renders the redirect target inside the form's fetch, and signing_document
  # then leaves by a full load of it. The fetch carries the strict document's
  # header, so the flash survives for the full load; the control, the same
  # fetch without the header, spends it.
  def save_contest_then_fetch(headers)
    patch contest_path(contests(:one)), params: { contest: { name: contests(:one).name } },
                                        headers: { "X-Turbo-Request-Id" => "save" }
    assert_redirected_to contests_path
    get contests_path, headers: { "X-Turbo-Request-Id" => "save" }.merge(headers)
    assert_response :success
    get contests_path
    response.body
  end

  test "a redirect a signing page's form follows keeps its flash for the full load" do
    log_in_as(users(:alex))
    assert_includes save_contest_then_fetch(SigningCsp::DOCUMENT_HEADER => "strict"), "Contest updated."
  end

  test "the same fetch from any other page spends the flash" do
    log_in_as(users(:alex))
    assert_not_includes save_contest_then_fetch({}), "Contest updated."
  end

  # The live board is the contest's page once a game has started:
  # contests#show sends everyone there. It renders the leaderboard compact,
  # which leaves out the admin Lock buttons (those are on show, #contest and
  # #admin), so it is listed as the page a player and an admin are on during
  # play, where the layout's wallet modals open.
  test "the live board gets the strict policy, for a guest and an admin" do
    get live_contest_path(contests(:one))
    assert_response :success
    assert page.at_css("#contest_#{contests(:one).id}_leaderboard"), "not the live board"
    assert_signing_page

    log_in_as(users(:alex))
    get live_contest_path(contests(:one))
    assert_response :success
    assert_signing_page
  end

  # A failed save re-renders a signing template. Posted natively, that render
  # is a document of its own: it must carry the strict policy and a nonce its
  # own scripts carry.
  test "a failed account save renders under the strict policy and its own nonce" do
    log_in_as(users(:jordan))
    users(:jordan).update_columns(email: nil)
    patch account_path, params: { user: { email: "bad@nope" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "Failed to update account."
    assert_signing_page
  end

  test "a failed contest save renders under the strict policy and its own nonce" do
    log_in_as(users(:alex))
    patch contest_path(contests(:one)), params: { contest: { name: "" } }
    assert_response :unprocessable_entity
    assert page.at_css("form[action='#{contest_path(contests(:one))}']"), "not the edit page"
    assert_signing_page
  end

  # Every action that renders a signing template is itself a signing page,
  # read from the controllers' source: `render :show` in accounts#update is
  # what made the re-render above a hazard while update was off the list.
  RENDER = /\brender\s*\(?\s*(?:action:\s*)?[:"'](\w+)/
  test "every action that renders a signing template is a signing page" do
    found = SigningCsp::PAGES.flat_map do |controller_path, actions|
      file = Rails.root.join("app/controllers/#{controller_path}_controller.rb")
      next [] unless file.exist?

      controller = "#{controller_path.camelize}Controller".constantize
      method = nil
      File.foreach(file).filter_map do |line|
        method = Regexp.last_match(1) if line =~ /^\s*def (\w+)/
        template = line[RENDER, 1]
        next unless template && actions.include?(template) && controller.action_methods.include?(method)

        "#{controller_path}##{method} renders #{template}"
      end.tap { |renders| renders.each { |render| assert_includes actions, render[/#(\w+)/, 1], render } }
    end
    assert_operator found.size, :>=, 5, "the scan found too few renders to mean anything: #{found}"
  end

  # A form on a signing page that posts to a signing action is a native post.
  # Through Turbo, a failed save would render in place under the document's
  # old nonce; with the action listed, Turbo reloads instead and the error is
  # lost. Native, the re-render is its own document.
  test "a form on a signing page that posts to a signing action is not a Turbo form" do
    log_in_as(users(:alex))
    checked = admin_signing_paths.flat_map do |path|
      get path
      page.css("form[action]").filter_map do |form|
        verb = (form.at_css("input[name='_method']")&.[]("value") || form["method"] || "get").upcase
        next if verb == "GET"

        route = Rails.application.routes.recognize_path(form["action"], method: verb) rescue next
        next unless SigningCsp::PAGES.fetch(route[:controller], []).include?(route[:action])

        assert_equal "false", form["data-turbo"], "#{path}: form to #{route[:controller]}##{route[:action]} is a Turbo form"
        "#{path} -> #{route[:controller]}##{route[:action]}"
      end
    end
    assert_operator checked.size, :>=, 3, "too few forms checked to mean anything: #{checked}"
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

  test "the enforce switch enforces the strict policy outside production too" do
    was = Rails.configuration.x.signing_csp_enforced
    Rails.configuration.x.signing_csp_enforced = true
    get contest_path(contests(:one))
    assert_nil response.headers[REPORT_ONLY]
    assert_not_includes script_src(response.headers[ENFORCED]), "'unsafe-inline'"

    get contests_path
    assert_nil response.headers[ENFORCED], "the app policy stays report-only here"
    assert_equal app_policy, response.headers[REPORT_ONLY]
  ensure
    Rails.configuration.x.signing_csp_enforced = was
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
