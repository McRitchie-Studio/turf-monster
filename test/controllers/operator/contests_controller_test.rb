require "test_helper"

# The hub's operator endpoint: inert without its token, 401 without the bearer,
# JSON on every answer (docs/OPERATOR_API.md).
class Operator::ContestsControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "test-operator-token-0123456789".freeze

  setup do
    @contest = contests(:one)
    @contest.update!(status: :open, onchain_contest_id: "onchain_operator")
    @previous = ENV["TURF_OPERATOR_TOKEN"]
    ENV["TURF_OPERATOR_TOKEN"] = TOKEN
  end

  teardown { ENV["TURF_OPERATOR_TOKEN"] = @previous }

  def auth(token = TOKEN) = { "Authorization" => "Bearer #{token}" }

  test "a bare 404 when no token is configured" do
    ENV["TURF_OPERATOR_TOKEN"] = ""
    get "/_operator/contests", headers: auth
    assert_response :not_found
  end

  test "401 without the bearer or with the wrong one, and nothing is queued" do
    get "/_operator/contests"
    assert_response :unauthorized
    assert_no_difference -> { PendingTransaction.count } do
      post "/_operator/contests/#{@contest.slug}/cancel", headers: auth("wrong")
    end
    assert_response :unauthorized
  end

  test "lists contests as JSON" do
    get "/_operator/contests", headers: auth
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal 1, body["schema"]
    assert body["contests"].any? { |c| c["slug"] == @contest.slug }
  end

  test "cancel queues a cosign; a paid entry with no choice is a 422 with its code" do
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post "/_operator/contests/#{@contest.slug}/cancel", params: { request_ref: "p-1" }, headers: auth, as: :json
    end
    assert_response :success
    assert_equal "queued", response.parsed_body["state"]

    other = Contest.create!(name: "Paid", slug: "paid-op", entry_fee_cents: 1900, status: :open, max_entries: 9,
                            contest_type: "medium", slate: slates(:one), user: users(:alex), skip_onchain_callback: true,
                            onchain_contest_id: "onchain_paid")
    Entry.create!(user: users(:sam), contest: other, status: :active, onchain_tx_signature: "sig-ctrl")
    post "/_operator/contests/#{other.slug}/cancel", headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_equal "paid_entries_need_choice", response.parsed_body["error"]
  end

  test "an unexpected error is a 500 with no message" do
    Operator::ContestOps.stub :new, -> { raise "secret-ish detail" } do
      get "/_operator/contests", headers: auth
    end
    assert_response :internal_server_error
    assert_equal({ "schema" => 1, "error" => "failed" }, response.parsed_body)
  end
end
