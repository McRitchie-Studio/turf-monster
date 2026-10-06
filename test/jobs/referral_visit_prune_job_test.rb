require "test_helper"

# [unit] ReferralVisitPruneJob: the nightly cron (config/schedule.yml) deletes
# referral_visits rows past ReferralVisit::RETENTION and keeps the rest.
class ReferralVisitPruneJobTest < ActiveJob::TestCase
  def visit(on, n)
    ReferralVisit.record(reference: "tiktok", visitor_id: format("00000000-0000-4000-8000-%012d", n),
                         path: "/", at: on.to_time.change(hour: 10))
  end

  test "removes rows past the window and nothing newer" do
    travel_to Time.zone.parse("2026-10-05 04:29") do
      old = Date.current - ReferralVisit::RETENTION - 1
      visit(old, 1)
      visit(old - 30, 2)
      visit(Date.current - ReferralVisit::RETENTION, 3)
      visit(Date.current, 4)

      assert_difference("ReferralVisit.count", -2) { ReferralVisitPruneJob.perform_now }
      assert ReferralVisit.where(visited_on: ...(Date.current - ReferralVisit::RETENTION)).none?
    end
  end
end
