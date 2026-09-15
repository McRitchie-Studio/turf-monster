# frozen_string_literal: true

require "test_helper"

# [docs-guard] docs/SOLANA.md's rollback claim, held against the guard that
# decides it.
#
# THE DEFECT THIS EXISTS FOR. The v0.26 changeover was chosen over a paused
# deploy window on ONE argument: the retreat is a config var and a restart,
# not a second Squads ceremony. The runbook then told the operator to tighten
# `EXPECTED_IDL_HASH` to the v0.26 hash alone as step 4 of that same ceremony,
# and called steps 3-4 "freely reversible". Measured: they are not. The switch
# selects the IDL FILE and the allow-list then judges whatever file the switch
# selected, so a pin naming only v0.26 refuses the v0.25 file that
# `heroku config:unset SOLANA_VAULT_GOVERNANCE` selects — `IdlMismatchError`,
# release phase and every web dyno refusing to boot. The deliverable's central
# claim failed in the state its own runbook produced.
#
# WHY THE TEST IS HERE AND NOT IN test/services. The thing under test is a
# DOCUMENT: the table docs/SOLANA.md prints for a ceremony-day operator. Every
# row of it is re-derived here from the real guard and the real committed IDL
# files and compared against what the doc SAYS, so a row that stops being true
# reddens here rather than on a dyno at 2am.
#
# WHAT IS REAL AND WHAT IS SUBSTITUTED. `Solana::Config::GOVERNANCE` and
# `IDL_PATH` are frozen at class load from ENV, so this build can only ever BE
# one row (switch off, v0.25 file). For that row — which is the rollback, the
# one the defect is about — `verify_idl!` is called for real, end to end,
# with only the operator-set PIN substituted. The switch-on rows cannot be
# reached without re-booting the app, so they are derived through the same
# comparison primitive the guard itself uses (`expected_idl_hashes`), against
# the real SHA256 of the real file. Nothing here stubs the hash.
class GovernanceRollbackPinTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/SOLANA.md")

  # The two artifacts the switch chooses between, on whatever cluster this
  # build is configured for. Derived the way Solana::Config::IDL_PATH derives
  # them, so a change to that rule reddens here instead of being mirrored.
  BASE = Solana::Config::NETWORK == "mainnet-beta" ? "turf_vault.mainnet" : "turf_vault"
  V25_PATH = Rails.root.join("config", "#{BASE}.idl.json")
  V26_PATH = Rails.root.join("config", "#{BASE}.v026.idl.json")

  def sha(path) = Digest::SHA256.hexdigest(File.read(path))

  # ── the selection rule the whole table rests on ───────────────────────────

  test "the switch is what selects the file, and the two files are the two shapes" do
    assert File.exist?(V25_PATH), "the v0.25 artifact the rollback selects must be committed"
    assert File.exist?(V26_PATH), "the v0.26 artifact the ceremony selects must be committed"

    # This build is the OFF row, so IDL_PATH must be the v0.25 artifact. If the
    # merge-time default ever flips, the rollback row below stops being the
    # row this build can execute and the whole file needs re-reading.
    refute Solana::Config.governance?, "this build must ship resolved to v0.25"
    assert_equal V25_PATH.to_s, Solana::Config::IDL_PATH.to_s

    # Structural, not a version string: turf-vault shipped v0.26 with Cargo
    # version 0.25.0, so metadata.version cannot tell these apart.
    names = ->(p) { JSON.parse(File.read(p)).fetch("instructions").map { |i| i["name"] } }
    refute_includes names.call(V25_PATH), "init_governance"
    assert_includes names.call(V26_PATH), "init_governance"
    refute_equal sha(V25_PATH), sha(V26_PATH), "two shapes, two hashes — or the pin cannot discriminate at all"
  end

  # ── THE DEFECT, exercised against the real guard ──────────────────────────
  #
  # Only the pin is substituted. IDL_PATH, the file on disk, the SHA256, the
  # shape guard and the raise are all the production ones.

  test "the tightened pin refuses the boot the rollback produces" do
    Solana::Config.stub(:expected_idl_hashes, [sha(V26_PATH)]) do
      error = assert_raises(Solana::Config::IdlMismatchError) { Solana::Config.verify_idl! }
      assert_match(/refusing to boot/, error.message)
      assert_match(/#{Regexp.escape(sha(V25_PATH))}/, error.message,
                   "the message must name the hash it got, which is the rolled-back file's")
    end
  end

  # The control, and the fix. Same call, same file, same guard — only the pin
  # differs, so a green here is attributable to the pin and nothing else.
  test "the widened pin boots the same rollback state" do
    Solana::Config.stub(:expected_idl_hashes, [sha(V25_PATH), sha(V26_PATH)]) do
      assert_nil Solana::Config.verify_idl!
    end
  end

  # The shape guard is NOT what fails in either case, and must not be softened
  # to make the rollback work: in both rows above the switch and the selected
  # file agree with each other, so verify_governance_alignment! is satisfied
  # and the hash allow-list is the only thing deciding.
  test "the shape guard is satisfied in the rollback state, so only the pin decides" do
    assert_nil Solana::Config.verify_governance_alignment!
    assert_equal Solana::Config.governance?, Solana::Config.idl_declares_governance?
  end

  # ── every row of the DOC's table, re-derived ──────────────────────────────

  ROW = /^\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|\s*(v0\.2[56]) IDL\s*\|\s*(.+?)\s*\|$/

  def table_rows
    DOC.read.lines.filter_map { |l| l.match(ROW) }.map do |m|
      {
        pin: m[1].scan(/v0\.2[56]/),
        switch: m[2].delete("`").strip,
        selected: m[3],
        refuses: m[4].include?("IdlMismatchError"),
        raw: m[0].strip
      }
    end
  end

  # THE FLOOR. A regex that stops matching would assert nothing and stay green,
  # which is the failure mode this whole class of guard is prone to. The table
  # is five rows and must parse as five, in both verdicts.
  test "the table parses, and parses to both verdicts" do
    rows = table_rows
    assert_equal 5, rows.length, "docs/SOLANA.md's pin table must parse to its five rows"
    assert_equal 3, rows.count { |r| !r[:refuses] }, "three rows must boot"
    assert_equal 2, rows.count { |r| r[:refuses] }, "two rows must refuse"
  end

  test "every row the doc prints is what the guard's own comparison yields" do
    hashes = { "v0.25" => sha(V25_PATH), "v0.26" => sha(V26_PATH) }

    table_rows.each do |row|
      # The switch and the selected file must agree — that is the selection
      # rule, and a row that violated it would be describing a state the shape
      # guard refuses for a different reason entirely.
      expected_shape = row[:switch] == "on" ? "v0.26" : "v0.25"
      assert_equal expected_shape, row[:selected],
                   "row contradicts the selection rule: #{row[:raw]}"

      pinned = row[:pin].map { |v| hashes.fetch(v) }
      # expected_idl_hashes is the production parser, handed the pin string an
      # operator would paste; include? is verbatim what idl_hash_acceptable? does.
      accepted = Solana::Config.expected_idl_hashes(pinned.join(","))
      boots = accepted.include?(hashes.fetch(row[:selected]))

      assert_equal !row[:refuses], boots,
                   "the doc and the guard disagree about: #{row[:raw]}"
    end
  end

  # ── the prose the defect was, in the end, about ───────────────────────────

  test "the ceremony list does not contain the tighten" do
    section = DOC.read[/#### Upgrade ordering — UNFORGIVING\n(.*?)\n#### /m, 1]
    assert section, "the ordering section must exist to be checked"

    steps = section.lines.grep(/^\d+\. /)
    assert_operator steps.length, :>=, 4, "the ceremony must still be a numbered list"
    refute steps.any? { |s| s.match?(/tighten/i) },
           "tightening forfeits the one-command rollback, so it is not a ceremony step"
  end

  test "the doc says plainly that tightening forfeits the rollback" do
    body = DOC.read
    assert_match(/Tightening `EXPECTED_IDL_HASH`.{0,80}forfeits the\n?\s*one-command rollback/m, body,
                 "the forfeit must be stated, not implied")
    refute_match(/steps 3-4 as\s*\n?\s*freely reversible/m, body,
                 "the claim this task was filed to remove")
  end
end
