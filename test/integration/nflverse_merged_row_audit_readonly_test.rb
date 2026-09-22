require "test_helper"
require "csv"

# [integration] Nflverse::MergedRowAudit against a seeded database — and the
# PROOF of the safety claim that lets it be pointed at production.
#
# "Read-only" is a claim about a RUN, not about a spelling. Grepping this
# service for `update` or `save` would only prove what this file's source says
# today; it would say nothing about a writer reached three call-frames down, and
# it would go on passing after someone adds one. So the claim is proven the only
# way it can be: by watching every SQL statement the audit actually emits over a
# seeded database that exercises both detectors, and asserting that not one of
# them is an INSERT, UPDATE or DELETE.
#
# The second test closes the other half — the audit's own objects REFUSE a write
# — so a future caller that gets hold of a row cannot quietly turn this into a
# repair tool. That is the enforcement; the subscriber is the proof.
class NflverseMergedRowAuditReadonlyTest < ActionDispatch::IntegrationTest
  WRITE_SQL = /\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE)\b/i

  HEADERS = %w[
    gsis_id nfl_id pff_id otc_id espn_id pfr_id
    common_first_name first_name last_name status last_season
  ].freeze

  # A database carrying EVERY failure shape plus clean rows, so the run under
  # observation is the real one and not a trivially empty scan.
  #
  # The last two rows exercise the WIDENED name lookup — one reached through the
  # feed's second spelling, one through a Person alias. Both are new query paths,
  # and a new path that runs outside this subscriber is a path the read-only
  # proof does not cover, so they are seeded here rather than only in the unit
  # suite. Each uses its own surname: a shared one would let `occupants.find`
  # pick either occupant and make the assertion depend on row order.
  setup do
    @clean = make_athlete("Alice", "Ant", gsis_id: "00-0020001")
    @foreign = make_athlete("Cara", "Crane", gsis_id: "00-0020003")  # actually Dave Drake's
    @namesake = make_athlete("Chris", "Smith", gsis_id: "00-0038661")
    @feed_spelling = make_athlete("Robert", "Beal", gsis_id: "00-0020005")
    @aliased = make_athlete("Christopher", "Stone", aliases: ["Chris Stone"], gsis_id: "00-0020007")

    @csv = CSV.generate do |csv|
      csv << HEADERS
      [
        ["00-0020001", "Alice", "Alice", "Ant"],
        ["00-0020002", "Cara", "Cara", "Crane"],
        ["00-0020003", "Dave", "Dave", "Drake"],
        ["00-0038661", "Chris", "Chris", "Smith"],
        ["00-0031234", "Chris", "Chris", "Smith"],
        # Turf stored "Robert"; the feed PREFERS "Rob" and carries "Robert" only
        # in first_name. The unheld twin is spelled the same way.
        ["00-0020005", "Rob", "Robert", "Beal"],
        ["00-0020006", "Rob", "Robert", "Beal"],
        # Turf stored "Christopher" with a "Chris Stone" alias; the feed knows
        # only "Chris", so the alias is the sole bridge.
        ["00-0020007", "Chris", "Chris", "Stone"],
        ["00-0020008", "Chris", "Chris", "Stone"]
      ].each do |gsis_id, common_first, first, last|
        csv << [gsis_id, nil, nil, nil, nil, nil, common_first, first, last, "ACT", "2026"]
      end
    end
  end

  def make_athlete(first, last, aliases: [], **ids)
    person = Person.create!(first_name: first, last_name: last, athlete: true, aliases: aliases)
    Athlete.create!(person_slug: person.slug, sport: "football", **ids)
  end

  # Captures every SQL statement the block issues. SCHEMA and TRANSACTION
  # statements are excluded because the test harness itself opens the wrapping
  # transaction and loads the schema cache — neither is the audit's doing, and
  # including them would make the assertion fail for a reason unrelated to it.
  def sql_during
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name].in?(["SCHEMA", "TRANSACTION"])

      statements << payload[:sql]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a full audit run over a seeded database issues no write statement" do
    result = nil
    statements = sql_during { result = Nflverse::MergedRowAudit.call(csv_body: @csv) }

    # The run has to have DONE something, or "no writes" is satisfied vacuously
    # by an audit that never opened the database at all.
    assert_operator statements.size, :>=, 2, "the audit must actually query"
    assert_operator result.athletes_checked, :>=, 3
    assert_equal 1, result.foreign_ids.size, "the seeded foreign-ID row is found"
    assert_equal %w[chris-smith-athlete christopher-stone-athlete robert-beal-athlete],
                 result.absorbed_namesakes.map(&:athlete_slug).sort,
                 "all three namesake shapes are found under observation — the exact " \
                 "spelling, the feed's second spelling, and the alias"

    writes = statements.grep(WRITE_SQL)
    assert_empty writes, "the audit issued write SQL: #{writes.inspect}"
  end

  test "the rows the audit loads refuse to be written" do
    loaded = nil
    Nflverse::MergedRowAudit.new(csv_body: @csv).send(:each_athlete) { |a| loaded ||= a }

    assert loaded.readonly?, "every athlete the audit loads is marked read-only"
    assert_raises(ActiveRecord::ReadOnlyRecord) { loaded.update!(jersey_number: 99) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { loaded.destroy }
  end

  test "the report names both humans behind each finding" do
    report = Nflverse::MergedRowAudit.call(csv_body: @csv).to_report

    # Detector one: the occupant from this database, the ID's owner from the feed.
    assert_match "Cara Crane", report
    assert_match "Dave Drake", report
    # Detector two: both humans share a name, so the second is named by his ID.
    assert_match "00-0031234", report
  end
end
