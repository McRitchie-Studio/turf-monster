require "test_helper"
require "csv"

# [integration] A refused namesake must be REACHABLE, not merely written.
#
# Card /tasks/turf-seed-stats-over-report asked for a durable record of the
# humans this importer refuses. A row in `error_logs` is only half of that: the
# operator finds it through Admin::ErrorLogsController, and that controller has
# two requirements a hand-rolled `ErrorLog.create!` can silently miss —
#
#   * `#show` looks rows up BY SLUG (`find_by!(slug:)`), so a row written
#     without one exists in the table and 404s in the only UI that reads it.
#   * the class facet is PARSED out of the `inspect` column
#     (Admin::ErrorLogsHelper.error_class_from_inspect), so a row whose inspect
#     is not shaped `#<Class: msg>` scatters into "Unknown".
#
# Both are wiring, not behaviour: the seeder's own unit tests pass whether or
# not either holds. These are the tests that notice if the supplying line goes.
class NflverseRefusalErrorLogTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    run_refusal!
    @log = ErrorLog.where(target_type: "Athlete").order(:id).last
  end

  # One namesake pair where the second man carries no identifier at all, which
  # is the refusal `resolve_athlete!` cannot slug its way out of.
  def run_refusal!
    headers = %w[gsis_id nfl_id pff_id otc_id espn_id pfr_id
                 common_first_name first_name last_name status last_season position latest_team]
    first  = ["", "52481", "60001", "otc-ja", "4262921", "JeffJu00",
              "Justin", "Justin", "Jefferson", "ACT", "2026", "WR", "MIN"]
    blank  = ["", "", "", "", "", "",
              "Justin", "Justin", "Jefferson", "ACT", "2026", "WR", "CLE"]
    body = CSV.generate do |out|
      out << headers
      out << first
      out << blank
    end
    Nflverse::SeedPlayers.new(upload_headshots: false, csv_body: body).call
  end

  test "the refusal was recorded at all" do
    assert_not_nil @log, "a refused namesake must leave an ErrorLog row"
    assert_match(/refused namesake Justin Jefferson/, @log.message)
  end

  test "an admin can open the refusal by slug" do
    assert @log.slug.present?, "a slug-less row is unreachable in /admin/error_logs"

    log_in_as(@admin)
    get admin_error_log_path(@log.slug)

    assert_response :success
    assert_match(/Justin Jefferson/, response.body)
  end

  test "the refusal files under its own class facet, not Unknown" do
    log_in_as(@admin)
    get admin_error_logs_path(klass: "Nflverse::SeedPlayers::NamesakeRefused")

    assert_response :success
    assert_match(/refused namesake Justin Jefferson/, response.body,
                 "the klass filter must find the refusal by its own class name")
  end

  test "the refusal deep-links to the athlete that held the slug" do
    assert_equal "Athlete", @log.target_type
    assert_equal "justin-jefferson", @log.target_name
    assert_equal Athlete.find_by(person_slug: "justin-jefferson").id, @log.target_id
  end
end
