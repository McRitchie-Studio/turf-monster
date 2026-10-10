require "test_helper"

# [unit] The bundled solana-studio gem bounds every RPC post: 10 seconds to
# connect, 30 to read. The entry and settlement paths budget their requests
# against those two numbers (Solana::Deadline, Entries::ManagedEntry), and the
# gem sets them inside Solana::Client#http_post with no option to pass. So the
# numbers are read here, off the connection the client really builds: a gem
# bump that drops or changes them fails this test.
class Solana::ClientHttpTimeoutsTest < ActiveSupport::TestCase
  class RecordingHttp
    attr_accessor :use_ssl, :verify_mode, :min_version, :open_timeout, :read_timeout
    attr_reader :timeouts_at_request

    def request(_request)
      @timeouts_at_request = [open_timeout, read_timeout]
      Struct.new(:code, :body).new("200", { jsonrpc: "2.0", id: 1, result: 123 }.to_json)
    end
  end

  test "an RPC post carries a 10 second connect timeout and a 30 second read timeout" do
    http = RecordingHttp.new

    answer = Net::HTTP.stub(:new, http) do
      Solana::Client.new(rpc_url: "https://rpc.example.test").get_block_height
    end

    assert_equal 123, answer, "CONTROL: the call went through the recorded connection"
    assert_equal [10, 30], http.timeouts_at_request
  end
end
