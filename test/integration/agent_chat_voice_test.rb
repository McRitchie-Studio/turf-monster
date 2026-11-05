require "test_helper"
require "support/agent_chat_contract_hub"
require "support/redis_cache_outage"

# [integration] /chat with hold to talk, admins only, through the app's real proxy
# and the engine's real client to a contract stub on a real socket
# (/tasks/turf-chat-takes-voice; docs/AGENT_CHAT.md).
class AgentChatVoiceTest < ActionDispatch::IntegrationTest
  TOKEN = "stub-agent-chat".freeze
  MIC = "[data-test=agent-chat-voice]".freeze
  FORGERY_CONTROLLERS = [ AgentChatPagesController, Studio::AgentChatsController, Studio::VoiceTakesController ].freeze

  setup do
    @hub = AgentChatContractHub.start(token: TOKEN, answer_after: 0.05)
    @saved = { url: Studio.agent_chat_hub_url, token: Studio.agent_chat_token, limit: Studio.voice_takes_rate_limit,
               transcriber: Studio.voice_transcriber, key: Studio.voice_openai_api_key }
    Studio.agent_chat_hub_url = @hub.url
    Studio.agent_chat_token = TOKEN
    # The engine's fallback counter lives for the process: a window per test.
    Studio.voice_takes_rate_limit = { to: 1000, within: 600, store: ActiveSupport::Cache::MemoryStore.new }
    @admin = users(:alex)
    @player = users(:jordan)
    @admin.update_column(:email_verified_at, Time.current)
  end

  teardown do
    Studio.agent_chat_hub_url = @saved[:url]
    Studio.agent_chat_token = @saved[:token]
    Studio.voice_takes_rate_limit = @saved[:limit]
    Studio.voice_transcriber = @saved[:transcriber]
    Studio.voice_openai_api_key = @saved[:key]
    @hub.stop
  end

  def take_params
    { voice: { audio: Rack::Test::UploadedFile.new(StringIO.new("not really audio"), "audio/webm", original_filename: "take"),
               mime_type: "audio/webm", duration_ms: 900 } }
  end

  def with_forgery_protection
    saved = FORGERY_CONTROLLERS.map(&:allow_forgery_protection)
    FORGERY_CONTROLLERS.each { |controller| controller.allow_forgery_protection = true }
    yield
  ensure
    FORGERY_CONTROLLERS.zip(saved) { |controller, value| controller.allow_forgery_protection = value }
  end

  def assert_refused_before_the_hub(status, &call)
    call.call
    assert_response status
    assert_empty @hub.requests, "the hub must not be asked"
  end

  def body = JSON.parse(response.body)

  # ---- The page ----

  test "an admin gets the chat for Turf's soul, the microphone and the privacy line" do
    log_in_as(@admin)
    get agent_chat_page_path

    assert_response :success
    assert_select "[data-test=agent-chat][data-agent-chat-soul=turf_monster]", 1
    assert_select "form[data-test=agent-chat-form] #{MIC}", 1
    assert_select "[data-test=agent-chat-voice-privacy]", text: Studio::AgentChat::VOICE_PRIVACY
  end

  test "a player is sent away from the page, and a signed-out visitor to sign in" do
    get agent_chat_page_path
    assert_redirected_to signin_path

    log_in_as(@player)
    get agent_chat_page_path
    assert_redirected_to root_path
  end

  test "the page's head carries the token a take sends, and nothing denies the microphone" do
    log_in_as(@admin)
    with_forgery_protection { get agent_chat_page_path }

    assert_select "meta[name=csrf-token]", 1
    assert_no_match(/microphone=\(\)/, response.headers["Permissions-Policy"].to_s)
    assert_no_match(/microphone=\(\)/, response.headers["Feature-Policy"].to_s)
  end

  test "every module the chat's lazy controllers import is pinned in the app's importmap" do
    pins = Rails.application.importmap.packages.keys
    %w[studio/stimulus studio/agent_chat studio/agent_chat_voice studio/voice_recorder studio/microphone_chip
       studio/microphone studio/level_meter studio/controllers/agent_chat_controller
       studio/controllers/agent_chat_voice_controller studio/controllers/voice_recorder_controller
       studio/controllers/microphone_chip_controller].each do |pin|
      assert_includes pins, pin
    end
  end

  # ---- The gate: refused before any hub call ----

  test "a player is refused by both chat calls and the take, before any hub call" do
    log_in_as(@player)

    assert_refused_before_the_hub(:forbidden) { post studio_agent_chat_messages_path, params: { soul: "turf_monster", text: "Hi" }, as: :json }
    assert_equal "not_allowed", body["reason"]
    assert_refused_before_the_hub(:forbidden) { get studio_agent_chat_turns_path(soul: "turf_monster") }
    assert_equal "not_allowed", body["reason"]
    assert_refused_before_the_hub(:forbidden) { post studio_voice_takes_path, params: take_params }
    assert_equal "not_allowed", body["reason"]
    assert_nil cookies[Studio::AgentChatsController::ANON_COOKIE.to_s], "no anon cookie for a refused viewer"
  end

  test "a signed-out visitor is refused by both chat calls and the take, before any hub call" do
    assert_refused_before_the_hub(:forbidden) { post studio_agent_chat_messages_path, params: { soul: "turf_monster", text: "Hi" }, as: :json }
    assert_refused_before_the_hub(:forbidden) { get studio_agent_chat_turns_path(soul: "turf_monster") }
    assert_refused_before_the_hub(:unauthorized) { post studio_voice_takes_path, params: take_params, headers: { "Accept" => "application/json" } }
    assert_nil cookies[Studio::AgentChatsController::ANON_COOKIE.to_s], "no anon cookie for a refused viewer"
  end

  test "the proxy offers no soul but Turf's" do
    log_in_as(@admin)
    post studio_agent_chat_messages_path, params: { soul: "alex", text: "Hi" }, as: :json
    assert_response :not_found
    assert_empty @hub.requests
  end

  # ---- Who the hub is told is talking ----

  test "an admin's verified email reaches the hub" do
    log_in_as(@admin)
    post studio_agent_chat_messages_path, params: { soul: "turf_monster", text: "Hi Turf" }, as: :json

    assert_response :created
    assert_equal({ "email" => @admin.email }, @hub.messages.last["person"])
    assert_equal "turf_monster", @hub.messages.last["soul"]
  end

  test "an admin with an unverified email is anonymous to the hub" do
    @admin.update_column(:email_verified_at, nil)
    log_in_as(@admin)
    post studio_agent_chat_messages_path, params: { soul: "turf_monster", text: "Hi Turf" }, as: :json

    assert_response :created
    person = @hub.messages.last["person"]
    assert_equal [ "anon_token" ], person.keys
    assert_no_match(/#{Regexp.escape(@admin.email)}/, @hub.messages.last.to_json)
  end

  # What the owner's account needs: a seeded row reads unverified until its first
  # email sign-in, and a wallet sign-in stamps nothing.
  test "a magic link stamps an admin on the roster's wallet, and is refused on any other wallet" do
    roster = User::PARKED_IDENTITIES.find { |identity| identity[:email] == @admin.email }[:wallet]
    @admin.update_columns(email_verified_at: nil, web3_solana_address: roster)
    assert @admin.accept_mailbox_proof!
    assert @admin.reload.email_verified_at.present?

    @admin.update_columns(email_verified_at: nil, web3_solana_address: "Other1111111111111111111111111111111111111")
    assert_not @admin.accept_mailbox_proof!, "the row is the operator's to resolve (users:parked_role_audit)"
    assert_nil @admin.reload.email_verified_at
  end

  test "changing the address clears the proof, so the admin goes anonymous until it is proven again" do
    @admin.update!(email: "someone-else@example.com")
    assert_nil @admin.reload.email_verified_at
  end

  # ---- The real forgery check ----

  test "with forgery on, the page's token carries a take and its words, and the form's token does not" do
    log_in_as(@admin)
    with_forgery_protection do
      get agent_chat_page_path
      meta = css_select("meta[name=csrf-token]").first["content"]
      form = css_select("form[data-test=agent-chat-form] input[name=authenticity_token]").first&.[]("value")

      post studio_voice_takes_path, params: take_params, headers: { "X-CSRF-Token" => meta }
      assert_response :success
      heard = body
      assert_equal Studio::VoiceTranscription::Mock::DEFAULT_TEXT, heard["text"]
      assert_equal "no_embedding", heard["check"]

      post studio_agent_chat_messages_path,
           params: { soul: "turf_monster", text: heard["text"],
                     voice: heard.slice("check", "score", "duration_ms") }.to_json,
           headers: { "X-CSRF-Token" => meta, "Content-Type" => "application/json" }
      assert_response :created
      assert_equal %w[check duration_ms score], @hub.messages.last["voice"].keys.sort
      assert_equal @admin.email, @hub.messages.last["person"]["email"]

      # The composer's own token is per-form, bound to /agent_chat/messages.
      assert form.present?, "the composer carries its own token"
      assert_not_equal meta, form
      assert_refused_by_forgery { post studio_voice_takes_path, params: take_params, headers: { "X-CSRF-Token" => form } }
    end
  end

  test "with forgery on, a take with no token never reaches the transcriber" do
    log_in_as(@admin)
    with_forgery_protection do
      assert_refused_by_forgery { post studio_voice_takes_path, params: take_params }
    end
  end

  # ---- The rate limit's store ----

  test "the configured store is rack-attack's" do
    limit = @saved[:limit]
    assert_same Rack::Attack.cache.store, limit[:store]
    assert_equal({ to: 20, within: 600 }, limit.slice(:to, :within))
  end

  test "takes count in the configured store and past the limit answer 429 before the transcriber" do
    store = ActiveSupport::Cache::MemoryStore.new
    Studio.voice_takes_rate_limit = { to: 1, within: 600, store: store }
    log_in_as(@admin)

    post studio_voice_takes_path, params: take_params
    assert_response :success
    assert_equal 1, store.instance_variable_get(:@data).size, "the count lives in the configured store"

    post studio_voice_takes_path, params: take_params
    assert_response :too_many_requests
    assert_equal "rate_limited", body["reason"]
    assert response.headers["Retry-After"].present?
  end

  test "the engine's call works on the store production has, and a Redis outage fails open" do
    RedisCacheOutage.with_rack_attack do
      store = Rack::Attack.cache.store
      assert_instance_of Rack::Attack::StoreProxy::RedisCacheStoreProxy, store
      assert_nil store.increment("rate-limit:studio/voice_takes:1:1", 1, expires_in: 600)

      Studio.voice_takes_rate_limit = { to: 1, within: 600, store: store }
      log_in_as(@admin)
      2.times do
        post studio_voice_takes_path, params: take_params
        assert_response :success
      end
    end
  end

  # ---- No key ----

  test "the real transcriber with no key answers the not_configured line, and nothing crashes" do
    Studio.voice_transcriber = "openai"
    Studio.voice_openai_api_key = nil
    log_in_as(@admin)

    with_env("STUDIO_VOICE_OPENAI_API_KEY" => nil) { post studio_voice_takes_path, params: take_params }

    assert_response :service_unavailable
    assert_equal "not_configured", body["reason"]
    assert_equal Studio::VoiceTranscription::NOT_CONFIGURED_MESSAGE, body["error"]
  end

  # ---- The privacy page ----

  test "the privacy page carries the approved line verbatim and names OpenAI among the companies" do
    get privacy_path
    assert_response :success
    assert_select "[data-test=voice-privacy]", text: Studio::AgentChat::VOICE_PRIVACY
    assert_select "li strong", text: "OpenAI"
  end

  private

  # The refusal is an InvalidAuthenticityToken, which this environment shows as a
  # 422. What matters is the status and that no take reached the transcriber.
  def assert_refused_by_forgery
    Studio::VoiceTranscription::Mock.reset!
    yield
    assert_response :unprocessable_entity
    assert_empty Studio::VoiceTranscription::Mock.calls, "a refused take is never transcribed"
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
