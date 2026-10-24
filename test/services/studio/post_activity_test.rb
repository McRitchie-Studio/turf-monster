require "test_helper"

# [unit] Studio::PostActivity: best effort, and it says which.
class Studio::PostActivityTest < ActiveSupport::TestCase
  class Http
    attr_reader :requests

    def initialize(response) = (@response = response) && (@requests = [])

    def request(req)
      @requests << req
      @response
    end
  end

  def response(klass, code, body = "{}")
    klass.new("1.1", code, "x").tap { |r| r.instance_variable_set(:@body, body) && r.instance_variable_set(:@read, true) }
  end

  test "posts with the runtime key and reports posted" do
    http = Http.new(response(Net::HTTPCreated, "201", { data: {} }.to_json))
    result = Studio::PostActivity.new(runtime_key: "rk", http: http).call(description: "d", metadata: { a: 1 })
    assert_equal "posted", result
    req = http.requests.first
    assert_equal "/api/v1/activities", req.path
    assert_equal "Bearer rk", req["Authorization"]
    assert_equal "platform_cosign", JSON.parse(req.body)["activity_type"]
  end

  test "a refusal is reported, never raised" do
    http = Http.new(response(Net::HTTPForbidden, "403"))
    result = Studio::PostActivity.new(runtime_key: "rk", http: http).call(description: "d")
    assert_match(/\Anot posted: .*403/, result)
  end

  test "no credential is reported, never raised" do
    result = Studio::PostActivity.new(runtime_key: "", secret: "").call(description: "d")
    assert_match(/\Anot posted: neither/, result)
  end
end
