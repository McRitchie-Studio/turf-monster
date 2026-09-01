# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# [unit] No JavaScript comment inside a turf-monster view's script block may carry an
# ERB sequence.
#
# WHY THIS REPO NEEDS ITS OWN COPY. studio-engine already guards this surface in
# test/views/script_comment_leak_test.rb. It cannot guard THIS app: the engine's
# test/ directory is not in the gemspec file list, so it does not ship with the
# gem and never sees a consumer's views. A guard that lives only in the engine
# reads as coverage from the outside while both consumers run unguarded, which is
# the same "green that means not-looked-at" this family of tests exists to end.
#
# PORTED, NOT REINVENTED. This is the engine file with the tree root repointed
# and the anti-vacuous floors re-measured for turf-monster — the walker, the leak
# rule and the probe tree are unchanged. /tasks/catch-third-comment-leak set that
# precedent for the sibling ERB-comment guard for a reason: patching one repo at a
# time grows three dialects of one rule, and the third dialect is where the next
# leak hides.
#
# THE MECHANISM, AND WHY IT IS WORSE THAN THE ERB-COMMENT ONE. A tag quoted inside
# an ERB comment is inert: the comment swallows it. A tag quoted inside a
# JAVASCRIPT comment is not inside anything as far as ERB is concerned — the JS
# comment is ordinary template text — so ERB opens a tag right there and RUNS it.
# A complete tag evaluates (a docstring silently calling code, or a NameError at
# render). An incomplete one swallows every byte up to the next close sequence
# anywhere later in the file, deleting working JavaScript with no syntax error to
# show for it. Wrapping the line in an HTML comment does not help: ERB runs inside
# those too.
#
# WHAT IT ASKS OF AUTHORS is what the ERB guard asks — describe the tag in words.
# Prose about the hazard stays legal; only the literal characters are refused. The
# ESCAPE form is refused with them, because it is not a way out: <%% renders a
# literal <% , so the escaped line emits a raw tag into this app's page output on
# every render, and that raw string is exactly what other guards in this ecosystem
# scan for.
#
# MEASURED BEFORE SHIPPING, on origin/accepted on 2026-09-01: 238 view files
# holding 76 script blocks, 2_339 JavaScript comments and 139_995 bytes of
# comment body that no guard in this repo read. The scan returned exactly ONE
# finding — layouts/application.html.erb, where a comment about the modal host
# ESCAPED the tag it was describing (<%% ... %>) instead of naming it in words.
# That line was correct ERB and the page worked, but it emitted a raw tag into
# every rendered page, so it was rewritten as prose in the same change. The
# guard therefore lands at ZERO with NO allowlist, which is the only way it is
# worth landing: an allowlisted guard is how a rule stops guarding.
#
# READING THE INPUT IS HALF THE JOB. A scan that finds nothing and a scan that
# read nothing look identical. The assertions below therefore check the INPUT —
# what the walker extracted, and how much of the tree it reached — not only the
# verdict.
class ScriptCommentLeakTest < ActiveSupport::TestCase
  ERB_OPEN = "<%"
  ERB_CLOSE = "%>"
  ERB_TAG = /<%.*?%>/m
  HTML_COMMENT = /<!--.*?-->/m
  SCRIPT_OPEN = /<script\b[^>]*>/i
  SCRIPT_CLOSE = %r{</script>}i
  QUOTES = ['"', "'", "`"].freeze

  # Anti-vacuous floors. Measured on origin/accepted on 2026-09-01: 76 script
  # blocks, 2_339 comments and 139_995 bytes of comment body over 238 view files.
  # Set at roughly 60% of each, so moving a program out to an asset file has room
  # while a walker that quietly stopped walking goes red.
  MIN_SCRIPT_BLOCKS = 45
  MIN_COMMENTS = 1_400
  MIN_COMMENT_BYTES = 83_000

  # A `/` opens a REGEX only where a value may begin. Everywhere else it divides.
  # Getting this wrong reads `/["']\/\//` as a comment and reports code as prose.
  #
  # No whitespace is listed here on purpose: regex_may_start? rstrips the tail
  # before examining it, so a trailing space or newline can never be the character
  # this list is asked about. The engine copy carries a newline entry that is
  # unreachable for that reason; it is not repeated here.
  TAIL_WINDOW = 16
  REGEX_MAY_FOLLOW_CHAR = "(,=:[!&|?{};+-*%~^<>".chars.freeze
  REGEX_MAY_FOLLOW_WORD = %w[
    return typeof instanceof in of new delete void case do else yield await
  ].freeze

  # Kinds that mean the walker could not read a span reliably. They are reported
  # as findings on purpose: an unreadable span is a blind spot, and a blind spot
  # that reports green is the whole failure this file exists to end.
  UNREADABLE = %i[unterminated_erb unterminated_block unterminated_literal].freeze

  def view_root = Rails.root.join("app/views")

  def views(root = view_root)
    Dir.glob(File.join(root, "**", "*.erb")).sort
  end

  def rel(path, root) = path.to_s.delete_prefix("#{root}/")

  # ---------------------------------------------------------------- anchoring

  # ERB tags and HTML comments blanked to spaces, LENGTH PRESERVED. Every offset
  # taken from this copy still indexes the original source, and newlines survive
  # so reported line numbers stay honest.
  def mask_non_markup(src)
    [ERB_TAG, HTML_COMMENT].reduce(src.dup) do |acc, pattern|
      acc.gsub(pattern) { |hit| hit.gsub(/[^\n]/, " ") }
    end
  end

  # Closing tags counted the SAME WAY the block finder anchors — on the masked
  # copy. The two must agree by construction, not by coincidence: this is the one
  # method both the invariant and its probe call, so a change here is visible to
  # the test that pins it.
  def script_closers(src) = mask_non_markup(src).scan(SCRIPT_CLOSE).length

  # [[inner_begin, inner_end], ...] as offsets into the ORIGINAL source.
  #
  # Anchoring on the masked copy is the point. Views name a script tag in PROSE —
  # inside an ERB comment, an HTML comment, a Ruby string, a JS comment — and on
  # raw source the first such mention opens a block that runs to the real
  # program's closing tag, handing the JavaScript walker a slab of markup.
  def script_blocks(src)
    masked = mask_non_markup(src)
    blocks = []
    pos = 0

    while (opener = SCRIPT_OPEN.match(masked, pos))
      close_at = masked.index(SCRIPT_CLOSE, opener.end(0))
      break if close_at.nil?

      blocks << [opener.end(0), close_at]
      pos = close_at + "</script>".length
    end

    blocks
  end

  # ---------------------------------------------------------------- the walker

  # One script block walked as JavaScript. Returns [[kind, body, offset], ...].
  #
  # The states that matter are the ones that can HIDE a comment opener — a string
  # ("https://example.com" is not a comment), a template literal, a regex. ERB
  # tags are opaque in CODE position, because an ERB tag's quotes and slashes are
  # Ruby, not JavaScript, and letting them steer this walk is how a walker loses
  # its place for the rest of a file. Inside a COMMENT they are the thing being
  # hunted, so there they are left exactly as written.
  def js_comments(js)
    found = []
    tail = +""
    index = 0
    length = js.length

    while index < length
      pair = js[index, 2]

      if pair == ERB_OPEN
        stop = js.index(ERB_CLOSE, index + 2)
        if stop.nil?
          found << [:unterminated_erb, js[index, 120], index]
          index += 2
        else
          index = stop + 2
        end
        tail = push_tail(tail, " ")
      elsif pair == "//"
        stop = js.index("\n", index) || length
        found << [:line, js[(index + 2)...stop], index]
        index = stop
      elsif pair == "/*"
        stop = js.index("*/", index + 2)
        if stop.nil?
          found << [:unterminated_block, js[(index + 2)..] || "", index]
          index = length
        else
          found << [:block, js[(index + 2)...stop], index]
          index = stop + 2
        end
      elsif QUOTES.include?(js[index])
        stop, closed = skip_literal(js, index)
        found << [:unterminated_literal, js[index, 120], index] unless closed
        index = stop
        tail = push_tail(tail, "x")
      elsif js[index] == "/" && regex_may_start?(tail)
        index = skip_regex(js, index)
        tail = push_tail(tail, "x")
      else
        tail = push_tail(tail, js[index])
        index += 1
      end
    end

    found
  end

  # Past a string or template literal, and whether it CLOSED.
  #
  # A quoted string resyncs at its own line end, so the worst a broken one costs
  # is the rest of that line. A template literal has no line end to resync on: one
  # that never closes swallows every comment after it for the rest of the block,
  # and reports a clean file. That is the exact shape of "a scan that read
  # nothing", so it is returned as unreadable rather than absorbed.
  #
  # ERB TAGS ARE NOT SKIPPED HERE, and that is a measured choice. Skipping them
  # changed nothing: the walker returned the identical 4_011 comments with and
  # without the branch across studio-engine, mcritchie-studio and turf-monster on
  # 2026-08-31, and zero literals ran away in any of them.
  #
  # The engine copy defends the omission by calling the branch unreachable —
  # reaching it would need "an odd number of one quote character, which is not
  # valid Ruby". THAT REASONING IS WRONG and is deliberately not repeated here. An
  # EVEN-quoted tag reaches it. Given
  #
  #     var s = "a <%= x("//and a %> here") %>";
  #
  # the JS string closes on the tag's own first quote, the walk resumes at
  # `//and a %> here` and reports a line comment carrying a close sequence — a
  # FALSE POSITIVE, reproduced before this file shipped.
  #
  # The branch stays out regardless, because the trade runs the right way: the
  # cost of omitting it is a loud failure on one line a human can rewrite, while
  # the cost of restoring it is a JavaScript walk steered by Ruby quoting, which
  # loses its place SILENTLY for the rest of a file. Zero occurrences of the shape
  # across all three repos. Do not restore the branch to "fix" a red line here —
  # rewrite the line.
  def skip_literal(js, start)
    quote = js[start]
    index = start + 1
    length = js.length

    while index < length
      if js[index] == "\\"
        index += 2
      elsif js[index] == quote
        return [index + 1, true]
      elsif js[index] == "\n" && quote != "`"
        return [index, true] # resynced at the line end, which bounds the damage
      else
        index += 1
      end
    end

    [length, false]
  end

  # Past a regex literal. A `/` inside a character class does not close it. If no
  # close arrives on the line it was not a regex, so step one character and let
  # the walk continue rather than swallowing the rest of the block.
  def skip_regex(js, start)
    index = start + 1
    length = js.length
    in_class = false

    while index < length
      char = js[index]
      if char == "\\"
        index += 2
      elsif char == "["
        in_class = true
        index += 1
      elsif char == "]"
        in_class = false
        index += 1
      elsif char == "/" && !in_class
        return index + 1
      elsif char == "\n"
        return start + 1
      else
        index += 1
      end
    end

    start + 1
  end

  def regex_may_start?(tail)
    trimmed = tail.rstrip
    return true if trimmed.empty?
    return true if REGEX_MAY_FOLLOW_CHAR.include?(trimmed[-1])

    REGEX_MAY_FOLLOW_WORD.include?(trimmed[/[A-Za-z_$][A-Za-z0-9_$]*\z/].to_s)
  end

  def push_tail(tail, char)
    grown = tail + char
    grown[-TAIL_WINDOW..] || grown
  end

  # ----------------------------------------------------------------- the scan

  # [[relative_path, line, kind, body], ...] for every JS comment in the tree.
  def script_comments(root = view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      script_blocks(src).flat_map do |from, to|
        js_comments(src[from...to]).map do |kind, body, offset|
          [rel(path, root), src[0...(from + offset)].count("\n") + 1, kind, body]
        end
      end
    end
  end

  def leaking_script_comments(root = view_root)
    script_comments(root).filter_map do |path, line, kind, body|
      next "#{path}:#{line}" if UNREADABLE.include?(kind)
      next unless body.include?(ERB_OPEN) || body.include?(ERB_CLOSE)

      "#{path}:#{line}"
    end.sort
  end

  # ------------------------------------------------------------- the verdict

  test "no script comment in a turf-monster view carries an ERB sequence" do
    found = leaking_script_comments

    assert_empty found,
                 "these JavaScript comments live inside a script block in a turf-monster view and " \
                 "carry an ERB open or close sequence. ERB does not know the line is a comment: " \
                 "a complete tag there is EXECUTED at render, and an incomplete one swallows the " \
                 "JavaScript after it up to the next close sequence in the file. An HTML comment " \
                 "does not help — ERB runs inside those too. The escape form is refused with " \
                 "them: it emits a raw tag into the page. Describe the tag in words:\n  " \
                 "#{found.join("\n  ")}"
  end

  # GUARD THE GUARD. Everything below asserts on what the walker READ, not only on
  # what it concluded, because a walker that stopped reading reports a clean tree.

  test "the scan actually reads this app's inline JavaScript" do
    blocks = views.sum { |path| script_blocks(File.read(path)).length }
    comments = script_comments
    bytes = comments.sum { |_path, _line, _kind, body| body.length }

    assert_operator blocks, :>=, MIN_SCRIPT_BLOCKS,
                    "only #{blocks} script block(s) found under #{view_root} — this guard is " \
                    "reading almost none of the JavaScript it exists to guard"
    assert_operator comments.length, :>=, MIN_COMMENTS,
                    "only #{comments.length} JavaScript comment(s) extracted — the walker is " \
                    "losing its place, not finding a clean tree"
    assert_operator bytes, :>=, MIN_COMMENT_BYTES,
                    "only #{bytes} bytes of comment body extracted — a walker that reads a " \
                    "fraction of the text reports green for the same reason an empty one does"
  end

  # The closer count is taken from the MASKED copy, because the block finder is.
  # Counting on RAW source instead — as the engine copy still does — means an ERB
  # or HTML comment that names a closing tag in PROSE is counted as a real one,
  # and this invariant reddens over a comment that broke nothing. That would
  # punish the exact habit the verdict above asks for: describe the hazard in
  # words. Latent rather than theoretical — zero occurrences in either consumer
  # today, and the probe below holds the line.
  test "every script block the scan finds is a real one" do
    mismatched = views.filter_map do |path|
      src = File.read(path)
      blocks = script_blocks(src).length
      closers = script_closers(src)
      next if blocks == closers

      "#{rel(path, view_root)}: #{blocks} block(s) opened for #{closers} closing tag(s)"
    end

    assert_empty mismatched,
                 "the block finder disagrees with the closing tags actually present. Too few " \
                 "means whole programs go unread; too many means markup is being walked as " \
                 "JavaScript:\n  #{mismatched.join("\n  ")}"
  end

  test "a closing tag named in prose does not break the block-count invariant" do
    src = "<%# never write </script> in prose %>\n<script>\n  var real = 1; // fine\n</script>\n"

    assert_equal 2, src.scan(SCRIPT_CLOSE).length,
                 "the probe must actually contain two closing sequences, or it proves nothing " \
                 "and this test is decoration"
    assert_equal 1, script_blocks(src).length
    assert_equal 1, script_closers(src),
                 "script_closers must count on the MASKED copy, as the block finder does. " \
                 "Counting on RAW source sees the prose mention, reports 1 block for 2 closers, " \
                 "and reddens this guard over a comment that broke nothing"
  end

  test "the walker returns comment bodies and nothing else" do
    js = <<~'JS'
      var url = "https://example.com/a"; // trailing note
      // a plain line
      /* a block
         over two lines */
      var slashes = /\/\//g;
      var tpl = `inline // not a comment`;
      var div = total / count / 2;
    JS

    assert_equal [
      " trailing note",
      " a plain line",
      " a block\n   over two lines "
    ], js_comments(js).map { |_kind, body, _offset| body },
                 "the walker must return every comment body and NO code. A double slash inside " \
                 "a URL, a regex or a template literal is not a comment, and reporting one as " \
                 "prose is how this scan would cry wolf on working code"
  end

  test "a literal that never closes is reported, not read past" do
    kinds = js_comments("var t = `never closed;\nvar u = 1; // unreachable\n")
            .map { |kind, _body, _offset| kind }

    assert_includes kinds, :unterminated_literal,
                    "a template literal with no closing backtick swallows every comment after " \
                    "it — there is no line end to resync on. Absorbing that in silence is a scan " \
                    "that read nothing while reporting a clean file"
    refute_includes kinds, :line,
                    "the comment IS swallowed, which is the point. What must not happen is the " \
                    "walker losing it without saying so"
  end

  test "an unterminated ERB open inside a script is reported, not skipped past" do
    kinds = js_comments("var a = 1; <%= never_closed\nvar b = 2;\n").map { |kind, _b, _o| kind }

    assert_includes kinds, :unterminated_erb,
                    "an ERB tag with no close swallows every byte after it up to the next close " \
                    "sequence in the FILE. Reading past it in silence is the blind spot"
  end

  test "the block finder is not anchored by a script tag named in prose" do
    with_probe_tree do |root|
      src = File.read(File.join(root, "probe/_ok_prose.html.erb"))
      blocks = script_blocks(src)

      assert_equal 1, blocks.size
      assert_equal "\n  var real = 1; // fine\n", src[blocks[0][0]...blocks[0][1]],
                   "the block anchored on the prose mention above the real program, so the ERB " \
                   "comment above it was walked as JavaScript"
    end
  end

  test "the scan catches every leak shape and leaves ordinary scripts alone" do
    with_probe_tree do |root|
      found = leaking_script_comments(root)

      assert_includes found.join, "_leak_line.html.erb",
                      "a line comment quoting an ERB tag is the shape this guard exists for"
      assert_includes found.join, "_leak_close_only.html.erb",
                      "a block comment quoting only a CLOSE sequence is the same defect, and the " \
                      "ERB guard is blind to it because no ERB comment is involved"
      assert_includes found.join, "_leak_open_only.html.erb",
                      "a body carrying only an OPEN is the worst of them: ERB starts a tag there " \
                      "and swallows JavaScript up to the next close sequence in the file"
      assert_includes found.join, "_leak_escaped.html.erb",
                      "the escape form renders a raw tag into this app's page. It is refused " \
                      "with the rest: describe the tag in words"
      assert_includes found.join, "_leak_unreadable.html.erb",
                      "a span the walker cannot read must be reported, not passed over. Silence " \
                      "there is the green-that-means-nothing this guard exists to end"
      assert_equal 5, found.size,
                   "an ordinary script was flagged. The next step would be an allowlist, and an " \
                   "allowlisted guard is how a rule stops guarding. Got: #{found.inspect}"
    end
  end

  test "a comment may still describe the hazard in words" do
    with_probe_tree do |root|
      refute_includes leaking_script_comments(root).join, "_ok_words.html.erb",
                      "a guard that bans discussing the problem makes the fix undocumentable"
    end
  end

  private

  def with_probe_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "probe"))

      # The leak shapes, separated by WHICH sequence the body carries. A probe that
      # happens to carry both still passes a rule that checks for only one of them,
      # and that is how a half-disabled rule reads as green.
      File.write(File.join(dir, "probe/_leak_line.html.erb"),
                 "<script>\n  // renders below the <%= yield %> call\n  var a = 1;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_close_only.html.erb"),
                 "<script>\n  /* the tag ends at its %> and the rest runs */\n  var b = 2;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_open_only.html.erb"),
                 "<script>\n  /* never write <% in one of these */\n  var c = 3;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_escaped.html.erb"),
                 "<script>\n  // see <%%= render \"studio/modals/host\" %> below\n</script>\n")
      # A span the walker cannot read is a blind spot, and a blind spot that reports
      # green is the failure this whole file exists to end. This body carries NO ERB
      # sequence, so only the unreadable-span rule catches it.
      File.write(File.join(dir, "probe/_leak_unreadable.html.erb"),
                 "<script>\n  /* a block comment that never closes\n  var d = 4;\n</script>\n")

      # Prose about the hazard, which must stay legal.
      File.write(File.join(dir, "probe/_ok_words.html.erb"),
                 "<script>\n  // an ERB comment ends at its first close marker, so a quoted tag\n" \
                 "  // truncates it and the tail renders as visible text.\n  var c = 3;\n</script>\n")

      # The literals that hide a comment opener. None of these is a comment.
      File.write(File.join(dir, "probe/_ok_literals.html.erb"),
                 "<script>\n  var u = \"https://example.com/<%= id %>\";\n" \
                 "  var r = /[\"']\\/\\//g;\n  var t = `a // b`;\n  var d = x / y / z;\n</script>\n")

      # The measured anchoring case: a script tag named in prose ABOVE the program.
      File.write(File.join(dir, "probe/_ok_prose.html.erb"),
                 "<%# ships at page level because a <script> inside the component never runs %>\n" \
                 "<!-- and an HTML comment naming <script> too -->\n" \
                 "<script>\n  var real = 1; // fine\n</script>\n")

      yield dir
    end
  end
end
