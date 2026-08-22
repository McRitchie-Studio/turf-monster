require "test_helper"

# OPSEC-039's boot-time cluster alignment check, driven through the REAL
# initializer file.
#
# THE BUG (survive-unauthorized-rpc-boot). The check rescued exactly one class,
# `Solana::Client::RpcError`. But solana-studio's Solana::Client#call does
# `JSON.parse(response.body)` with no rescue of its own, so an upstream that
# answers with anything OTHER than JSON — an unauthorized provider's
# "Unauthorized", a 403 HTML error page, a proxy's plaintext, a gateway timeout
# page — produces a raw JSON::ParserError. That walked straight past the rescue
# and ABORTED BOOT, including at slug-compile time.
#
# Why it mattered more than its size: the mainnet Helius key had been served in
# page source and had to be rotated, and revoking it would have taken
# turf-monster-mainnet down by this exact path — with the fix undeployable,
# because slug compile runs this too.
#
# WHY THESE TESTS USE A REAL SOCKET. Stubbing the client to raise RpcError would
# exercise the branch that ALREADY worked. The failure mode only exists because a
# real body fails to parse inside the real gem, so NonJsonRpcEndpoint serves real
# non-JSON off a real socket and the initializer builds its own real client.
# Nothing about the error is injected; only the endpoint is.
#
# The two halves of the contract are both asserted here, because widening a
# rescue is only correct if the check still REFUSES when it has real evidence:
#   - INDETERMINATE (unreachable / unauthorized / unparseable) => log + boot.
#   - DETERMINATE MISMATCH (a genesis hash that came back and disagrees)
#     => still fatal, exactly as before.
class SolanaNetworkAlignmentTest < ActiveSupport::TestCase
  INITIALIZER     = Rails.root.join("config/initializers/solana_network_alignment.rb").to_s
  DEVNET_GENESIS  = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG".freeze
  MAINNET_GENESIS = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d".freeze

  # A value that is obviously not a real credential, so a failure message or a
  # captured log can be shown to anyone. Never put a live key in a test.
  SENTINEL_KEY = "SENTINEL-NOT-A-REAL-KEY-0000".freeze

  # Bodies a hostile or unauthorized upstream really returns. Every one of these
  # raises JSON::ParserError inside Solana::Client#call.
  NON_JSON_RESPONSES = {
    "an unauthorized provider's plaintext" => {
      status: "401 Unauthorized", body: "Unauthorized", content_type: "text/plain"
    },
    "a 403 HTML error page" => {
      status: "403 Forbidden",
      body: "<html><head><title>403 Forbidden</title></head><body><h1>403 Forbidden</h1></body></html>",
      content_type: "text/html"
    },
    "a gateway timeout page" => {
      status: "504 Gateway Time-out",
      body: "<html><body><h1>504 Gateway Time-out</h1><hr>nginx</body></html>",
      content_type: "text/html"
    },
    # Bodies that are not UTF-8 AT ALL. These are separate from the four above:
    # the parser quotes the offending token into its message, so an invalid byte
    # in the FIRST token lands inside e.message and the rescue body's own gsub
    # raises ArgumentError — uncaught, because it is raised from inside the
    # rescue clause. A high byte MID-body does not reproduce it (the parser
    # quotes only the ASCII first token), so these bodies start with one.
    "a latin-1 error page (invalid UTF-8)" => {
      status: "401 Unauthorized", body: "\xE9chec d'authentification".b, content_type: "text/plain"
    },
    "a gzipped body served without Content-Encoding" => {
      status: "502 Bad Gateway", body: "\x1F\x8B\x08\x00\x00\x00\x00\x00\x00\x03".b, content_type: "text/plain"
    },
    "an empty body" => {
      status: "200 OK", body: "", content_type: "text/plain"
    }
  }.freeze

  # --- the regression: none of these may abort boot -------------------------

  NON_JSON_RESPONSES.each do |label, response|
    test "boot SURVIVES #{label} from the RPC" do
      escaped = capture_boot_failure(**response)

      assert_nil escaped,
                 "the alignment check let #{escaped&.class} escape and ABORT BOOT. " \
                 "A non-JSON upstream body must degrade to a log line, not kill the " \
                 "process — rotating the mainnet RPC credential depends on it."
    end
  end

  test "boot SURVIVES an RPC that refuses the connection outright" do
    # Nothing is listening on this port: Errno::ECONNREFUSED, which the gem also
    # leaves unwrapped (it wraps only OpenTimeout/ReadTimeout/ECONNRESET).
    dead = TCPServer.new("127.0.0.1", 0)
    port = dead.addr[1]
    dead.close

    escaped = nil
    begin
      run_initializer(rpc_url: "http://127.0.0.1:#{port}/")
    rescue StandardError => e
      escaped = e
    end

    assert_nil escaped,
               "a refused connection escaped as #{escaped&.class} and aborted boot"
  end

  test "boot SURVIVES an RPC URL the client itself rejects" do
    # Solana::Client::InsecureRpcUrlError descends from ArgumentError, is raised
    # from Client.new BEFORE any request, and is another non-RpcError class that
    # reached this path.
    escaped = nil
    begin
      run_initializer(rpc_url: "http://rpc.example.invalid/")
    rescue StandardError => e
      escaped = e
    end

    assert_nil escaped,
               "an unusable RPC URL escaped as #{escaped&.class} and aborted boot"
  end

  # --- the other half: the check must still bite ----------------------------

  test "a genuine genesis MISMATCH still REFUSES to boot" do
    # This is the guard's entire purpose, and the one case where fatal is right:
    # the RPC answered, so we have real evidence the cluster is wrong. If
    # widening the rescue ever swallows THIS, the check has been neutered.
    error = nil
    serving_genesis(MAINNET_GENESIS) do |url|
      error = assert_raises(RuntimeError) { run_initializer(rpc_url: url) }
    end

    assert_match(/refusing to boot/, error.message)
    assert_match(/OPSEC-039/, error.message)
  end

  test "a matching genesis boots and says so" do
    log = nil
    serving_genesis(DEVNET_GENESIS) do |url|
      log = capture_rails_log { run_initializer(rpc_url: url) }
    end

    assert_match(/network alignment OK/, log)
  end

  # --- opsec: the degraded log must not leak the credential -----------------

  test "the INCONCLUSIVE log redacts the endpoint's credential" do
    log = nil
    NonJsonRpcEndpoint.serving(
      status: "401 Unauthorized", body: "Unauthorized", query: "api-key=#{SENTINEL_KEY}"
    ) do |endpoint|
      log = capture_rails_log { run_initializer(rpc_url: endpoint.url) }
    end

    refute_includes log, SENTINEL_KEY,
                     "the alignment warning printed the RPC credential into the logs — " \
                     "this path fires precisely when the key is bad, so it is exactly " \
                     "where a leak would land"
    assert_match(/api-key=\*\*\*/, log,
                 "the operator still needs to see WHICH parameter was rejected")
    assert_match(/continuing boot/, log)
  end

  # The test above passes for a reason that does NOT generalise: on the 401 path
  # the exception is a JSON::ParserError whose message quotes the BODY, so it
  # CANNOT contain the endpoint. The redaction it proves is the second half of
  # the log line — `redact_rpc_url(RPC_URL)` — while `failure` (the interpolated
  # e.message) went in raw. These two cases are the ones where that mattered:
  # both classes embed the WHOLE credentialed URL in their own message.
  test "the INCONCLUSIVE log redacts a credential carried inside e.message" do
    # Solana::Client::InsecureRpcUrlError — the gem interpolates
    # `@rpc_url.inspect`. A pasted http:// endpoint is the most likely operator
    # error during a key rotation.
    log = capture_rails_log do
      run_initializer(rpc_url: "http://rpc.example.test/?api-key=#{SENTINEL_KEY}")
    end

    refute_includes log, SENTINEL_KEY,
                     "the exception message carried the credential straight into the log"
    assert_match(/InsecureRpcUrlError/, log, "the operator still needs the failure named")
    assert_match(/continuing boot/, log, "an indeterminate result must still boot")
  end

  test "the INCONCLUSIVE log redacts a credential inside an UNPARSEABLE endpoint" do
    # URI::InvalidURIError quotes the offending URI back. The credential is not
    # inside anything that parses as a URL, which is what makes this case
    # different from the one above.
    log = capture_rails_log do
      run_initializer(rpc_url: "https:// rpc.example.test/?api-key=#{SENTINEL_KEY}")
    end

    refute_includes log, SENTINEL_KEY,
                     "a malformed endpoint published its credential into the log"
    assert_match(/continuing boot/, log)
  end

  private

  # Run the REAL initializer against an endpoint serving `body`, returning the
  # exception that escaped (nil when boot survived).
  def capture_boot_failure(status:, body:, content_type:)
    NonJsonRpcEndpoint.serving(status: status, body: body, content_type: content_type) do |endpoint|
      begin
        run_initializer(rpc_url: endpoint.url)
        nil
      rescue StandardError => e
        e
      end
    end
  end

  # `config.after_initialize` registers against a load hook that has ALREADY
  # fired in a booted process, so ActiveSupport runs the block IMMEDIATELY —
  # which is what makes loading the real initializer a faithful drive of the
  # production path rather than a re-implementation of it.
  #
  # The file's first line is `Rails.env.test? || ...` -> skip, so `test?` is
  # stubbed false to reach the body at all.
  def run_initializer(rpc_url:)
    with_rpc_url(rpc_url) do
      Rails.env.stub(:test?, false) { load INITIALIZER }
    end
  end

  # The initializer reads Solana::Config::RPC_URL, a load-time constant. Swap it
  # rather than stubbing Solana::Client, so the client, the socket, the HTTP
  # exchange and the JSON parse are all the real ones.
  def with_rpc_url(url)
    saved = Solana::Config::RPC_URL
    swap_rpc_url(url)
    yield
  ensure
    swap_rpc_url(saved)
  end

  def swap_rpc_url(url)
    Solana::Config.send(:remove_const, :RPC_URL)
    Solana::Config.const_set(:RPC_URL, url)
  end

  # Serve one well-formed JSON-RPC reply carrying `genesis` — the shape a
  # HEALTHY getGenesisHash returns — and yield its URL for the duration.
  def serving_genesis(genesis)
    body = { jsonrpc: "2.0", id: 1, result: genesis }.to_json
    NonJsonRpcEndpoint.serving(status: "200 OK", body: body, content_type: "application/json") do |endpoint|
      yield endpoint.url
    end
  end

  def capture_rails_log
    io       = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
