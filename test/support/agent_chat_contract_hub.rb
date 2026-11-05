require "socket"
require "json"
require "time"
require "uri"
require "rack/utils"

# A stand-in for the McRitchie Studio hub's agent chat API on a real socket, so
# the app's real proxy and the engine's real client (Net::HTTP, the bearer, the
# status codes) run end to end. It honours the hub's contract
# (mcritchie-studio Api::V1::AgentChatsController, AgentChat::Voice,
# AgentChat::Turns), and refuses what the hub refuses:
#
#   401 no bearer or the wrong one · 404 a soul with no web chat
#   422 no person, no words, or a voice that is not a hash with a known check
#
# The speaker is the hub's to name, never the post's: the verified person on a
# "matched" check, else "Someone new". A row goes pending, typing, answered.
#
#   hub = AgentChatContractHub.start(token: "stub", souls: %w[turf_monster])
#   Studio.agent_chat_hub_url = hub.url
#   hub.messages # => the parsed bodies of every POST it stored
#   hub.requests # => every request that reached it, refused ones too
#
# `requests` is what a "before any hub call" test reads.
#
# Copied from alex-build's stub (task alex-build-takes-voice), with `requests`
# added. Run by the Ruby tests, by e2e/agent_chat_voice.spec.js through
# POST /test/agent_chat_lab, and by a desk with LOCAL_STUB_HUB=1.
class AgentChatContractHub
  attr_reader :port, :messages, :requests

  def self.start(...) = new(...).tap(&:start)

  def initialize(token:, souls: %w[turf_monster], answer_after: 1.0)
    @token = token
    @souls = souls
    @answer_after = answer_after
    @threads = Hash.new { |hash, key| hash[key] = [] }
    @messages = []
    @requests = []
    @seq = 0
    @lock = Mutex.new
  end

  def url = "http://127.0.0.1:#{port}"

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def stop
    @server&.close
    @thread&.join(1)
  end

  private

  def answer(method, path, query, headers, body)
    @lock.synchronize { @requests << "#{method} #{path}" }
    return [ 401, { error: "An app's agent-chat credential is required" } ] unless headers["authorization"] == "Bearer #{@token}"

    params = method == "POST" ? JSON.parse(body.to_s) : query
    return [ 404, { error: "no web chat" } ] unless @souls.include?(params["soul"].to_s)

    person = params["person"].to_h
    key = thread_key(person)
    return [ 422, { error: "person needs an email or an anon_token" } ] if key.nil?

    case [ method, path ]
    when [ "POST", "/api/v1/agent_chat/messages" ] then post_message(params, person, key)
    when [ "GET", "/api/v1/agent_chat/turns" ] then turns(key, params["after"])
    else [ 404, { error: "no such route" } ]
    end
  end

  def post_message(params, person, key)
    text = params["text"].to_s
    return [ 422, { error: "text is blank" } ] if text.strip.empty?

    voice = params["voice"]
    unless voice.nil? || (voice.is_a?(Hash) && Studio::VoiceTranscription::CHECKS.include?(voice["check"].to_s))
      return [ 422, { error: "voice.check is not one the engine answers" } ]
    end

    row = @lock.synchronize do
      @messages << params
      @seq += 1
      { id: @seq, text: text, at: Time.now.utc.iso8601(3), status: "pending", reply: nil }.tap { |r| @threads[key] << r }
    end
    Thread.new do
      sleep @answer_after / 2.0
      @lock.synchronize { row[:status] = "typing" }
      sleep @answer_after / 2.0
      @lock.synchronize { row.merge!(status: "answered", reply: "You said: #{row[:text]}") }
    end
    reply = { "turn" => @lock.synchronize { turns_of(row).first } }
    reply["voice"] = kept_voice(voice, person) if voice
    [ 201, reply ]
  end

  def turns(key, after)
    @lock.synchronize do
      rows = @threads[key]
      shown = after.to_s.match?(/\A\d+\z/) ? rows.select { |row| row[:id] > after.to_i } : rows
      [ 200, { "turns" => shown.flat_map { |row| turns_of(row) },
               "pending" => rows.any? { |row| %w[pending typing].include?(row[:status]) } } ]
    end
  end

  def kept_voice(voice, person)
    speaker = voice["check"] == "matched" ? person["email"].presence : nil
    voice.slice("check", "score", "duration_ms").merge("speaker" => speaker || Studio::VoiceTranscription::SOMEONE_NEW)
  end

  def thread_key(person)
    return "email:#{person["email"]}" if person["email"].present?

    "anon:#{person["anon_token"]}" if person["anon_token"].present?
  end

  def turns_of(row)
    user = { "id" => row[:id], "role" => "user", "text" => row[:text], "created_at" => row[:at], "status" => row[:status] }
    return [ user ] unless row[:reply]

    [ user, user.merge("role" => "agent", "text" => row[:reply]) ]
  end

  def serve(socket)
    method, target, = socket.gets.to_s.split(" ", 3)
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
    uri = URI.parse(target.to_s)
    status, payload = answer(method, uri.path, Rack::Utils.parse_nested_query(uri.query.to_s), headers, body)
    text = JSON.generate(payload)
    socket.write([ "HTTP/1.1 #{status} X", "Content-Type: application/json", "Content-Length: #{text.bytesize}",
                   "Connection: close" ].join("\r\n") + "\r\n\r\n" + text)
  rescue StandardError
    nil
  ensure
    socket.close rescue nil
  end
end
