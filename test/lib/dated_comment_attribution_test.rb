require "test_helper"
require "tmpdir"
require "fileutils"

# A WORKING FILE STATES THE CURRENT RULE, IN THE PRESENT TENSE.
#
# A comment in app/, lib/ or config/ says what the code does now, with at most
# one line of why and the task slug that decided it. Who decided it, and when,
# is history: it belongs in the task, the PR or git, not in a comment that goes
# on being read long after the decision moved on (turf-comments-present-tense).
#
# Two checks, over the comments only (code and rendered strings are not read):
#
#   1. NO DATED ATTRIBUTION. A person or role named beside a date —
#      "(Alex, 2026-10-05)", "(operator call, 2026-08-27)", "Avi review
#      2026-06-13" — fails, naming the line.
#   2. BARE DATES ONLY SHRINK. A date with no name ("measured 2026-09-10", a
#      protocol revision) can be a fact the code depends on, so it is not banned
#      outright; the count may not grow past BARE_DATE_CEILING. Lower the
#      ceiling when a pass removes some.
#
# WHAT COUNTS AS A COMMENT. Ruby, rake, rackup and YAML: the text after a `#`
# that opens a line or follows whitespace (not `#{`). JavaScript files: `//`
# comments and `/* */` blocks. ERB: `<%# %>` bodies and Ruby `#` lines inside
# code tags. JavaScript and HTML comments inside an ERB template are page bytes,
# not source notes, and are left to the page's own tests.
class DatedCommentAttributionTest < ActiveSupport::TestCase
  ROOTS = %w[app lib config].freeze
  EXTENSIONS = %w[.rb .rake .ru .yml .yaml .js .erb].freeze
  # CHANGELOG-style files record history by design.
  ALLOWED = [/(?:\A|\/)CHANGELOG[^\/]*\z/i].freeze

  WHO = /\b(?:Alex|operator|owner|Avi|Carl|Jasper|Steffon|Shannon|Xan)\b/i
  DATE = /\b20\d{2}-\d{2}(?:-\d{2})?\b/
  ATTRIBUTION = /#{WHO}[^\d]{0,25}?#{DATE}/
  BARE_DATE = /\b20\d{2}-\d{2}-\d{2}\b/
  BARE_DATE_CEILING = 291

  # [[line_number, comment_text], ...] for one file's source.
  def self.comments(path, src)
    ext = File.extname(path)
    lines = src.lines
    case ext
    when ".js" then js_comments(lines)
    when ".erb" then erb_comments(lines)
    else hash_comments(lines)
    end
  end

  def self.hash_comments(lines)
    lines.each_with_index.filter_map do |line, i|
      match = line.match(/(?:\A|\s)#(?!\{)(.*)$/)
      [i + 1, match[1]] if match
    end
  end

  def self.js_comments(lines)
    in_block = false
    lines.each_with_index.filter_map do |line, i|
      if in_block
        in_block = !line.include?("*/")
        next [i + 1, line]
      end
      if (open = line.index("/*"))
        in_block = !line[open..].include?("*/")
        next [i + 1, line[open..]]
      end
      match = line.match(%r{(?:\A|\s)//(.*)$})
      [i + 1, match[1]] if match
    end
  end

  def self.erb_comments(lines)
    in_comment = false
    lines.each_with_index.filter_map do |line, i|
      if in_comment
        in_comment = !line.include?("%>")
        next [i + 1, line]
      end
      if (open = line.index("<%#"))
        in_comment = !line[open..].include?("%>")
        next [i + 1, line[open..]]
      end
      match = line.match(/\A\s*#(?!\{)(.*)$/)
      [i + 1, match[1]] if match
    end
  end

  def self.scanned_files(root = Rails.root)
    ROOTS.flat_map { |dir| Dir.glob(File.join(root, dir, "**", "*")) }
         .select { |path| File.file?(path) && EXTENSIONS.include?(File.extname(path)) }
         .reject { |path| ALLOWED.any? { |rule| rule.match?(path) } }
         .sort
  end

  # Consecutive comment lines read as one passage, so an attribution that
  # wraps ("(Alex,\n# 2026-10-05)") is still one match. Yields each passage's
  # text and a lambda from a character offset back to its line number.
  def self.passages(comment_lines)
    comment_lines.slice_when { |(a, _), (b, _)| b != a + 1 }.map do |run|
      starts = []
      text = +""
      run.each do |number, line|
        starts << [text.length, number]
        text << line.strip << " "
      end
      line_at = ->(offset) { starts.reverse.find { |start, _| start <= offset }.last }
      [text, line_at]
    end
  end

  # { attributions: ["path:line: text", ...], bare_dates: Integer }
  def self.scan(root = Rails.root)
    attributions = []
    bare_dates = 0
    scanned_files(root).each do |path|
      rel = path.delete_prefix("#{root}/")
      passages(comments(rel, File.read(path))).each do |text, line_at|
        text.to_enum(:scan, ATTRIBUTION).each do
          match = Regexp.last_match
          attributions << "#{rel}:#{line_at.(match.begin(0))}: #{match[0]}"
        end
        bare_dates += text.scan(BARE_DATE).size
      end
    end
    { attributions: attributions, bare_dates: bare_dates }
  end

  test "no comment in app, lib or config names who decided something and when" do
    found = self.class.scan[:attributions]
    assert found.empty?, <<~MSG
      #{found.size} comment(s) carry a dated attribution. State the rule in the
      present tense (task slug where one exists) and leave who and when to git:
      #{found.join("\n")}
    MSG
  end

  test "bare dates in comments do not grow" do
    count = self.class.scan[:bare_dates]
    assert_operator count, :<=, BARE_DATE_CEILING, <<~MSG
      Comments in app, lib and config carry #{count} bare dates, over the ceiling of
      #{BARE_DATE_CEILING}. Say what the code does now instead of when it changed.
    MSG
  end

  test "the ceiling is tight, so a pass that removes dates also lowers it" do
    count = self.class.scan[:bare_dates]
    assert_equal BARE_DATE_CEILING, count,
                 "Bare dates fell to #{count}; lower BARE_DATE_CEILING to match."
  end

  # The guard bites: each shape it exists for fails on a fixture tree, and the
  # page-content and code shapes it must not read stay clean.
  test "a fixture tree with dated attributions fails, naming each line" do
    Dir.mktmpdir do |root|
      write = lambda do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
        File.write(File.join(root, rel), body)
      end
      write.("app/models/a.rb", "x = 1 # oldest first (Alex, 2026-10-05)\n")
      write.("app/views/b.html.erb", "<%# THE RULE (operator call,\n    2026-08-27): stays. %>\n<%# ok (Avi review 2026-06-13) %>\n")
      write.("app/javascript/c.js", "// RETRY ONCE (operator call, 2026-09-07).\n")
      write.("config/d.yml", "# measured 2026-09-10\nkey: value\n")
      # Not comments: a rendered string, inline page JS, and code.
      write.("app/views/e.html.erb", "<p>(Alex, 2026-10-05)</p>\n<script>\n  // (operator call, 2026-09-07)\n</script>\n")
      write.("app/models/f.rb", "LABEL = \"Alex 2026-10-05\"\n")
      write.("config/CHANGELOG.yml", "# (Alex, 2026-10-05)\n")

      result = self.class.scan(root)
      assert_equal %w[app/javascript/c.js:1 app/models/a.rb:1 app/views/b.html.erb:1 app/views/b.html.erb:3],
                   result[:attributions].map { |line| line.split(": ").first }
      assert_equal 5, result[:bare_dates]
    end
  end
end
