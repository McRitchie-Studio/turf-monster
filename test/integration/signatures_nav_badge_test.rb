require "test_helper"

# The Signatures row in the admin nav, and the count it shows.
#
# The count is the point. `PendingTransaction.pending.count` was 11 on
# production the day this was built and 10 of those were `enter_contest` rows
# from June and July that nobody would ever cosign — so a badge wired to
# `pending` would have opened reading 11 with exactly one thing waiting, and
# taught the operator to ignore it immediately. Every assertion here is really
# about that distinction.
class SignaturesNavBadgeTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    PendingTransaction.delete_all
  end

  def ptx(status: "pending", stale: false)
    PendingTransaction.create!(
      tx_type: "settle_contest", serialized_tx: "WIRE-#{SecureRandom.hex(4)}",
      status: status, stale: stale, initiator_address: "init", metadata: {}.to_json
    )
  end

  def badge(body)
    body[/data-signature-count="(\d+)"/, 1]
  end

  def badge_classes(body)
    body[/class="([^"]*)"\s+data-signature-count=/, 1].to_s
  end

  test "an admin sees a Signatures link into the treasury queue" do
    log_in_as(@admin)
    get contests_path
    assert_response :success
    assert_match(/>Signatures</, response.body)
    assert_match(%r{href="#{Regexp.escape(admin_pending_transactions_path)}"}, response.body)
  end

  test "a non-admin sees no Signatures link" do
    log_in_as(users(:jordan))
    get contests_path
    assert_response :success
    assert_no_match(/>Signatures</, response.body)
    assert_no_match(/data-signature-count/, response.body)
  end

  test "the badge counts pending signatures" do
    3.times { ptx }
    log_in_as(@admin)
    get contests_path
    assert_equal "3", badge(response.body)
  end

  # The reason the stale flag exists.
  test "the badge does not count rows marked stale" do
    ptx
    2.times { ptx(stale: true) }
    log_in_as(@admin)
    get contests_path
    assert_equal "1", badge(response.body),
      "stale rows are still pending, but they must not inflate the badge"
  end

  test "the badge does not count transactions that are already resolved" do
    ptx
    ptx(status: "confirmed")
    ptx(status: "expired")
    log_in_as(@admin)
    get contests_path
    assert_equal "1", badge(response.body)
  end

  # The weight IS the signal — an operator should be able to catch it without
  # reading the digit.
  test "the badge is bold when something is waiting" do
    ptx
    log_in_as(@admin)
    get contests_path
    assert_includes badge_classes(response.body), "font-bold"
    assert_not_includes badge_classes(response.body), "font-normal"
  end

  test "the badge is gray and unbolded at zero" do
    log_in_as(@admin)
    get contests_path
    assert_equal "0", badge(response.body)
    assert_includes badge_classes(response.body), "font-normal"
    assert_includes badge_classes(response.body), "text-muted"
    assert_not_includes badge_classes(response.body), "font-bold"
  end
end
