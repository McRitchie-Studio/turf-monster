# A real Solana::Client whose transport answers HTTP 429 to every request, and
# whose sleeps are recorded instead of slept.
#
# Everything between the transport and the caller is the gem's own code: the
# retry loop, the Retry-After reading, the wait budget, the CallStats, and the
# ClientLogger prepended over #call. Only two private seams are replaced, on
# this one instance: #http_post (the wire) and #sleep (the clock).
#
#   client = ThrottledRpc.client(retry_after: 3)
#   assert_raises(Solana::Client::HttpError) { client.get_account_info("x") }
#   client.slept   # => [3.2]           the waits the gem chose
#   client.posts   # => 2               the attempts that reached the wire
#
# `succeed_after: n` answers 429 n times, then a JSON-RPC result, for a read
# that recovers.
module ThrottledRpc
  Response = Struct.new(:code, :body, :headers) do
    def [](name)
      headers[name]
    end
  end

  def self.client(retry_after: 3, succeed_after: nil, result: { "value" => nil })
    client = Solana::Client.new(rpc_url: "https://rpc.throttled.test")
    slept = []
    posts = 0

    client.define_singleton_method(:http_post) do |body|
      posts += 1
      if succeed_after && posts > succeed_after
        Response.new("200", { jsonrpc: "2.0", id: body[:id], result: result }.to_json, {})
      else
        Response.new("429", "Too many requests", { "Retry-After" => retry_after.to_s })
      end
    end
    client.define_singleton_method(:sleep) { |seconds| slept << seconds }
    client.define_singleton_method(:slept) { slept }
    client.define_singleton_method(:posts) { posts }
    client
  end
end
