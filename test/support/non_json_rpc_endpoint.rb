# A REAL HTTP server, on a real socket, that answers every request with a body
# of our choosing — including bodies that are not JSON at all.
#
# WHY A REAL SERVER AND NOT A STUB. The bug this exists for
# (survive-unauthorized-rpc-boot) is that an unauthorized RPC provider replies
# with PLAIN TEXT, and solana-studio's Solana::Client#call runs
# `JSON.parse(response.body)` with no rescue — so a raw JSON::ParserError comes
# out of the gem, NOT a Solana::Client::RpcError. A test that stubs the client
# to raise RpcError exercises the branch that already worked and proves nothing.
# The only way to prove the real failure mode is to let the real gem parse a
# real non-JSON body off a real socket.
#
# `http://127.0.0.1` is deliberate and permitted: solana-studio's
# `validate_rpc_scheme!` refuses plain http:// EXCEPT for the hosts in
# Solana::Client::HTTP_OK_HOSTS, which includes 127.0.0.1. So the client under
# test takes its normal code path.
#
# Binds port 0 (kernel-assigned) so parallel test workers never collide.
class NonJsonRpcEndpoint
  # Serve `body` for the duration of the block, then shut down.
  #
  #   NonJsonRpcEndpoint.serving(status: "401 Unauthorized", body: "Unauthorized") do |endpoint|
  #     Solana::Client.new(rpc_url: endpoint.url).get_genesis_hash
  #   end
  def self.serving(status:, body:, content_type: "text/plain", query: nil)
    endpoint = new(status: status, body: body, content_type: content_type, query: query)
    endpoint.start
    yield endpoint
  ensure
    endpoint&.stop
  end

  def initialize(status:, body:, content_type: "text/plain", query: nil)
    @status       = status
    @body         = body.to_s
    @content_type = content_type
    @query        = query
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port   = @server.addr[1]
    @thread = Thread.new { accept_loop }
    @thread.abort_on_exception = false
    self
  end

  def stop
    @server&.close
    @thread&.kill
    @thread&.join(1)
  end

  # The RPC URL to hand Solana::Client. `query` lets a caller attach a FAKE
  # credential sentinel so a test can assert the redaction of what gets logged.
  def url
    base = "http://127.0.0.1:#{@port}/"
    @query ? "#{base}?#{@query}" : base
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      begin
        read_request(socket)
        socket.write(response)
      rescue StandardError
        # A client that hung up mid-exchange is not this helper's problem.
      ensure
        socket.close rescue nil
      end
    end
  rescue IOError, Errno::EBADF
    # @server was closed by #stop — normal shutdown.
  end

  # Drain headers, then the declared body, so the client sees a clean exchange
  # rather than a connection reset it would retry against.
  def read_request(socket)
    length = 0
    while (line = socket.gets)
      break if line == "\r\n" || line == "\n"

      length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
    end
    socket.read(length) if length.positive?
  end

  def response
    [
      "HTTP/1.1 #{@status}",
      "Content-Type: #{@content_type}",
      "Content-Length: #{@body.bytesize}",
      "Connection: close",
      "",
      @body
    ].join("\r\n")
  end
end
