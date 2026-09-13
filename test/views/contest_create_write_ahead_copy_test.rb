require "test_helper"

# [component] The admin note under Create Contest on /contests/new must say
# what ContestsController#finalize actually does with the Contest row.
#
# WHY THIS IS PINNED. The note used to say the DB row was created only after
# the on-chain transaction confirmed, "no orphans possible". The code has done
# the opposite since PR #551: finalize saves a `pending` row
# (build_pending_contest + save!) BEFORE the broadcast, stamps the signature,
# verifies, and only then promotes the row to `open`. Any failed step leaves
# that pending row behind, and Contests::PendingReconciler, run by
# PendingContestReconcilerJob on the sidekiq-cron schedule, is what resolves
# it. An operator reads this note on a money path and reasons from it.
#
# Both tests assert the RIGHT sentence, never the absence of the old one: a
# deleted paragraph passes an absence check.
class ContestCreateWriteAheadCopyTest < ActionDispatch::IntegrationTest
  # The note is the paragraph directly under the Create Contest submit button.
  NOTE = "button[data-creating-label] + p".freeze

  setup { log_in_as(users(:alex)) }

  def note_text
    # The Season select maps over list-shaped seasons; FakeVault's default
    # single-season hash does not render.
    Solana::Vault.stub :new, FakeVault.new(seasons: [{ season_id: 1, name: "Season 1" }]) do
      get new_contest_path
    end
    assert_response :success
    notes = css_select(NOTE)
    assert_equal 1, notes.size, "expected exactly one note under the Create Contest button"
    notes.first.text.squish
  end

  test "names the pending row finalize writes before the broadcast" do
    assert_includes note_text,
      "The contest row is saved as pending before the transaction broadcasts"
  end

  # The cadence is DERIVED from the schedule the sweep really runs on, so a
  # retuned cron fails here instead of leaving the note quoting a stale number.
  test "names the sweep cadence config/schedule.yml actually runs" do
    cron = YAML.load_file(Rails.root.join("config/schedule.yml"))
               .fetch("pending_contest_reconciler").fetch("cron")
    minutes = cron[%r{\A\*/(\d+) }, 1]
    assert minutes, "pending_contest_reconciler cron is no longer */N minutes (#{cron.inspect}); re-word the note"
    assert_includes note_text, "a sweep every #{minutes} minutes"
  end
end
