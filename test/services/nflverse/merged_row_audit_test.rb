require "test_helper"

# [unit] Nflverse::MergedRowAudit — finding athlete rows that hold a second
# human's league ID.
#
# Every test drives a hand-built CSV through `csv_body:` rather than the 7MB
# live feed, so the suite never touches the network.
#
# The two detectors are tested SEPARATELY AND AGAINST EACH OTHER, because the
# whole reason there are two is that each is blind where the other sees. The
# chris-smith test below asserts that the name-mismatch detector finds NOTHING
# there — if a refactor ever makes one detector appear to cover both shapes,
# that assertion is what catches it.
class Nflverse::MergedRowAuditTest < ActiveSupport::TestCase
  HEADERS = %w[
    gsis_id nfl_id pff_id otc_id espn_id pfr_id
    common_first_name first_name last_name status last_season
  ].freeze

  # One players.csv row. Defaults are ACTIVE and current so a test that cares
  # about the status/season filter has to say so.
  def feed_row(gsis_id:, first:, last:, common_first: nil, status: "ACT",
               last_season: "2026", espn_id: nil, pff_id: nil, otc_id: nil,
               pfr_id: nil, nfl_id: nil)
    {
      "gsis_id" => gsis_id, "nfl_id" => nfl_id, "pff_id" => pff_id,
      "otc_id" => otc_id, "espn_id" => espn_id, "pfr_id" => pfr_id,
      "common_first_name" => common_first || first, "first_name" => first,
      "last_name" => last, "status" => status, "last_season" => last_season
    }
  end

  def csv_for(*rows)
    CSV.generate do |csv|
      csv << HEADERS
      rows.each { |row| csv << HEADERS.map { |h| row[h] } }
    end
  end

  # A turf athlete, built the way the importer builds one.
  def athlete!(first, last, aliases: [], sport: "football", **ids)
    person = Person.create!(first_name: first, last_name: last, athlete: true, aliases: aliases)
    Athlete.create!(person_slug: person.slug, sport: sport, **ids)
  end

  def audit(*rows, **opts)
    Nflverse::MergedRowAudit.call(csv_body: csv_for(*rows), **opts)
  end

  # ── The baseline. Without it, a detector that never fires reads as correct. ──
  test "an athlete whose stored ID names the same human is not flagged" do
    athlete!("Alice", "Ant", gsis_id: "00-0010001")

    result = audit(feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"))

    assert_empty result.findings, "a correctly-identified athlete must not be flagged"
    assert result.clean?
  end

  # ── DETECTOR ONE: the row's name disagrees with the feed's owner of its ID ──
  test "[control] a row holding another human's gsis_id is named, and so is the human it belongs to" do
    athlete!("Alice", "Ant", gsis_id: "00-0010002")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"),
      feed_row(gsis_id: "00-0010002", first: "Bob", last: "Bee")
    )

    assert_equal 1, result.foreign_ids.size
    finding = result.foreign_ids.sole
    assert_equal "alice-ant-athlete", finding.athlete_slug
    assert_equal [["gsis_id", "00-0010002"]], finding.held_ids

    # BOTH HUMANS, each READ rather than inferred: the occupant from this
    # database, the other from the feed.
    assert_equal "Alice Ant", finding.occupant_name, "the human the row is named for"
    assert_equal "Bob Bee", finding.other_name, "the human the feed says owns that ID"
  end

  # A COUNT CANNOT SEE THIS. Two rows whose IDs are exchanged leave every
  # cardinality identical — same athletes, same people, same number of rows
  # carrying a gsis_id — so the audit has to assert the slug→ID MAPPING. This
  # test reverses an input rather than removing one, and pins the counts that
  # stay equal either way so the point cannot be lost in a later edit.
  test "a permutation of two athletes' IDs is caught, though every count is unchanged" do
    rows = [
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"),
      feed_row(gsis_id: "00-0010002", first: "Bob", last: "Bee")
    ]

    correct = athlete!("Alice", "Ant", gsis_id: "00-0010001")
    athlete!("Bob", "Bee", gsis_id: "00-0010002")
    before = audit(*rows)
    assert_empty before.findings

    # Reverse the mapping — the two humans keep their rows and swap identities.
    correct.update_columns(gsis_id: nil)
    Athlete.find_by(person_slug: "bob-bee").update_columns(gsis_id: "00-0010001")
    correct.update_columns(gsis_id: "00-0010002")

    after = audit(*rows)

    assert_equal before.athletes_checked, after.athletes_checked, "the count is identical"
    assert_equal before.ids_checked, after.ids_checked, "the count is identical"
    assert_equal 2, after.foreign_ids.size, "but the MAPPING is wrong in both directions"
    assert_equal ["Alice Ant", "Bob Bee"], after.foreign_ids.map(&:occupant_name).sort
    assert_equal ["Alice Ant", "Bob Bee"], after.foreign_ids.map(&:other_name).sort
  end

  # ── DETECTOR TWO: the chris-smith shape, which detector one cannot see ──────
  test "a namesake merge is caught even though the row's name matches its stored ID" do
    # The hub's incident: one Chris Smith's row absorbed the other, so it holds
    # 00-0038661 while the second Chris Smith has no row at all.
    athlete!("Chris", "Smith", gsis_id: "00-0038661")

    result = audit(
      feed_row(gsis_id: "00-0038661", first: "Chris", last: "Smith"),
      feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith")
    )

    assert_empty result.foreign_ids,
                 "detector one is BLIND here — the feed names 00-0038661 'Chris Smith' " \
                 "and so does the row, so the mapping check passes"

    finding = result.absorbed_namesakes.sole
    assert_equal "chris-smith-athlete", finding.athlete_slug
    assert_equal [["gsis_id", "00-0038661"]], finding.held_ids
    assert_equal "Chris Smith", finding.occupant_name
    assert_equal "Chris Smith", finding.other_name
    assert_equal "00-0031234", finding.other_gsis_id,
                 "when both humans share a name, the second is named by his ID"
  end

  test "a feed human with no turf row and no same-named row is not flagged" do
    athlete!("Alice", "Ant", gsis_id: "00-0010001")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"),
      feed_row(gsis_id: "00-0019999", first: "Zed", last: "Zulu")
    )

    assert_empty result.findings,
                 "a player who was simply never imported is not a merge"
  end

  # THE FEED SCOPE IS LOAD-BEARING IN BOTH DIRECTIONS, and getting it wrong is
  # silent either way — too wide floods the report, too narrow drops real merges.
  #
  # Scoped by SEASON, not by today's status. Measured against production
  # 2026-09-22: turf holds 2,896 athletes seeded in the preseason, of whom the
  # feed now calls only 1,731 ACT but 2,511 current-league. A status filter would
  # blind this detector to 40% of the rows it audits — and an absorbed human who
  # has since been CUT is precisely the case it must not drop.
  test "a CUT player still in the current league is in scope; a retired one is not" do
    athlete!("Chris", "Smith", gsis_id: "00-0038661")
    held = feed_row(gsis_id: "00-0038661", first: "Chris", last: "Smith")

    retired = audit(held, feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith",
                                   status: "RET", last_season: "2011"))
    assert_empty retired.findings, "a namesake who left the league years ago is not evidence"

    cut = audit(held, feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith",
                               status: "CUT", last_season: "2026"))
    assert_equal 1, cut.absorbed_namesakes.size,
                 "a current-league player is in scope whatever his status says today"
  end

  # ONE ATHLETE IS ONE FINDING. A merged row holds the absorbed human's whole
  # cross-reference set, so a per-column finding reports one row six times and
  # "findings: 6" reads as six damaged athletes. Measured against production: a
  # single flagged row produced five.
  test "a row whose whole ID set belongs to one other human is ONE finding" do
    athlete!("Cara", "Crane", gsis_id: "00-0010002", espn_id: "4000002",
             pff_id: 90002, otc_id: "otc-2", pfr_id: "DrakDa00", nflverse_id: "nfl-2")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Cara", last: "Crane", espn_id: "4000001"),
      feed_row(gsis_id: "00-0010002", first: "Dave", last: "Drake", espn_id: "4000002",
               pff_id: "90002", otc_id: "otc-2", pfr_id: "DrakDa00", nfl_id: "nfl-2")
    )

    finding = result.foreign_ids.sole
    assert_equal %w[gsis_id espn_id pff_id otc_id pfr_id nflverse_id].sort,
                 finding.held_columns.sort, "every foreign ID is listed on the one finding"
    assert_equal "Dave Drake", finding.other_name
  end

  # ...but two DIFFERENT other humans on one row stay two findings. Grouping on
  # the feed's gsis_id rather than its name is what keeps them apart, and a
  # name-grouped version would merge two humans back into one — the exact
  # confusion this audit reports.
  test "IDs belonging to two different humans produce two findings on one row" do
    athlete!("Cara", "Crane", gsis_id: "00-0010002", espn_id: "4000003")

    result = audit(
      feed_row(gsis_id: "00-0010002", first: "Dave", last: "Drake"),
      feed_row(gsis_id: "00-0010003", first: "Erin", last: "Egret", espn_id: "4000003")
    )

    assert_equal 2, result.foreign_ids.size
    assert_equal ["Dave Drake", "Erin Egret"], result.foreign_ids.map(&:other_name).sort
  end

  # A CANDIDATE AND AN EXPLAINED ABSENCE LOOK IDENTICAL WITHOUT THIS. The
  # importer ingests status=ACT only, so a DEV/RES/PUP/CUT human has no row
  # because it skipped him — that is not evidence of a merge. Measured against
  # production 2026-09-22: the sole candidate raised (anthony-johnson) is DEV,
  # and this field is what settled it without a database investigation.
  test "a candidate is marked unexplained only when the importer would have ingested him" do
    athlete!("Chris", "Smith", gsis_id: "00-0038661")
    held = feed_row(gsis_id: "00-0038661", first: "Chris", last: "Smith")

    skipped = audit(held, feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith",
                                   status: "DEV")).absorbed_namesakes.sole
    assert_equal "DEV", skipped.other_status
    assert_not skipped.missing_row_is_unexplained?,
               "the importer skips a non-ACT row, so his absence is already explained"

    lead = audit(held, feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith",
                                status: "ACT")).absorbed_namesakes.sole
    assert lead.missing_row_is_unexplained?,
           "an ACT human the importer should have created a row for is a real lead"
  end

  test "the report separates real leads from absences the importer explains" do
    athlete!("Chris", "Smith", gsis_id: "00-0038661")

    report = audit(
      feed_row(gsis_id: "00-0038661", first: "Chris", last: "Smith"),
      feed_row(gsis_id: "00-0031234", first: "Chris", last: "Smith", status: "DEV")
    ).to_report

    assert_match(/INVESTIGATE FIRST.*\(0\)/, report)
    assert_match(/absence already explained.*\(1\)/, report)
  end

  # ── Spelling variance must not be reported as a merge ───────────────────────
  # A false accusation costs a real investigation, and a genuine merge holds two
  # entirely different names rather than a suffix or a period.
  test "suffix, punctuation, nickname and alias differences are not merges" do
    athlete!("Will", "Anderson Jr.", gsis_id: "00-0010010")
    athlete!("T.J.", "Watt", gsis_id: "00-0010011")
    athlete!("Chig", "Okonkwo", gsis_id: "00-0010012")
    athlete!("Robert", "Griffin", aliases: ["RG Three"], gsis_id: "00-0010013")

    result = audit(
      feed_row(gsis_id: "00-0010010", first: "Will", last: "Anderson"),
      feed_row(gsis_id: "00-0010011", first: "TJ", last: "Watt"),
      feed_row(gsis_id: "00-0010012", first: "Chigoziem", common_first: "Chig", last: "Okonkwo"),
      feed_row(gsis_id: "00-0010013", first: "RG", last: "Three")
    )

    assert_empty result.findings, "spelling variance is not a merged human"
  end

  # ── Every cross-reference column the feed carries, not just gsis_id ─────────
  test "a foreign espn_id is caught on a row whose gsis_id is correct" do
    athlete!("Alice", "Ant", gsis_id: "00-0010001", espn_id: "4000002")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant", espn_id: "4000001"),
      feed_row(gsis_id: "00-0010002", first: "Bob", last: "Bee", espn_id: "4000002")
    )

    finding = result.foreign_ids.sole
    assert_equal ["espn_id"], finding.held_columns,
                 "the correct gsis_id is not flagged alongside the foreign espn_id"
    assert_equal "Bob Bee", finding.other_name
  end

  # ── What the audit declines to claim ────────────────────────────────────────
  test "an ID absent from the feed is counted as unverifiable, not accused" do
    athlete!("Alice", "Ant", gsis_id: "00-0099998")

    result = audit(feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"))

    assert_empty result.findings, "absent from the feed is not evidence of a merge"
    assert_operator result.unverifiable_ids, :>=, 1
  end

  # THE BOUNDARY THAT KEEPS DETECTOR TWO HONEST, and it fired wrongly before the
  # guard existed. Alice holds an ID the feed has never heard of, and the feed's
  # one Alice Ant is held by nobody — the bare conjunction matches, and the
  # finding printed "the feed's OTHER Alice Ant" when the feed holds a single
  # one. A row whose own identity is unverified cannot support a claim about a
  # second human, so it stays in the unverifiable count and nothing is alleged.
  test "a row whose own ID the feed cannot vouch for is not accused of a namesake merge" do
    athlete!("Alice", "Ant", gsis_id: "00-0099998")

    result = audit(feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"))

    assert_empty result.absorbed_namesakes,
                 "the feed holds one Alice Ant — there is no second human to name"
    assert_operator result.unverifiable_ids, :>=, 1
  end

  # The detectors PARTITION the findings rather than overlap: a row detector one
  # already flagged must not be reported a second time under another heading.
  test "a row flagged for a foreign ID is not also reported as an absorbed namesake" do
    athlete!("Cara", "Crane", gsis_id: "00-0010002")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Cara", last: "Crane"),
      feed_row(gsis_id: "00-0010002", first: "Dave", last: "Drake")
    )

    assert_equal 1, result.foreign_ids.size
    assert_empty result.absorbed_namesakes, "one problem is reported once"
  end

  test "an athlete carrying no checkable ID is counted as unidentified" do
    athlete!("Alice", "Ant")

    result = audit(feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"))

    assert_empty result.findings
    assert_operator result.unidentified_athletes, :>=, 1
  end

  test "a non-football athlete is not audited against the NFL feed" do
    athlete!("Sergio", "Soccer", sport: "soccer", gsis_id: "00-0010002")

    result = audit(
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"),
      feed_row(gsis_id: "00-0010002", first: "Bob", last: "Bee")
    )

    assert_empty result.foreign_ids
    assert_not_includes result.findings.map(&:person_slug), "sergio-soccer"
  end

  # ── The report is the deliverable, so its honesty is tested ─────────────────
  test "the report names both humans and states what it cannot see" do
    athlete!("Alice", "Ant", gsis_id: "00-0010002")

    report = audit(
      feed_row(gsis_id: "00-0010001", first: "Alice", last: "Ant"),
      feed_row(gsis_id: "00-0010002", first: "Bob", last: "Bee")
    ).to_report

    assert_match "Alice Ant", report
    assert_match "Bob Bee", report
    assert_match "READ-ONLY", report
    assert_match "WHAT THIS AUDIT CANNOT SEE", report
    assert_match "sleeper_id", report,
                 "the one stored ID column this feed cannot vouch for is named, not omitted"
  end
end
