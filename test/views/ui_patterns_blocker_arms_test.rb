require "test_helper"

# THE BLOCKER SWITCH IS DESCRIBED IN PROSE, SO THE PROSE MUST BE DERIVED.
#
# docs/UI_PATTERNS.md § "The blocker switch navigates nowhere" states how many
# arms showEligibilityBlockerModal has, names each one, and says how many of
# them clear the hold button. Four facts about one switch, written by hand in a
# file the switch does not live in.
#
# WHY THIS EXISTS, precisely. On 2026-09-07 PR #596 (self-custody-entry-unguarded)
# added a SEVENTH arm - web3_step_up_required - to the switch in
# contests/_turf_totals_board. This PR's doc section, written against six, was
# base-merged over that change and AUTO-MERGED CLEAN: the two hunks never
# touched, git flagged nothing, CI was green, and the document silently began
# claiming a count that the source had already disproved. A reviewer reading
# both files by eye is what caught it.
#
# A count written by hand rots the moment someone adds an arm. A count DERIVED
# from the switch cannot. This test derives both sides and asserts they agree,
# so the next arm either updates this section or fails here by name.
#
# The list assertion is the load-bearing one: bumping the number without naming
# the new arm still fails, because the doc must ENUMERATE what the switch
# dispatches, not merely count it.
class UiPatternsBlockerArmsTest < ActiveSupport::TestCase
  BOARD = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")
  DOC   = Rails.root.join("docs/UI_PATTERNS.md")

  NUMBER_WORDS = {
    "four" => 4, "five" => 5, "six" => 6, "seven" => 7,
    "eight" => 8, "nine" => 9, "ten" => 10, "eleven" => 11, "twelve" => 12
  }.freeze

  # --- readers: the SOURCE side ---------------------------------------------

  # The switch body only, so a `case` elsewhere in this 1,500-line partial can
  # never be miscounted as a blocker arm.
  def switch_body
    body = BOARD.read[/showEligibilityBlockerModal\(blocker\)\s*\{(.*?)\n    \},/m, 1]
    assert body, "showEligibilityBlockerModal no longer parses out of #{BOARD.basename} — " \
                 "this guard reads that switch and can conclude nothing without it"
    body
  end

  # reason => handler method name, in source order.
  def source_arms
    switch_body.scan(/case\s+'([a-z0-9_]+)':\s*this\.([A-Za-z0-9_]+)\(/).to_h
  end

  def handler_body(name)
    body = BOARD.read[/^    #{Regexp.escape(name)}\((.*?)\n    \},/m, 1]
    assert body, "#{name}() no longer parses out of #{BOARD.basename} — the arm is dispatched " \
                 "to a method this guard cannot read, so it cannot say whether it clears the hold"
    body
  end

  # Arms whose handler calls resetHoldButtons(), derived rather than listed.
  def source_arms_clearing_hold
    source_arms.select { |_reason, handler| handler_body(handler).include?("resetHoldButtons") }.keys
  end

  # --- readers: the DOC side -------------------------------------------------

  def doc_section
    body = DOC.read[/### 2\. The blocker switch navigates nowhere(.*?)\n### /m, 1]
    assert body, "docs/UI_PATTERNS.md no longer contains the blocker-switch section this guard describes"
    body
  end

  # The bullets that enumerate the arms. `default` is the switch's default, not
  # an arm, so it is excluded here exactly as it is in the source count.
  def doc_arms
    doc_section.scan(/^- `([a-z0-9_]+)` → `[A-Za-z0-9_]+\(/).flatten - ["default"]
  end

  def doc_stated_total
    section = doc_section
    plus_default = section[/\*\*(\w+) arms plus a default/, 1]
    named        = section[/the (\w+) named arms each open a modal/, 1]
    assert plus_default, "the section no longer states an arm count in its '**N arms plus a default**' claim"
    assert named, "the section no longer states an arm count in its 'the N named arms' claim"
    assert_equal plus_default, named,
                 "the section states TWO different totals in one paragraph (#{plus_default} and #{named}) — " \
                 "a partial correction; fix both"
    NUMBER_WORDS.fetch(plus_default) { flunk "unmapped number word #{plus_default.inspect} in the arm count" }
  end

  def doc_stated_clearing
    pair = doc_section.match(/CLEARS it instead: (\w+) of the\s+(\w+) arms and the default call/)
    assert pair, "the section no longer states how many arms call resetHoldButtons()"
    [NUMBER_WORDS.fetch(pair[1]) { flunk "unmapped number word #{pair[1].inspect}" },
     NUMBER_WORDS.fetch(pair[2]) { flunk "unmapped number word #{pair[2].inspect}" }]
  end

  # --- anti-vacuity controls -------------------------------------------------
  #
  # Every assertion below compares two derived numbers. If either reader silently
  # returned nothing, the comparison could pass on two empty sets and this file
  # would report green on a switch it never read. These run first and prove the
  # scan reached real content.

  test "CONTROL: both files exist and the readers reach real content" do
    [BOARD, DOC].each do |path|
      assert path.exist?, "#{path} must exist for this guard to mean anything"
      assert_operator path.read.bytesize, :>, 2_000,
                      "#{path.basename} read back too little to be the real file"
    end
    assert_operator source_arms.size, :>=, 5,
                    "parsed #{source_arms.size} arms out of the switch — the reader is broken, not the switch"
    assert_operator doc_arms.size, :>=, 5,
                    "parsed #{doc_arms.size} arms out of the doc section — the reader is broken"
    assert_not_empty source_arms_clearing_hold
  end

  # --- the agreement guard ---------------------------------------------------

  test "the doc's stated arm COUNT matches the switch" do
    assert_equal source_arms.size, doc_stated_total,
                 "docs/UI_PATTERNS.md says showEligibilityBlockerModal has #{doc_stated_total} arms; " \
                 "the switch in #{BOARD.basename} has #{source_arms.size} " \
                 "(#{source_arms.keys.join(', ')}). An arm was added or removed without updating the doc."
  end

  test "the doc NAMES every arm the switch dispatches" do
    assert_equal source_arms.keys.sort, doc_arms.sort,
                 "the doc's arm list and the switch disagree. Missing from the doc: " \
                 "#{(source_arms.keys - doc_arms).inspect}; documented but not in the switch: " \
                 "#{(doc_arms - source_arms.keys).inspect}. Name the arm and where it routes — " \
                 "bumping the count alone is not documenting it."
  end

  test "the doc's resetHoldButtons arithmetic matches the switch" do
    stated_clearing, stated_total = doc_stated_clearing
    assert_equal source_arms.size, stated_total,
                 "the hold-button paragraph says '#{stated_total} arms' but the switch has #{source_arms.size}"
    assert_equal source_arms_clearing_hold.size, stated_clearing,
                 "the doc says #{stated_clearing} arms call resetHoldButtons(); #{source_arms_clearing_hold.size} do " \
                 "(#{source_arms_clearing_hold.join(', ')}). The arms that do NOT: " \
                 "#{(source_arms.keys - source_arms_clearing_hold).inspect}."
  end
end
