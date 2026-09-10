require "test_helper"

# Aeropay::Client unit tests, stubbed at the Net::HTTP seam (house rule:
# minitest inline stubs only, no webmock/VCR — mirrors Coinflow::ClientTest).
# Aeropay ships no Ruby SDK, so this client IS the integration layer; a scripted
# FakeHttp records every outgoing Net::HTTPRequest and replays a response queue.
#
# NOTE: every request/response field asserted here is a doc-derived ASSUMPTION
# (built to dev.aero.inc/docs without a live sandbox) — these tests lock the
# shape THIS client sends/expects so a future contract correction is a visible
# diff, not a silent drift.
class Aeropay::ClientTest < ActiveSupport::TestCase
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :requests
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(responses)
      @responses = responses
      @requests  = []
    end

    def request(req)
      @requests << req
      raise "FakeHttp queue empty for #{req.method} #{req.path}" if @responses.empty?
      @responses.shift
    end
  end

  setup { @client = Aeropay::Client.new }

  def ok_transaction(id = "txn_ABC123", status = "pending")
    FakeHttp::Response.new("200", { id: id, status: status }.to_json)
  end

  def with_env(key, value)
    original = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    original.nil? ? ENV.delete(key) : ENV[key] = original
  end

  # ── Environment ───────────────────────────────────────────────────────────

  test "base_url defaults to the sandbox host and sandbox? is true there" do
    assert Aeropay::Client.sandbox?
    assert_equal "https://api.sandbox-pay.aero.inc/v2", Aeropay::Client.base_url
  end

  test "base_url is ENV-overridable and sandbox? follows the host" do
    with_env("AEROPAY_API_BASE", "https://api.aeropay.com/v2") do
      assert_equal "https://api.aeropay.com/v2", Aeropay::Client.base_url
      refute Aeropay::Client.sandbox?
    end
  end

  # ── create_deposit ────────────────────────────────────────────────────────

  test "create_deposit derives the pack amount SERVER-SIDE, targets /v2/transaction, and sends Bearer auth" do
    http = FakeHttp.new([ok_transaction("txn_HAPPY", "pending")])
    user = Struct.new(:id).new(42)

    deposit = with_env("AEROPAY_API_TOKEN", "sk_test_123") do
      with_env("AEROPAY_MERCHANT_ID", "merch_1") do
        Net::HTTP.stub(:new, http) do
          @client.create_deposit(
            user: user, pack: StripePurchase.pack("single"),
            bank_account_id: "bank_9", reference: "aeropay_ref1", idempotency_key: "aeropay_ref1"
          )
        end
      end
    end

    assert_equal "txn_HAPPY", deposit["id"]
    assert_equal "pending", deposit["status"]

    req = http.requests.last
    assert_equal "POST", req.method
    # The /v2 version segment from the base URL must survive (URI.join would drop it).
    assert_equal "/v2/transaction", req.path
    assert_equal "Bearer sk_test_123", req["Authorization"]
    assert_equal "aeropay_ref1", req["Idempotency-Key"]

    body = JSON.parse(req.body)
    # Amount derives SERVER-SIDE from the pack, as decimal dollars — the caller
    # only names a pack id. (FLAG: dollars-vs-cents assumption.)
    assert_equal "19.00", body["amount"]
    assert_equal "USD", body["currency"]
    assert_equal "bank_9", body["bankAccountId"]
    assert_equal "aeropay_ref1", body["externalId"]
    assert_equal "instant", body["paymentRail"], "prefers the irrevocable RfP/RTP pay-in"
    assert_equal "merch_1", body["merchantId"]
  end

  test "create_deposit reads the transaction id from a nested data envelope too" do
    http = FakeHttp.new([FakeHttp::Response.new("200", { data: { id: "txn_NESTED", status: "completed" } }.to_json)])
    deposit = Net::HTTP.stub(:new, http) do
      @client.create_deposit(
        user: Struct.new(:id).new(7), pack: StripePurchase.pack("single"),
        bank_account_id: "bank_1", reference: "ref"
      )
    end
    assert_equal "txn_NESTED", deposit["id"]
    assert_equal "completed", deposit["status"]
  end

  test "create_deposit raises Aeropay::Client::Error when the response has no transaction id" do
    http = FakeHttp.new([FakeHttp::Response.new("200", {}.to_json)])
    assert_raises(Aeropay::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_deposit(
          user: Struct.new(:id).new(7), pack: StripePurchase.pack("single"),
          bank_account_id: "bank_1", reference: "ref"
        )
      end
    end
  end

  test "a non-2xx response raises with the Aeropay message" do
    http = FakeHttp.new([FakeHttp::Response.new("422", { message: "bank account not found" }.to_json)])
    err = assert_raises(Aeropay::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_deposit(
          user: Struct.new(:id).new(7), pack: StripePurchase.pack("single"),
          bank_account_id: "bad", reference: "ref"
        )
      end
    end
    assert_match(/422/, err.message)
    assert_match(/bank account not found/, err.message)
  end

  # ── Aerosync bank-link exchange (server-side leg; widget stubbed) ──────────

  test "link_account_from_aggregator GETs /v2/linkAccountFromAggregator with the token" do
    http = FakeHttp.new([FakeHttp::Response.new("200", { bankAccountId: "bank_new" }.to_json)])
    body = Net::HTTP.stub(:new, http) { @client.link_account_from_aggregator(token: "aggr_tok") }
    assert_equal "bank_new", body["bankAccountId"]
    req = http.requests.last
    assert_equal "GET", req.method
    assert_includes req.path, "/v2/linkAccountFromAggregator"
    assert_includes req.path, "token=aggr_tok"
  end

  test "bank_accounts GETs /v2/bankAccounts" do
    http = FakeHttp.new([FakeHttp::Response.new("200", { accounts: [] }.to_json)])
    Net::HTTP.stub(:new, http) { @client.bank_accounts(customer_id: "cust_1") }
    req = http.requests.last
    assert_equal "GET", req.method
    assert_includes req.path, "/v2/bankAccounts"
    assert_includes req.path, "customerId=cust_1"
  end

  # ── verify_webhook (HMAC-SHA256 over raw body, constant-time, fails closed) ─

  test "verify_webhook matches the HMAC of the raw body and fails closed otherwise" do
    with_env("AEROPAY_WEBHOOK_SIGNING_KEY", "whsec_123") do
      raw = { "topic" => "transaction_completed", "data" => { "id" => "txn_1" } }.to_json
      good = OpenSSL::HMAC.hexdigest("SHA256", "whsec_123", raw)

      assert @client.verify_webhook(raw, good)
      refute @client.verify_webhook(raw, "deadbeef"), "a wrong signature fails"
      refute @client.verify_webhook(raw, ""), "a blank signature fails"
      refute @client.verify_webhook(raw, nil), "a nil signature fails"
      refute @client.verify_webhook("#{raw} tampered", good), "a tampered body fails"
    end
  end

  test "verify_webhook fails closed when the signing key is unset" do
    with_env("AEROPAY_WEBHOOK_SIGNING_KEY", nil) do
      assert_not @client.verify_webhook("body", "anything")
    end
  end
end
