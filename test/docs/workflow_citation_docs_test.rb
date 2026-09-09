# frozen_string_literal: true

require "test_helper"
require "prism"

# A `path/to/file.rb:NN` CITATION IS A CLAIM ABOUT RUNNING CODE, and until this
# test existed nothing checked it. docs/workflows/web3-landing-to-entry.md opens
# with "Code is law. Every claim below cites path/to/file.rb:NN from the current
# codebase" — a promise that a reader can follow any number in it straight to the
# thing it names. Nothing enforced that promise, so every refactor quietly spent
# it, and the numbers rotted at the speed the app moved.
#
# MEASURED BY THIS FILE, 2026-09-08, against the document as it then stood: 113
# citations, of which 14 landed on the code they named. The other 99 break down
# as 54 landing inside a DIFFERENT method than the prose names, 30 landing in
# code with no enclosing method and quoting nothing found there, 6 pointing past
# the end of their file, 2 naming files that had GRADUATED TO THE studio-engine
# GEM and no longer existed in this repo, and 7 written in a `Symbol#method:NN`
# form that resolves to no file at all. Worked examples:
# `Entry#confirm_onchain!` was cited at entry.rb:130 — that line is inside
# `assert_enterable!`, and the method had moved to :242 — and
# `ContestsController#confirm_onchain_entry` at :568, which is `def world_cup`;
# the action had moved to :1284.
#
# WHY THE DRIFT IS WORSE THAN A MISSING CITATION. A wrong number does not read as
# wrong. It reads as freshly verified — someone went and looked — so a reader
# lands on unrelated code and concludes the DOC is describing something subtle
# rather than that the number is stale. That is also why the sweep it guards was
# all-or-nothing: correcting one citation inside a bullet whose siblings are also
# stale produces a bullet that reads verified and is not.
#
# WHY THIS IS NOT A "DOES LINE NN EXIST" CHECK. Every stale citation above was
# in-bounds. contests_controller.rb is 2739 lines; :568 exists, it just is not
# `confirm_onchain_entry`. A bounds check passes on all 113 and proves nothing.
# So THE SYMBOL IS THE CLAIM AND THE NUMBER IS BOOKKEEPING, and this guard is
# keyed on the symbol:
#
#   * for a .rb file, the enclosing definition of the cited line is derived with
#     Prism (the parser Ruby itself ships), not with a `def` regex;
#   * for an .erb file, the inline-JS factory members are located by brace
#     balance — `_turf_totals_board.html.erb` defines `selectionBoard()` inline
#     because Alpine processes x-data before importmap modules load, so its
#     methods are ERB text and no Ruby parser sees them;
#   * where the cited lines sit inside a definition, the prose MUST name that
#     definition — nothing else will do;
#   * only where there is no enclosing definition (a routes.rb entry, ERB markup,
#     a JSON block, a callback declaration in a class body) does it fall back to
#     asking that a code token the prose quotes appear in the cited lines.
#
# Move a method and the number under it stops matching the symbol beside it, so
# the citation reddens HERE rather than misleading a reader six months on.
#
# THE FLOOR IS PART OF THE GUARD, not decoration. A sweep whose regex stops
# matching passes having proved nothing, which is the failure mode this whole
# class of test is prone to: rename the citation style, match zero, assert
# nothing, stay green. So the parse is asserted to find at least each guarded
# document's own `min_citations` in COVERAGE, and to find both citation SHAPES
# that document uses. Deleting citations below a floor is a deliberate act that
# has to move a number in this file.
#
# ITS LIMITS, STATED PLAINLY.
#
#   1. IT GUARDS TWO DOCUMENTS OF NINE. COVERAGE below is the whole list, and
#      docs/workflows/ holds 323 more citations that are NOT checked here —
#      measured 2026-09-09 by this file's own parser: admin-contest-setup 122,
#      email-signup-token-to-chat 98, referral-google-tokens-to-chat 55,
#      slate-build 48. Do not read this file as covering the directory.
#      WORSE THAN UNCHECKED, TWO DOCUMENTS ARE UNCITED. live-scoring.md and
#      submit-entry-decision-tree.md parse to ZERO citations each, in a directory
#      whose _TEMPLATE.md says to "Cite file:line for EVERY step". They name
#      symbols throughout — Nfl::LiveScores::PollCycle, Live::FocusGame,
#      ContestsController#prepare_entry — and point at none of them. A FLOOR
#      CANNOT REACH THAT. Every check here starts from a parsed citation, so a
#      document with no citations is not weakly guarded, it is invisible: adding
#      it to COVERAGE with a floor of 0 would be a coverage claim backed by
#      nothing. Those two need citing first, then guarding. Until they are, the
#      directory README names them as uncited rather than describing every
#      per-workflow file as line-cited, which is what it used to do.
#   2. IT CANNOT CHECK PROSE. It proves a citation lands on the symbol the prose
#      names. It cannot prove the sentence about that symbol is true, and the
#      same sweep found sentences that were: the document described a client-side
#      broadcast (`connection.sendRawTransaction`) and a `stamp_entry_signature`
#      round trip that the code had stopped doing. Nothing mechanical catches
#      that — only reading the code does.
#   3. THE LITERAL FALLBACK CAN ANCHOR ON A COMMENT. Where a citation has no
#      enclosing definition, it passes if a prose token appears anywhere in the
#      cited lines — including inside a comment that merely MENTIONS the symbol.
#      Measured 2026-09-09: after `accepted` moved, the `provider.signMessage`
#      citation at application.html.erb:450-452 landed on a comment reading
#      "drops into connect() + signMessage() below" and stayed GREEN while being
#      stale. This is not stripped, because the document cites comments
#      DELIBERATELY in six places — a route that moved to the engine, an endpoint
#      no client calls any more — and two of those say so outright. So the
#      literal branch is a weaker claim than the symbol branch by construction:
#      it proves the words are there, not that the code is.
#   4. CROSS-REPO REFERENCES CARRY NO LINE NUMBER, on purpose. studio-engine is
#      a versioned gem (`~> 0.72`), so a line number in it would rot on an
#      unrelated `bundle update` and redden this test for a change nobody made
#      here. Those citations name the file and the symbol, and are checked
#      against the RESOLVED gem — the symbol survives the bump, the number would
#      not.
#   5. THE SYMBOL BRANCH DOES NOT COVER EVERY CITATION, and the gap is not
#      random. Measured 2026-09-09, per document. web3-landing-to-entry: 164
#      citations, 131 on the symbol branch, 33 on the literal fallback — and ALL
#      SEVEN citations on `app/views/layouts/application.html.erb`, the whole
#      Phantom connect-and-sign surface, are in that 33. The cause is mechanical,
#      not editorial: JS_DEF below requires `function name(...) {`, and that file
#      writes `window.solanaConnectAndVerify = async function(walletName, opts)`,
#      so no line in its ~400-line body has an enclosing definition to anchor on.
#      market-snapshot: 55 citations, 36 on the symbol branch, 19 on the
#      fallback, and there the concentration is by FILE EXTENSION —
#      `definitions` below reads `.rb` with Prism and inline JS inside `.erb`,
#      and returns nothing for anything else. So every citation on `.rake` and
#      `.js` is on the weaker branch BY CONSTRUCTION, never by an editor's
#      choice, and in that document those two extensions plus a seed script with
#      no `def` and one constant in a class body are exactly the 19.
#      A reader following a security claim is the reader most likely to land on
#      the weak branch, and there the guard proves the words are present, not
#      that the code is. Each guarded document's preamble says so, and
#      "the preamble states the split ..." below holds it to those numbers.
#   6. A WIDE SYMBOL MAKES THE SYMBOL BRANCH NEARLY AS WEAK AS THE FALLBACK. The
#      symbol branch asks only that the cited line fall SOMEWHERE inside the
#      named definition. `confirmEntry()` spans 410 lines and 11 citations land
#      in it, so any of those numbers could be a hundred lines off and still
#      anchor. That is how `:201` cited `_turf_totals_board.html.erb:1621` — a
#      BLANK line, three past the `useOnchainFlow` branch it names at :1618 — and
#      passed. This is NOT fixed by tightening the anchor: a citation
#      legitimately points into a long function, and demanding a tighter match
#      would redden honest ones. What IS fixed is the degenerate case — a
#      citation whose cited lines are entirely blank is now rejected outright, at
#      0 false positives across all 164. The rest of the weakness stands stated.
class WorkflowCitationDocsTest < ActiveSupport::TestCase
  # COVERAGE IS PER DOCUMENT, AND THAT IS THE POINT. A second document guarded
  # under one shared floor would be covered in name only: web3-landing-to-entry's
  # 164 citations satisfy any total this file could reasonably assert, so a
  # combined floor would stay green with the second document's citations deleted
  # entirely. A floor implying reach the guard does not have is the same defect
  # as a citation implying a check it does not get. So each guarded document
  # carries its OWN floors and its OWN preamble claim, and adding one means
  # measuring that document, not appending a path.
  #
  #   min_citations / min_path / min_bare
  #     Floors for the parse, each set below the count that document's sweep left
  #     behind — low enough that ordinary editing does not trip them, high enough
  #     that a citation style change matching nothing cannot slip through green.
  #     min_bare is per document because the two do not write citations alike:
  #     web3-landing-to-entry leans on bare `:NN` (98 of 164), market-snapshot
  #     re-states the path far more often (17 of 55).
  #
  #   fallback_only_files
  #     Files on which EVERY citation in that document rides the weaker literal
  #     branch. The document names them to its reader; this list is what holds it
  #     to that claim, so if such a file ever grows a definition the guard can
  #     see, the preamble goes stale LOUDLY rather than quietly understating.
  #     It is a claim about the files it NAMES, not an exhaustive list of every
  #     fallback-only file in the document — the split counts above carry the
  #     exhaustive part.
  COVERAGE = {
    "docs/workflows/web3-landing-to-entry.md" => {
      min_citations: 120, min_path: 45, min_bare: 70,
      fallback_only_files: %w[app/views/layouts/application.html.erb]
    },
    "docs/workflows/market-snapshot.md" => {
      min_citations: 45, min_path: 30, min_bare: 12,
      fallback_only_files: %w[
        lib/tasks/nfl.rake
        lib/tasks/market.rake
        db/seeds/nfl_2026.rb
        scripts/scrape_draftkings.js
        app/services/nfl/espn/client.rb
      ]
    }
  }.freeze

  GUARDED_DOCS = COVERAGE.keys.freeze

  # Tokens too common to anchor anything. A citation that only matches one of
  # these has not been verified by the literal branch.
  STOP_TOKENS = %w[
    true false nil null return raise status error success entry entries user users
    contest contests session cookies params render json post get put patch delete
    active cart admin slug name value data config script async await function var
  ].freeze

  MIN_LITERAL_TOKEN = 6

  # A real repo file used as the CONTROL for the blank-line rejection below. It
  # needs only two properties — it exists, and it holds both a blank line and a
  # non-blank one — and the control locates them at run time, so it cannot go
  # stale. Which file it is carries no other meaning; the per-document claim
  # about fallback-only files lives in COVERAGE above.
  BLANK_CONTROL_FILE = "app/views/layouts/application.html.erb"

  # A citation: `path/to/file.rb:12`, `file.rb:12-18`, `:12`, `:12, 20-24`.
  LINES  = /\d+(?:-\d+)?(?:,\s*\d+(?:-\d+)?)*/
  CITE   = /`([^`]*?):(#{LINES})`/
  # A cross-repo reference: `studio-engine: app/models/session_context.rb`.
  ENGINE = /`studio-engine:\s*([\w.\/-]+\.rb)`/
  TOKEN  = /`([^`]+)`/

  # ---------------------------------------------------------------- the tests

  test "every cited file exists in this repo" do
    missing = citations.reject { |c| c[:path] && File.exist?(abs(c[:path])) }
    assert_empty missing.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]} -> #{c[:path] || 'UNRESOLVED FILE CONTEXT'}" },
                 "citation names a file this repo does not have"
  end

  test "every cited line is inside its file" do
    over = citations.select do |c|
      next false unless c[:path] && File.exist?(abs(c[:path]))
      len = source(c[:path]).size
      c[:ranges].any? { |r| r.last > len }
    end
    assert_empty over.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]} -> #{c[:path]} has #{source(c[:path]).size} lines" },
                 "citation points past the end of the file"
  end

  test "every citation lands on the symbol its prose names" do
    unanchored = citations.reject { |c| anchored?(c) }
    report = unanchored.map do |c|
      encl = enclosing_names(c).join(", ")
      "#{c[:doc]}:#{c[:line]}  #{c[:raw]}  -> #{c[:path]}  " \
        "encloses=[#{encl.empty? ? 'nothing' : encl}]  prose names=[#{prose_tokens(c).first(8).join(' ')}]"
    end
    assert_empty report,
                 "citation does not land on any symbol or literal its prose names — " \
                 "the number moved, or the prose did"
  end

  test "cross-repo references resolve to a real symbol in the resolved gem" do
    refs = engine_references
    assert_operator refs.size, :>=, 1, "expected the document to name at least one studio-engine file"
    root = Studio::Engine.root
    unnamed = refs.select { |r| r[:symbol].to_s.empty? }
    assert_empty unnamed.map { |r| "#{r[:doc]}:#{r[:line]} studio-engine:#{r[:path]}" },
                 "a cross-repo reference names no symbol — the line number is not there to " \
                 "carry the claim, so the symbol has to, and an empty one would match anything"
    broken = refs.reject do |r|
      path = root.join(r[:path])
      # (?![\w!?]) rather than \b: a bang method ends on a non-word character,
      # where \b never fires — which silently reddened every reference.
      File.exist?(path) &&
        File.read(path).match?(/\b(?:def|class|module)\s+#{Regexp.escape(r[:symbol])}(?![\w!?])/)
    end
    assert_empty broken.map { |r| "#{r[:doc]}:#{r[:line]} studio-engine:#{r[:path]} should define #{r[:symbol]}" },
                 "cross-repo reference names a file or symbol the resolved studio-engine does not have"
  end

  # The parse itself is asserted, because a guard that matches nothing passes.
  # PER DOCUMENT: a shared total would let one document's citations stand in for
  # another's, so a floor is only worth what the smallest guarded document has.
  test "the parse still finds citations of both shapes each document uses" do
    COVERAGE.each do |doc, spec|
      mine = citations_for(doc)
      assert_operator mine.size, :>=, spec.fetch(:min_citations),
                      "#{doc}: parsed #{mine.size} citations; the regex likely stopped matching"
      assert_operator mine.count { |c| c[:kind] == :path }, :>=, spec.fetch(:min_path),
                      "#{doc}: too few path-qualified citations parsed"
      assert_operator mine.count { |c| c[:kind] == :bare }, :>=, spec.fetch(:min_bare),
                      "#{doc}: too few bare :NN citations parsed"
    end
    assert citations.all? { |c| c[:path] },
           "a bare citation resolved to no file: " \
           "#{citations.reject { |c| c[:path] }.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]}" }.join(', ')}"
  end

  test "the citation convention the parser relies on is stated in the document" do
    GUARDED_DOCS.each do |doc|
      text = File.read(abs(doc))
      assert_match(/Code is law/, text, "#{doc} lost its citation preamble")
      assert_match(/bare `:NN`/, text,
                   "#{doc} must state that a bare :NN inherits the nearest preceding path — " \
                   "this parser resolves file context that way, and a reader has to know it too")
    end
  end

  # A citation whose cited lines are ALL blank names nothing. It clears the
  # symbol branch because a wide definition swallows it (limit 6) and it clears
  # the literal branch because a blank line has no token to reject, so it is
  # invisible to every other check here. web3-landing-to-entry.md:201 cited
  # _turf_totals_board.html.erb:1621 that way — blank, three lines past the
  # branch it named — and stayed green.
  test "no citation lands on lines that are entirely blank" do
    blank = citations.select { |c| blank_citation?(c) }
    assert_empty blank.map { |c| "#{c[:doc]}:#{c[:line]}  #{c[:raw]}  -> #{c[:path]}" },
                 "citation points at blank lines, which name nothing — cite the code, " \
                 "not the gap after it"
  end

  # The guard above is VACUOUSLY green on a correct document, so this proves it
  # bites. Nothing is hard-coded: a blank line and a non-blank line are located
  # at run time, so the control cannot itself go stale.
  test "the blank-line rejection rejects a blank citation and only a blank one" do
    lines       = source(BLANK_CONTROL_FILE)
    blank_no    = lines.index { |l| l.strip.empty? }&.succ
    nonblank_no = lines.index { |l| !l.strip.empty? }&.succ
    assert blank_no,    "expected #{BLANK_CONTROL_FILE} to contain a blank line"
    assert nonblank_no, "expected #{BLANK_CONTROL_FILE} to contain a non-blank line"

    assert blank_citation?(cite_at(BLANK_CONTROL_FILE, blank_no..blank_no)),
           "the rejection passed #{BLANK_CONTROL_FILE}:#{blank_no}, which is blank — " \
           "the guard above is inert"
    refute blank_citation?(cite_at(BLANK_CONTROL_FILE, nonblank_no..nonblank_no)),
           "the rejection failed #{BLANK_CONTROL_FILE}:#{nonblank_no}, which is not blank"

    lo, hi = [blank_no, nonblank_no].minmax
    refute blank_citation?(cite_at(BLANK_CONTROL_FILE, lo..hi)),
           "the rejection failed #{BLANK_CONTROL_FILE}:#{lo}-#{hi} — a range that merely " \
           "CONTAINS a blank line is legitimate; only an all-blank one names nothing"
  end

  # THE PREAMBLE MAKES CLAIMS ABOUT THIS GUARD, so this guard checks them. An
  # unenforced number in prose is the exact defect the document exists to
  # prevent, and it gets no exemption for being a number about the guard itself.
  test "the preamble states the split between the symbol branch and the fallback" do
    COVERAGE.each_key do |doc|
      mine     = citations_for(doc)
      symbol   = mine.count { |c| enclosing_names(c).any? }
      fallback = mine.size - symbol
      preamble = preamble_text(doc)

      m = preamble.match(/\*\*(\d+) of the (\d+) citations\*\*/)
      assert m, "#{doc}: the preamble must state how many citations get the SYMBOL check, " \
                "written `**N of the M citations**`. Left unqualified it promises a reader " \
                "a check that #{fallback} citations in this document do not get."
      said_symbol, said_total = m[1].to_i, m[2].to_i
      said_fallback = preamble[/[Tt]he other \*\*(\d+)\*\*/, 1].to_i

      assert_equal [symbol, mine.size, fallback], [said_symbol, said_total, said_fallback],
                   "#{doc}: the preamble says #{said_symbol} of #{said_total} on the symbol " \
                   "branch and #{said_fallback} on the fallback; measured #{symbol} of " \
                   "#{mine.size} and #{fallback}. Re-derive the numbers in the preamble — " \
                   "do not drop them."
    end
  end

  # The share alone would let a reader assume the fallback is scattered noise. It
  # is not: it is concentrated, and it covers the signing surface whole.
  test "the files the preamble names as fallback-only really are fallback-only" do
    COVERAGE.each do |doc, spec|
      expected = spec.fetch(:fallback_only_files)
      next if expected.empty?

      m = preamble_text(doc).match(/\*\*All (\d+) citations on ([^*]+)\*\*/)
      assert m, "#{doc}: the preamble must name the file(s) whose citations ALL ride the " \
                "weaker fallback, written **All N citations on `path`** — a backticked list " \
                "of paths where there is more than one"
      said_count = m[1].to_i
      said_paths = m[2].scan(/`([^`]+)`/).flatten

      assert_equal expected.sort, said_paths.sort,
                   "#{doc}: the preamble names #{said_paths.inspect}; this guard tracks " \
                   "#{expected.inspect}"

      on_files = citations_for(doc).select { |c| said_paths.include?(c[:path]) }
      assert_equal said_count, on_files.size,
                   "#{doc}: the preamble says #{said_count} citations on those files; " \
                   "there are #{on_files.size}"

      symbol_checked = on_files.select { |c| enclosing_names(c).any? }
      assert_empty symbol_checked.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]} inside #{enclosing_names(c).join(", ")}" },
                   "#{doc}: the preamble tells a reader EVERY citation on those files rides " \
                   "the weaker fallback branch. These no longer do, so the preamble now " \
                   "understates the guard — move the prose"
    end
  end

  # ---------------------------------------------------------------- machinery

  # A citation whose cited lines are all blank. `body.any?` keeps an out-of-range
  # citation out of this report: "past the end of the file" is a different defect
  # with a different remedy, and the bounds test above owns it.
  def blank_citation?(citation)
    return false unless citation[:path] && File.exist?(abs(citation[:path]))
    body = citation[:ranges].flat_map { |r| source(citation[:path])[(r.first - 1)..(r.last - 1)] || [] }
    body.any? && body.all? { |l| l.to_s.strip.empty? }
  end

  def cite_at(path, range)
    { doc: GUARDED_DOCS.first, line: 0, raw: "#{path}:#{range.first}-#{range.last}",
      kind: :path, path: path, ranges: [range] }
  end

  # The citations belonging to ONE guarded document. Every per-document claim
  # goes through here rather than through `citations`, so no assertion about one
  # document can be satisfied by another document's numbers.
  def citations_for(doc) = citations.select { |c| c[:doc] == doc }

  # A guarded document's preamble as ONE line. Blockquote markers and hard wraps
  # are typography, not content, and a claim must not escape a check by landing
  # on a line break.
  def preamble_text(doc)
    (@preamble_text ||= {})[doc] ||= begin
      lines = doc_lines(doc)
      start = lines.index { |l| l.start_with?(">") }
      if start
        fin = start
        fin += 1 while fin + 1 < lines.size && lines[fin + 1].start_with?(">")
        lines[start..fin].map { |l| l.sub(/\A>\s?/, "") }.join(" ").gsub(/\s+/, " ")
      else
        ""
      end
    end
  end

  def abs(rel) = Rails.root.join(rel).to_s

  def source(path)
    (@sources ||= {})[path] ||= File.readlines(abs(path), chomp: true)
  end

  # Citations, with file context resolved. A path-qualified citation sets the
  # context; a bare `:NN` inherits the nearest preceding one. Context is reset at
  # each `##` heading so a section cannot silently borrow the previous section's
  # file.
  def citations
    @citations ||= GUARDED_DOCS.flat_map do |doc|
      lines = File.readlines(abs(doc), chomp: true)
      basenames = {}
      lines.each do |l|
        l.scan(CITE) { basenames[File.basename($1)] ||= $1 if $1.include?("/") }
      end

      context = nil
      out = []
      lines.each_with_index do |line, i|
        context = nil if line.start_with?("## ")
        line.scan(CITE) do
          head, nums = $1, $2
          kind = head.empty? ? :bare : :path
          path = kind == :bare ? context : (head.include?("/") ? head : basenames[head])
          context = path if kind == :path && path
          out << {
            doc: doc, line: i + 1, raw: "#{head}:#{nums}", kind: kind, path: path,
            ranges: nums.split(",").map do |r|
              a, b = r.strip.split("-").map(&:to_i)
              (a..(b || a))
            end
          }
        end
      end
      out
    end
  end

  def engine_references
    @engine_references ||= GUARDED_DOCS.flat_map do |doc|
      File.readlines(abs(doc), chomp: true).each_with_index.flat_map do |line, i|
        line.scan(ENGINE).map do |(path)|
          { doc: doc, line: i + 1, path: path,
            symbol: symbol_named_before(doc, i + 1, path) }
        end
      end
    end
  end

  # The symbol a cross-repo reference claims: the LAST `Klass#method` token
  # written before it in the same prose unit. Reading the unit rather than the
  # one physical line is what lets the reference wrap — the alternative was an
  # unwrappable 140-column line in the document, which is a poor trade for a
  # parser's convenience.
  def symbol_named_before(doc, line_no, path)
    unit = prose_unit(doc: doc, line: line_no)
    head = unit[0...(unit.index(path) || unit.length)]
    head.scan(/`[A-Za-z_][\w:]*#(\w+[!?]?)`/).flatten.last ||
      head.scan(/`#(\w+[!?]?)`/).flatten.last.to_s
  end

  # The prose unit a citation belongs to. Inside a list, that is its own item
  # plus every ancestor item — a sub-bullet under "ContestsController#prepare_entry"
  # inherits that name, which is exactly how a reader reads it. Outside a list
  # (the preamble, a blockquote), it is the blank-line-delimited paragraph, so a
  # citation there is anchored by its own paragraph and not by whatever bullet
  # happened to precede it.
  def prose_unit(citation)
    lines = doc_lines(citation[:doc])
    idx = citation[:line] - 1

    s = idx
    s -= 1 while s.positive? && !list_item?(lines[s]) && !boundary?(lines[s])
    return paragraph(lines, idx) if boundary?(lines[s]) || !list_item?(lines[s])

    e = idx
    e += 1 while e + 1 < lines.size && !list_item?(lines[e + 1]) && !boundary?(lines[e + 1])
    text = lines[s..e].join("\n")

    indent = lines[s][/\A\s*/].size
    i = s - 1
    while i >= 0 && !boundary?(lines[i])
      if list_item?(lines[i]) && lines[i][/\A\s*/].size < indent
        indent = lines[i][/\A\s*/].size
        text = lines[i..(s - 1)].join("\n") + "\n" + text
        s = i
      end
      i -= 1
    end
    text
  end

  def list_item?(line) = line.match?(/\A\s*(?:[-*]|\d+\.)\s/)
  def boundary?(line)  = line.strip.empty? || line.start_with?("#")

  def paragraph(lines, idx)
    s = idx
    s -= 1 while s.positive? && !boundary?(lines[s - 1])
    e = idx
    e += 1 while e + 1 < lines.size && !boundary?(lines[e + 1])
    lines[s..e].join("\n")
  end

  def doc_lines(doc)
    (@doc_lines ||= {})[doc] ||= File.readlines(abs(doc), chomp: true)
  end

  # Backticked code spans in the prose unit, minus the citations themselves.
  def prose_tokens(citation)
    prose_unit(citation).scan(TOKEN).flatten.reject { |t| t.match?(/\A[\w.\/-]*:#{LINES}\z/) }
  end

  def enclosing_names(citation)
    return [] unless citation[:path] && File.exist?(abs(citation[:path]))
    defs = definitions(citation[:path])
    citation[:ranges].filter_map { |r| innermost(defs, r.first) }.map { |d| d[:name] }.uniq
  end

  # THE LITERAL BRANCH IS A FALLBACK, NOT AN ALTERNATIVE, and the order matters.
  # When the cited lines sit inside a definition, that definition IS the claim and
  # only naming it will do — otherwise a citation moved from `confirm_onchain!`
  # into `confirm!` passes on a shared `user.with_lock`, which is exactly the
  # near-miss this guard exists to catch (it survived mutation until this branch
  # was ordered). The literal check is reached only where there is no enclosing
  # symbol to name: routes entries, ERB markup, JSON blocks, callback
  # declarations in a class body.
  def anchored?(citation)
    return false unless citation[:path] && File.exist?(abs(citation[:path]))

    tokens = prose_tokens(citation)
    enclosing = enclosing_names(citation)
    if enclosing.any?
      names = tokens.flat_map { |t| t.scan(/[A-Za-z_][\w]*[!?]?/) }.uniq
      return enclosing.any? { |n| names.include?(n) }
    end

    cited = citation[:ranges].flat_map { |r| source(citation[:path])[(r.first - 1)..(r.last - 1)] || [] }.join("\n")
    tokens.any? do |t|
      probe = t.sub(/\A[#.:]/, "").split("(").first.to_s.strip
      next false if probe.length < MIN_LITERAL_TOKEN
      next false if STOP_TOKENS.include?(probe.downcase)
      cited.include?(probe)
    end
  end

  # --- symbol extraction -----------------------------------------------------

  def definitions(path)
    (@definitions ||= {})[path] ||=
      case File.extname(path)
      when ".rb"  then ruby_definitions(path)
      when ".erb" then erb_js_definitions(path)
      else []
      end
  end

  def ruby_definitions(path)
    out = []
    collect_defs(Prism.parse_file(abs(path)).value, out)
    out
  end

  def collect_defs(node, out)
    return unless node.is_a?(Prism::Node)
    if node.is_a?(Prism::DefNode)
      out << { name: node.name.to_s, first: node.location.start_line, last: node.location.end_line }
    end
    node.compact_child_nodes.each { |child| collect_defs(child, out) }
  end

  # Members of an inline-JS object literal (`toggleSelection(matchupId) {`,
  # `async confirmEntry() {`) and classic `function name(...) {`. The range is
  # found by brace balance, which is why control keywords are excluded — an
  # `if (...) {` is shaped identically.
  # The parameter list must be plain identifiers. `setTimeout(function () {` is a
  # CALL shaped exactly like a member definition, and a looser `\([^)]*\)` read it
  # as one — which credited a citation to "setTimeout" instead of the method it
  # actually sits in.
  JS_DEF = /\A(\s*)(?:async\s+)?(?:function\s+)?([A-Za-z_$][\w$]*)\s*\(\s*(?:[A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*\s*)?\)\s*\{\s*\z/
  JS_KEYWORDS = %w[if for while switch catch do else try function return with].freeze

  def erb_js_definitions(path)
    lines = source(path)
    lines.each_with_index.filter_map do |line, idx|
      m = JS_DEF.match(line)
      next unless m
      next if JS_KEYWORDS.include?(m[2])
      depth = 0
      last = nil
      (idx...lines.size).each do |j|
        depth += lines[j].count("{") - lines[j].count("}")
        if depth <= 0
          last = j + 1
          break
        end
      end
      { name: m[2], first: idx + 1, last: last || lines.size }
    end
  end

  def innermost(defs, line)
    defs.select { |d| d[:first] <= line && line <= d[:last] }
        .min_by { |d| d[:last] - d[:first] }
  end
end
