require "test_helper"
require "tmpdir"
require "fileutils"

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
# The precondition this DOES catch is an ERB OPEN inside the body: quoting a tag
# is the common way to terminate a comment by accident. That is what this
# asserts, and the view tree carries zero of them today, so it needs no allowlist.
#
# WHAT IT DOES NOT CATCH, stated because a guard that overstates its reach is
# worse than a narrow one. A reviewer proved the gap on 2026-08-25: a comment
# reading "...ends at the first close sequence, which is <the close sequence> and
# everything after..." carries NO ERB open, so this test stays GREEN while Rails
# renders the leaked prose into the page. That sentence is exactly what someone
# writes while DOCUMENTING this rule, which makes it a likely leak, not an exotic
# one.
#
# THAT GAP IS NOW CLOSED, and not by the widening this paragraph used to reject.
# Flagging all prose after a comment's close was measured and produced three false
# positives on legitimate inline script and attribute text, so it would have needed
# an allowlist — and an allowlisted guard is how a rule stops guarding. The
# signature that shipped instead is narrower: an ORPHAN close sequence between a
# comment's real close and the next ERB open. That orphan is the author's own
# second `%>`, the tell that one comment became two. Measured the same way before
# shipping: ZERO candidates across the whole view tree, so it carries no allowlist.
# See "THE SECOND SIGNATURE" below.
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

  # ---------------------------------------------------------------------------
  # THE SECOND SIGNATURE — the gap the header above used to declare unreachable.
  #
  # A comment that quotes ONLY THE CLOSE sequence carries no ERB open, so the
  # first assertion stays green while Rails renders the trailing prose. That is
  # the sentence someone writes while DOCUMENTING this very rule, which makes it
  # a likely leak rather than an exotic one.
  #
  # WHY THIS SIGNATURE AND NOT "PROSE AFTER A COMMENT". That widening was measured
  # against the view tree when this file was written and produced THREE false
  # positives on legitimate inline script and attribute text, so it would have
  # needed an allowlist — and an allowlisted guard is how a rule stops guarding.
  # This one is narrower and needs no allowlist: it fires only when an ORPHAN
  # close sequence sits between a comment's real close and the next ERB open.
  # That orphan is the author's own second `%>` — the tell that they wrote one
  # comment and the parser made two. Legitimate trailing text does not carry one.
  #
  # MEASURED before shipping, the same way the narrow rule was: this signature
  # returns ZERO candidates across the entire app/views tree today, so it needs
  # no allowlist and no exemption. If it ever fires, it has found something real.
  ORPHAN_CLOSE = "%>"

  def leaking_comments
    Dir.glob(Rails.root.join("app/views/**/*.erb")).flat_map do |path|
      src = File.read(path)
      rel = path.delete_prefix("#{Rails.root}/")
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        # Only the text between this comment's close and the NEXT ERB open can be
        # leaked prose; anything past that open belongs to another tag.
        next_open = rest.index(ERB_OPEN)
        segment = next_open ? rest[0...next_open] : rest
        next unless segment.include?(ORPHAN_CLOSE)

        "#{rel}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  test "no ERB comment terminates early and leaks its tail into the page" do
    assert_empty leaking_comments,
                 "these ERB comments quote a CLOSE sequence, so the comment ends there and the " \
                 "rest of the sentence renders into the page as visible text. No ERB open is " \
                 "involved, which is why the first assertion cannot see it. Rewrite the sentence " \
                 "without the literal close sequence, or use an HTML comment:\n  " +
                 leaking_comments.join("\n  ")
  end

  # Guard the second guard, for the same reason as the first.
  test "the scan recognises a comment that quotes only the close sequence" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/views/probe"))
      leak = File.join(dir, "app/views/probe/_leak.html.erb")
      # Exactly the reviewer's case: documenting the rule leaks the explanation.
      File.write(leak, "<div>\n  <%# a comment ends at the first close sequence, which is %> and everything after renders %>\n</div>\n")
      ok = File.join(dir, "app/views/probe/_ok.html.erb")
      File.write(ok, "<div>\n  <%# an ordinary comment %>\n  <p>50% wide</p>\n</div>\n")

      Rails.stub :root, Pathname.new(dir) do
        found = leaking_comments
        assert_equal ["app/views/probe/_leak.html.erb:2"], found,
                     "the second signature must catch the close-only leak and leave ordinary " \
                     "comments and prose percentages alone, got: #{found.inspect}"
      end
    end
  end
end
