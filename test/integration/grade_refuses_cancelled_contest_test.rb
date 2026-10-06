require "test_helper"

# [integration] A contest cancelled on chain keeps `status: "open"`, so the
# admin grade button still posts to it. The admin grade action must answer
# with the refusal, never a 500, and grade nothing. The control grades the
# same contest uncancelled through the same door.
class GradeRefusesCancelledContestTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @contest = Contest.create!(name: "Cancel guard #{SecureRandom.hex(2)}", slate: slates(:one),
                               rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                               user: @admin, status: "open", max_entries: 29)
    player = User.create!(email: "cancel_guard_#{SecureRandom.hex(4)}@example.com")
    @entry = Entry.create!(user: player, contest: @contest, status: "active", score: 100.0)
    log_in_as(@admin)
  end

  test "the admin grade action on a cancelled contest shows the refusal and grades nothing" do
    @contest.update_columns(onchain_cancelled: true)

    assert_no_difference -> { ErrorLog.count } do
      post grade_contest_path(@contest)
    end

    assert_redirected_to contest_page_path(@contest)
    assert_equal Contest::CANCELLED_GRADE_MESSAGE, flash[:alert]
    assert_ungraded
  end

  test "the JSON grade call on a cancelled contest answers 422 with the refusal" do
    @contest.update_columns(onchain_cancelled: true)

    post grade_contest_path(@contest), as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal Contest::CANCELLED_GRADE_MESSAGE, body["error"]
    assert_ungraded
  end

  test "control: the same contest, not cancelled, grades through the same action" do
    post grade_contest_path(@contest)

    assert_redirected_to contest_path(@contest)
    assert_equal "Contest graded and settled!", flash[:notice]
    assert_equal "settled", @contest.reload.status
    assert_equal 300_00, @entry.reload.payout_cents
    assert_equal 1, TransactionLog.where(source: @contest).count
  end

  private

  def assert_ungraded
    assert_equal "open", @contest.reload.status
    assert_equal "active", @entry.reload.status
    assert_nil @entry.payout_cents.to_i.nonzero?
    assert_equal 0, TransactionLog.where(source: @contest).count
    assert_equal 0, PendingTransaction.where(target: @contest).count
  end
end
