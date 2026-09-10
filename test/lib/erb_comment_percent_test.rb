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
# WHAT SIGNATURE 1 DOES NOT CATCH, stated because a guard that overstates its reach
# is worse than a narrow one. A reviewer proved the gap on 2026-08-25: a comment
# reading "...ends at the first close sequence, which is <the close sequence> and
# everything after..." carries NO ERB open, so this assertion stays GREEN while Rails
# renders the leaked prose into the page. That sentence is exactly what someone
# writes while DOCUMENTING this rule, which makes it a likely leak, not an exotic
# one. Signature 2 below is what catches it.
#
# THAT GAP IS NOW CLOSED, and not by the widening this paragraph used to reject.
# Flagging all prose after a comment's close was measured and produced three false
# positives on legitimate inline script and attribute text, so it would have needed
# an allowlist — and an allowlisted guard is how a rule stops guarding. The
# signature that shipped instead is narrower: an ORPHAN close sequence after a
# comment's real close. That orphan is the author's own second `%>`, the tell that
# one comment became two. See "THE SECOND SIGNATURE" below.
#
# A THIRD SHAPE walked through BOTH of those, and closing it is why this file was
# touched again on 2026-08-27. When the leaked tail itself REOPENS ERB before the
# author's second close, signature 1 sees no open inside the body (the body ended
# at the first close) and signature 2, which searched only up to the next ERB open,
# never reached the orphan behind it. Proven, not theorised:
#
#     <%# closed with %> like so, see <%= 1 %> and the rest %>
#
# renders " like so, see 1 and the rest %>" into the page while both assertions stay
# green. The fix is one step: signature 2 now STEPS OVER complete ERB tags instead of
# stopping at the first one. Measured before landing, the same way as the other two —
# ZERO candidates across all three enrolled repos at origin/accepted (turf 225 view
# files, hub 214, engine 164), so the widening carries no allowlist and no exemption.
#
# WHAT IT STILL DOES NOT CATCH, stated because a guard that overstates its reach is
# worse than a narrow one: a comment whose tail carries NO second close sequence at
# all — `<%# a note %> and then some prose` with no `%>` after it. That prose really
# does render, but it is textually indistinguishable from the ordinary markup that
# follows almost every comment in the tree, which is the measurement that killed the
# broad widening twice. Catching it needs an allowlist, and an allowlisted guard is
# how a rule stops guarding.
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

  # SIGNATURE 2, WIDENED. Walk forward from a comment's real close, STEPPING OVER
  # complete ERB tags, and report the first close sequence that has no open of its
  # own. That orphan is the author's second `%>` — the tell that one comment became
  # two. Legitimate trailing markup never carries one.
  #
  # THE STEP-OVER IS THE WHOLE FIX. The first version stopped at the next ERB open
  # and only searched the text before it, which a THIRD leak shape walks straight
  # through: when the leaked tail itself REOPENS ERB before the author's second
  # close, that tag's open arrives first, so the orphan is never reached and both
  # shipped signatures stay green while the prose renders. Proven, not theorised —
  # `<%# closed with %> like so, see <%= 1 %> and the rest %>` renders
  # " like so, see 1 and the rest %>" into the page.
  def orphan_close_after?(rest)
    pos = 0
    loop do
      open_at = rest.index(ERB_OPEN, pos)
      close_at = rest.index(ORPHAN_CLOSE, pos)
      return false if close_at.nil?
      return true if open_at.nil? || close_at < open_at

      # A COMPLETE tag stands between here and any orphan: skip past its own close
      # and keep looking. Stopping here is exactly the third shape's escape route.
      tag_close = rest.index(ORPHAN_CLOSE, open_at + ERB_OPEN.length)
      return false if tag_close.nil?

      pos = tag_close + ORPHAN_CLOSE.length
    end
  end

  def leaking_comments
    Dir.glob(Rails.root.join("app/views/**/*.erb")).flat_map do |path|
      src = File.read(path)
      rel = path.delete_prefix("#{Rails.root}/")
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        next unless orphan_close_after?(rest)

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

  # Guard the WIDENING, which is the only reason this file changed. The third shape
  # is the one BOTH shipped signatures walked through, so a matcher that quietly
  # narrowed back would read as a clean tree — the exact failure the two guard-the-
  # guard tests above exist to prevent, one shape later.
  #
  # All three leak shapes are planted together, on purpose: the widening must catch
  # the new one WITHOUT losing either of the two it inherited.
  test "the scan catches all three leak shapes and leaves ordinary views alone" do
    Dir.mktmpdir do |dir|
      views = File.join(dir, "app/views/probe")
      FileUtils.mkdir_p(views)
      write = ->(name, body) { File.write(File.join(views, name), body) }

      write.call("_shape1.html.erb", "<div>\n  <%# quoting <%= yield %> breaks this comment %>\n</div>\n")
      write.call("_shape2.html.erb", "<div>\n  <%# ends at the first close, which is %> and everything after renders %>\n</div>\n")
      # SHAPE 3 — the tail REOPENS ERB before the author's second close, so the
      # orphan is not the first thing after the comment and the narrow scan stopped
      # short of it. Rails renders " like so, see 1 and the rest %>" into the page.
      write.call("_shape3.html.erb", "<div>\n  <%# closed with %> like so, see <%= 1 %> and the rest %>\n</div>\n")

      # The three legitimate shapes that must stay quiet — a bare comment, a comment
      # followed by a real tag, and prose percentages. An allowlisted guard is how a
      # rule stops guarding, so these carry the whole cost of the widening.
      write.call("_ok_plain.html.erb", "<div>\n  <%# an ordinary comment %>\n  <p>50% wide</p>\n</div>\n")
      write.call("_ok_tag.html.erb", "<div>\n  <%# describes the next line %>\n  <%= render \"x\" %>\n  <p>done</p>\n</div>\n")
      write.call("_ok_many.html.erb", "<div>\n  <%# note %>\n  <span><%= a %></span>\n  <span><%= b %></span>\n</div>\n")

      Rails.stub :root, Pathname.new(dir) do
        found = leaking_comments

        assert_includes found, "app/views/probe/_shape3.html.erb:2",
                        "the third shape is the one this widening exists for: the leaked tail " \
                        "reopens ERB, so the author's orphan close is never the first thing after " \
                        "the comment and the narrow scan stopped short of it"
        assert_includes found, "app/views/probe/_shape2.html.erb:2",
                        "the widening must not lose the close-only shape it inherited"
        assert_includes found, "app/views/probe/_shape1.html.erb:2",
                        "a quoted ERB open leaves an orphan too, and this scan must still see it"
        assert_equal 3, found.size,
                     "the widening flagged an ordinary view — an allowlist would be the next step, " \
                     "and an allowlisted guard is how a rule stops guarding. Got: #{found.inspect}"
      end
    end
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
