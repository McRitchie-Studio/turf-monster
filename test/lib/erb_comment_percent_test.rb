require "test_helper"

# AN ERB COMMENT MAY NOT QUOTE ERB.
#
# `<%# ... %>` ends at the FIRST close sequence anywhere in its body. Quote an
# ERB tag inside a comment and the comment TERMINATES ON IT — everything after
# renders into the page as visible text. It fails silently: the template parses,
# every existing test passes, and the leak shows up only to someone looking at a
# screen.
#
# docs/UI_PATTERNS.md "Alpine + ERB Constraints" rule 3 has said so for months.
# It happened anyway on 2026-08-24, in modals/_wallet_changed.html.erb: a comment
# explaining the card_header partial quoted that partial's own ERB, terminated on
# it, and dumped four sentences of explanation into the top of a modal the
# operator was looking at. A rule with no guard is a rule that gets rediscovered.
#
# WHY THIS SIGNATURE AND NOT THE DOC'S "ZERO PERCENT" WORDING. The first version
# of this test enforced the doc literally — no percent character in a comment
# body — and it DID NOT CATCH THE BUG IT WAS WRITTEN FOR. Mutation-checked: with
# `<%= yield %>` restored to the comment, the body scanned up to that point holds
# no percent at all, so the strict rule passed while the page leaked. Worse, it
# reddened on seven harmless prose percentages ("50% wide") that leak nothing.
# It caught the innocent and missed the guilty.
#
# The real precondition is an ERB OPEN inside the body: to terminate a comment by
# accident you must have written one. That is what this asserts, and the view
# tree carries zero of them today, so it needs no allowlist to stay honest.
class ErbCommentPercentTest < ActiveSupport::TestCase
  COMMENT = /<%#(.*?)%>/m
  ERB_OPEN = "<%"

  def quoting_comments
    Dir.glob(Rails.root.join("app/views/**/*.erb")).flat_map do |path|
      src = File.read(path)
      rel = path.delete_prefix("#{Rails.root}/")
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        next unless match[1].include?(ERB_OPEN)

        "#{rel}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  test "no ERB comment quotes an ERB tag" do
    assert_empty quoting_comments,
                 "these ERB comments contain an ERB open tag, so the comment TERMINATES on it and " \
                 "the rest of the prose renders into the page as visible text " \
                 "(docs/UI_PATTERNS.md, Alpine + ERB Constraints, rule 3). Describe the tag in " \
                 "words, or use an HTML comment:\n  #{quoting_comments.join("\n  ")}"
  end

  # Guard the guard. Without this the assertion above is a green light that can
  # never turn red — a matcher that stopped matching would read as a clean tree.
  test "the scan recognises an ERB tag quoted inside a comment" do
    sample = "<div>\n  <%# quoting <%= yield %> breaks this comment %>\n</div>"
    bodies = sample.scan(COMMENT).map(&:first)

    assert bodies.any? { |body| body.include?(ERB_OPEN) },
           "the matcher no longer sees the very thing it exists to catch"
  end
end
