require "test_helper"
require "minitest/mock"
require "open3"

# [unit] The layout's LogRocket tags (ApplicationHelper#session_replay_active?):
# in production a signed-out visitor loads no LogRocket at all, and a signed-in
# player loads the recorder, its sanitized init and the slug-only identify.
# The production check (ApplicationHelper.session_replay_environment?, which
# reads Rails.env.production?) is stubbed for the request alone: stubbing
# Rails.env itself sends every production-only boot check in the app off,
# and the page 500s before the layout finishes.
class SessionReplayLayoutTest < ActionDispatch::IntegrationTest
  RECORDER = %r{<script src="https://cdn\.logr-in\.com/LogRocket\.min\.js"}

  def in_production(&block)
    ApplicationHelper.stub(:session_replay_environment?, true, &block)
  end

  test "a signed-out visitor in production loads no LogRocket" do
    in_production { get "/help" }
    assert_response :success
    assert_not response.body.match?(RECORDER), "the LogRocket recorder loads"
    assert_not response.body.match?(/LogRocket\.init/), "LogRocket.init renders"
    assert_not response.body.match?(/LogRocket\.identify/), "LogRocket.identify renders"
  end

  test "a signed-in player in production loads the recorder, the sanitizer and the identify" do
    log_in_as(users(:jordan))
    in_production { get "/help" }
    assert_response :success
    assert response.body.match?(RECORDER), "the LogRocket recorder is missing"
    assert response.body.match?(/LogRocket\.init\('jodsqq\/mcritchie-studio'/), "no LogRocket.init"
    assert response.body.match?(/requestSanitizer/), "no request sanitizer"
    assert response.body.match?(/LogRocket\.identify\('#{users(:jordan).slug}'/), "no slug-only identify"
  end

  # ---- The sanitizers, run for real (/tasks/turf-replay-skips-chat) ----
  #
  # The layout's own inline script, as this request rendered it, runs under node
  # with a fake window.LogRocket that keeps the config, and the two sanitizers it
  # passed are called on samples. Paths come from the routes the app draws, so a
  # moved route or a tightened boundary fails here. A copy of the regex would
  # prove nothing.
  #
  # The samples have the shape the SDK hands over (cdn.logr-in.com/LogRocket.min.js,
  # read 2026-11-05): a fetch request's url is what the caller passed, here a
  # path; a response's url is Response.url, absolute.
  #
  # CONTROL: remove agent_chat or voice from either list in the layout. The tests
  # below go red and name the path.
  HOST = "https://turf.test".freeze

  def sanitize_with_the_layouts_script(kind, urls)
    log_in_as(users(:jordan))
    in_production { get "/help" }
    source = Nokogiri::HTML(response.body).css("script").map(&:text).find { |text| text.include?("LogRocket.init(") }
    assert source, "the layout rendered no LogRocket.init script"

    runner = <<~JS
      var config;
      var window = { LogRocket: { init: function (id, options) { config = options; } } };
      #{source}
      var urls = #{urls.to_json};
      var out = {};
      urls.forEach(function (url) {
        var sanitized = config.network[#{"#{kind}Sanitizer".to_json}]({
          url: url, body: "THE WORDS", method: "POST", headers: { "X-CSRF-Token": "tok", Accept: "application/json" }
        });
        out[url] = { body: sanitized.body === undefined ? null : sanitized.body, url: sanitized.url, headers: sanitized.headers };
      });
      console.log(JSON.stringify(out));
    JS
    out, err, status = Open3.capture3("node", "-e", runner)
    assert status.success?, "the layout's script failed under node: #{err}"
    JSON.parse(out)
  end

  def bodies_dropped(kind, urls)
    results = sanitize_with_the_layouts_script(kind, urls)
    assert_equal urls.sort, results.keys.sort
    results.select { |_url, result| result["body"].nil? }.keys
  end

  # /profile/voice is on purpose: the unanchored pattern matches it, and it carries a
  # voice's embeddings. Voice profiles are off on Turf today, but the route is drawn.
  CHAT_ROUTES = lambda do |test|
    [ test.studio_agent_chat_messages_path,
      test.studio_agent_chat_turns_path(soul: "turf_monster", limit: 50, after: 12),
      test.studio_voice_takes_path,
      test.profile_voice_path ]
  end

  test "a chat message, a turn, a take and a saved voice send no request body to the recorder" do
    urls = CHAT_ROUTES.call(self)
    assert_equal urls, bodies_dropped(:request, urls)
  end

  test "a chat answer and a take's returned transcript send no response body to the recorder" do
    urls = CHAT_ROUTES.call(self).map { |path| "#{HOST}#{path}" }
    assert_equal urls, bodies_dropped(:response, urls)
  end

  test "the chat's boundaries do not widen to other routes" do
    urls = [ "/help", "/chat", "/contests", "/profile", "/test/agent_chat_lab", "/voicemail", "/agent_chats", "/contests/1/messages", "/contests/voice-of-reason" ]
    assert_empty bodies_dropped(:request, urls)
    assert_empty bodies_dropped(:response, urls.map { |path| "#{HOST}#{path}" })
  end

  test "the lists' existing entries still drop their bodies" do
    requests = %w[/auth/siws /account/email /wallet/sync /magic_link/send /webhooks/stripe]
    assert_equal requests, bodies_dropped(:request, requests)
    responses = %w[/auth/siws /account/email /wallet/sync /magic_link/send /session_state].map { |path| "#{HOST}#{path}" }
    assert_equal responses, bodies_dropped(:response, responses)
  end

  test "the CSRF token and an api key still stay out, on the chat's calls too" do
    path = studio_agent_chat_messages_path
    keyed = "/rpc?api-key=secret123&x=1"
    results = sanitize_with_the_layouts_script(:request, [ path, keyed ])
    assert_equal({ "Accept" => "application/json" }, results[path]["headers"])
    assert_equal "/rpc?api-key=REDACTED&x=1", results[keyed]["url"]
  end

  # A turn's URL holds no person: the browser sends only soul, limit and the after
  # cursor (studio/agent_chat turnsUrl). The proxy adds `person` on the server side.
  test "a turn's URL reaches the recorder as it is, and it names nobody" do
    path = studio_agent_chat_turns_path(soul: "turf_monster", limit: 50, after: 12)
    assert_equal path, sanitize_with_the_layouts_script(:request, [ path ])[path]["url"]
    assert_equal %w[after limit soul], Rack::Utils.parse_query(URI(path).query).keys.sort
  end

  # ---- The chat's DOM ----

  test "with the recorder on, everything the chat shows sits inside a data-private element" do
    log_in_as(users(:alex))
    in_production { get agent_chat_page_path }
    assert_response :success
    assert response.body.match?(RECORDER), "the recorder is off, so this proves nothing"

    assert_select "main [data-private]", 1
    %w[agent-chat agent-chat-messages agent-chat-typing-slot agent-chat-status agent-chat-error
       agent-chat-voice-status agent-chat-input].each do |name|
      assert_select "[data-private] [data-test=#{name}]", { minimum: 1 }, "#{name} is outside the private wrapper"
    end
    # A bare attribute reads as the recorder's "redact": it keeps the box's size.
    # A value of "delete" would hide the box.
    assert_select "main [data-private='']", 1
  end

  test "the production check reads Rails.env" do
    assert_not ApplicationHelper.session_replay_environment?
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert ApplicationHelper.session_replay_environment?
    end
  end

  test "outside production nobody loads LogRocket" do
    log_in_as(users(:jordan))
    get "/help"
    assert_response :success
    assert_not response.body.match?(RECORDER), "the LogRocket recorder loads"
  end
end
