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

  # ── WHAT THE ROLLBACK BUYS, held against the two IDLs ─────────────────────
  #
  # The doc's other load-bearing claim, and the one most likely to be read too
  # generously: the unset is a BOOT-level rollback, not a functional one. Anchor
  # account lists are positional, so a v0.25 wire is rejected by a v0.26 program
  # wherever the list differs — and it differs almost everywhere. The numbers in
  # the prose are derived here from the committed artifacts, so a future IDL that
  # changes them reddens instead of leaving the runbook overstating the retreat.

  def instruction_accounts(path)
    JSON.parse(File.read(path)).fetch("instructions")
        .to_h { |i| [i["name"], i.fetch("accounts").map { |a| a["name"] }] }
  end

  test "19 of the 20 shared instructions change account list, and the doc says so" do
    v25 = instruction_accounts(V25_PATH)
    v26 = instruction_accounts(V26_PATH)
    shared = v25.keys & v26.keys

    assert_equal 20, shared.length, "the shapes share 20 instructions"
    changed = shared.reject { |n| v25[n] == v26[n] }
    assert_equal 19, changed.length, "19 of the 20 have a different account list"
    assert_equal ["initialize"], (shared - changed), "only the one-time bootstrap survives unchanged"

    gained = shared.select { |n| v26[n].include?("governance") && !v25[n].include?("governance") }
    assert_equal 17, gained.length, "17 of them change by gaining the governance account"

    body = DOC.read
    assert_match(/20 instructions, and 19 of them have a different account list/, body)
    assert_match(/17\s*\n?\s*by gaining `governance`/m, body)
  end

  # The read side is the reason a rolled-back app LOOKS healthy, which is the
  # trap the prose names — and the mechanism is NOT the obvious one. Neither
  # changed account type grows: both SPEND TRAILING `_reserved` PADDING, so every
  # pre-existing field keeps its byte offset and a v0.25 decoder reads the new
  # field as padding it already ignores. That is a stronger property than
  # "appended", and it is the claim the prose now makes. This test was written
  # asserting the weaker one and reddened, which is how the doc got corrected.
  #
  # It is also the mechanism behind the step-4 warning. v0.25's VaultState has
  # THREE signer slots; v0.26's extra two live in `signers_ext`, a field the
  # deployed v0.25 binary does not have — which is exactly why a five-key
  # update_signers against it truncates rather than failing.
  SIZES = { "pubkey" => 32, "u8" => 1, "u16" => 2, "u32" => 4, "u64" => 8, "i64" => 8 }.freeze

  def byte_size(type)
    return SIZES.fetch(type) if type.is_a?(String)
    return byte_size(type["array"][0]) * type["array"][1] if type.is_a?(Hash) && type["array"]
    raise "no size for #{type.inspect}"
  end

  def typed_fields(path)
    JSON.parse(File.read(path)).fetch("types", [])
        .to_h { |t| [t["name"], (t.dig("type", "fields") || [])] }
  end

  test "the changed layouts spend reserved padding, so every old field keeps its offset" do
    f25 = typed_fields(V25_PATH)
    f26 = typed_fields(V26_PATH)
    names = JSON.parse(File.read(V25_PATH)).fetch("accounts").map { |a| a["name"] } &
            JSON.parse(File.read(V26_PATH)).fetch("accounts").map { |a| a["name"] }

    assert_equal 7, names.length, "seven account types are shared"
    changed = names.reject { |n| f25[n].map { |f| f["name"] } == f26[n].map { |f| f["name"] } }
    assert_equal %w[UserAccount VaultState], changed.sort,
                 "only these two changed; a third means the read-side claim needs re-deriving"

    changed.each do |n|
      old_f = f25[n]
      new_f = f26[n]
      assert_equal "_reserved", old_f.last["name"], "#{n} must end in padding for this argument to hold"
      assert_equal "_reserved", new_f.last["name"]

      # Every pre-existing field, padding aside, sits at the SAME index in the
      # same order — which for a flat Borsh struct is the same byte offset.
      old_body = old_f[0..-2]
      assert_equal old_body.map { |f| f["name"] }, new_f[0, old_body.length].map { |f| f["name"] },
                   "#{n}'s pre-existing fields must keep their positions"
      assert_equal old_body.map { |f| f["type"] }, new_f[0, old_body.length].map { |f| f["type"] },
                   "#{n}'s pre-existing fields must keep their types"

      # And the new fields are paid for out of the padding, byte for byte, so
      # the account's total size does not move.
      added = new_f[old_body.length..-2]
      refute_empty added, "#{n} is in the changed set, so it must have gained a field"
      spent = byte_size(old_f.last["type"]) - byte_size(new_f.last["type"])
      assert_equal added.sum { |f| byte_size(f["type"]) }, spent,
                   "#{n}'s new fields must be paid for out of _reserved, or the account grew"
    end

    # The concrete numbers, so a future change cannot quietly rebalance them.
    assert_equal 1, byte_size(f26["UserAccount"].find { |f| f["name"] == "username_registered" }["type"])
    assert_equal 64, byte_size(f26["VaultState"].find { |f| f["name"] == "signers_ext" }["type"])
    assert_equal 3, f26["VaultState"].find { |f| f["name"] == "signers" }["type"]["array"][1],
                 "the base signers array stays THREE — the extra two live in signers_ext"

    assert_match(%r{spend\s+trailing\s+`_reserved`\s+padding}mi, DOC.read,
                 "the prose must name the mechanism, not the weaker 'appended' claim")
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
