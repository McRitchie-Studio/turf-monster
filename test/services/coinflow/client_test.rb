require "test_helper"

# Coinflow::Client unit tests, stubbed at the Net::HTTP seam (house rule:
# minitest inline stubs only, no webmock/VCR — mirrors Paypal::ClientTest).
# Coinflow ships no Ruby SDK, so this client IS the integration layer; a scripted
# FakeHttp records every outgoing Net::HTTPRequest and replays a response queue.
class Coinflow::ClientTest < ActiveSupport::TestCase
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

  setup { @client = Coinflow::Client.new }

  def ok_link(link = "https://sandbox.coinflow.cash/solana/purchase-v2/turfmonster")
    FakeHttp::Response.new("200", { link: link }.to_json)
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
    assert Coinflow::Client.sandbox?
    assert_equal "https://api-sandbox.coinflow.cash", Coinflow::Client.base_url
  end

  # ── create_checkout_link ─────────────────────────────────────────────────

  # A buyer stand-in: the client reads only #id (auth header) and #email.
  def fake_user(id: 42, email: "buyer@example.com")
    Struct.new(:id, :email).new(id, email)
  end

  test "create_checkout_link derives the pack subtotal and lists the wallet + card/paypal/venmo methods" do
    http = FakeHttp.new([ok_link])
    user = fake_user

    link = Net::HTTP.stub(:new, http) do
      @client.create_checkout_link(
        user: user, pack: StripePurchase.pack("single"), pack_id: "single",
        return_url: "http://localhost:3111/tokens/buy?coinflow=return", ip: "1.2.3.4"
      )
    end
    assert_equal "https://sandbox.coinflow.cash/solana/purchase-v2/turfmonster", link

    req = http.requests.last
    assert_equal "POST", req.method
    assert_equal "/api/checkout/link", req.path
    assert_equal "tm_user_42", req["x-coinflow-auth-user-id"]

    body = JSON.parse(req.body)
    # Amount derives SERVER-SIDE from the pack — the caller only names a pack id.
    assert_equal 1900, body.dig("subtotal", "cents")
    assert_equal "USD", body.dig("subtotal", "currency")
    # The consumer rails, wallet buttons first: Apple/Google Pay + card + PayPal
    # + Venmo (bank/wire/SEPA/crypto/Cash App/APA/Interac all dropped).
    assert_equal %w[applePay googlePay card paypal venmo], body["allowedPaymentMethods"]
    assert_equal "http://localhost:3111/tokens/buy?coinflow=return",
                 body.dig("standaloneLinkConfig", "callbackUrl")
    assert_equal "1.2.3.4", body.dig("standaloneLinkConfig", "endUserDeviceIpAddress")
  end

  # The regression this file exists to hold: without chargebackProtectionData the
  # create-link call still returns 200, and the buyer only discovers the problem
  # at Confirm Purchase on Coinflow's hosted page ("chargebackProtectionData is
  # required"). Assert the ARRAY IS SENT and carries the underwriter's fields —
  # a 200 response proves nothing here, so there is no proxy to assert instead.
  test "create_checkout_link sends chargebackProtectionData describing the entry-token cart" do
    http = FakeHttp.new([ok_link])

    Net::HTTP.stub(:new, http) do
      @client.create_checkout_link(
        user: fake_user, pack: StripePurchase.pack("trio"), pack_id: "trio",
        return_url: "http://x", ip: "1.2.3.4"
      )
    end

    items = JSON.parse(http.requests.last.body)["chargebackProtectionData"]
    assert_equal 1, items.length, "expected exactly one cart item"
    item = items.first
    assert_equal "Turf Monster entry token", item["productName"]
    # Coinflow's productType enum — skill-based contests, not a game of chance.
    assert_equal "gameOfSkill", item["productType"]
    # Quantity is the PACK's token count (trio => 3), not the number of carts.
    assert_equal 3, item["quantity"]
    assert_equal "trio", item.dig("rawProductData", "packId")
    assert_equal 4900, item.dig("rawProductData", "priceCents")
  end

  test "create_checkout_link sends the buyer email as an underwriter identity signal" do
    http = FakeHttp.new([ok_link])

    Net::HTTP.stub(:new, http) do
      @client.create_checkout_link(
        user: fake_user(email: "buyer@example.com"), pack: StripePurchase.pack("single"),
        pack_id: "single", return_url: "http://x", ip: "1.2.3.4"
      )
    end
    assert_equal "buyer@example.com", JSON.parse(http.requests.last.body)["email"]
  end

  # Never send `email: null` — omit the key so Coinflow validates the rest of the
  # body instead of rejecting an explicit null.
  test "create_checkout_link omits email entirely when the buyer has none" do
    http = FakeHttp.new([ok_link])

    Net::HTTP.stub(:new, http) do
      @client.create_checkout_link(
        user: fake_user(email: nil), pack: StripePurchase.pack("single"),
        pack_id: "single", return_url: "http://x", ip: "1.2.3.4"
      )
    end
    body = JSON.parse(http.requests.last.body)
    refute body.key?("email"), "blank email must be omitted, not sent as null"
    # The cart data still rides along — a missing email must not drop it.
    assert_equal 1, body["chargebackProtectionData"].length
  end

  test "create_checkout_link raises Coinflow::Client::Error when the response has no link" do
    http = FakeHttp.new([FakeHttp::Response.new("200", {}.to_json)])
    assert_raises(Coinflow::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_checkout_link(
          user: fake_user(id: 7), pack: StripePurchase.pack("single"), pack_id: "single",
          return_url: "http://x", ip: "1.2.3.4"
        )
      end
    end
  end

  test "a non-2xx response raises with the Coinflow message" do
    http = FakeHttp.new([FakeHttp::Response.new("422", { message: "bad request" }.to_json)])
    err = assert_raises(Coinflow::Client::Error) do
      Net::HTTP.stub(:new, http) do
        @client.create_checkout_link(
          user: fake_user(id: 7), pack: StripePurchase.pack("single"), pack_id: "single",
          return_url: "http://x", ip: "1.2.3.4"
        )
      end
    end
    assert_match(/422/, err.message)
    assert_match(/bad request/, err.message)
  end

  # ── verify_webhook_auth (shared-secret, constant-time, fails closed) ───────

  test "verify_webhook_auth matches the validation key and fails closed otherwise" do
    with_env("COINFLOW_WEBHOOK_VALIDATION_KEY", "secret-123") do
      assert @client.verify_webhook_auth("secret-123")
      refute @client.verify_webhook_auth("wrong-value")
      refute @client.verify_webhook_auth("")
      refute @client.verify_webhook_auth(nil)
    end
  end

  test "verify_webhook_auth fails closed when the validation key is unset" do
    with_env("COINFLOW_WEBHOOK_VALIDATION_KEY", nil) do
      refute @client.verify_webhook_auth("anything")
    end
  end
end
