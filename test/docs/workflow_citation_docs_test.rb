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
# has to move a number in this file. The directory-wide checks carry the same
# floor for the same reason (MIN_DIRECTORY_CITATIONS) — and one more, because
# their scope is DERIVED rather than typed: a glob resolves to less than it
# should silently, so WORKFLOW_DOCS is asserted to reach every document COVERAGE
# names and to hold its measured citation count.
#
# ITS LIMITS, STATED PLAINLY.
#
#   1. IT GUARDS THE WHOLE DIRECTORY, WITH EVERY CHECK — since the sweep that
#      closed the split (sweep-workflow-symbol-citations, 2026-09-09). The history
#      is worth keeping, because it is the measurement that justified the cost.
#      The glob (WORKFLOW_DOCS) first carried only the three checks that need no
#      per-document metadata: the cited file exists, the cited line is inside it,
#      the cited lines are not all blank. The SYMBOL check — the one with teeth —
#      ran only over COVERAGE, because turning it on directory-wide failed 265 of
#      the 323 citations in the four documents the glob had newly reached
#      (admin-contest-setup 104, email-signup-token-to-chat 68,
#      referral-google-tokens-to-chat 51, slate-build 42 — measured by this
#      file's own parser). A wrong COORDINATE was caught everywhere; a wrong
#      SYMBOL only in COVERAGE.
#      WHAT THE WIDENING ITSELF CAUGHT, the day it landed: 18 stale citations in
#      three documents nothing had ever checked — 3 past end-of-file (including
#      admin-contest-setup.md's `admin_controller.rb:353` into a 77-line file,
#      stale long before the PR that made it visible), 8 landing on blank lines,
#      and 7 naming a file the repo does not have (4 bare basenames that resolved
#      to no file at all, 2 cross-repo references written with a line number
#      against limit 4 below, 1 missing its `app/controllers/` prefix). One of
#      the 7 was not merely mis-numbered but false: the board was said to expose
#      a `link_to "buy", tokens_buy_path` it has never had since the picker went
#      in-modal.
#      WHAT THE SWEEP PAID, document by document, re-derived against `accepted`
#      and opted in: referral-google-tokens-to-chat (57 citations in, 49 failing;
#      139 out), email-signup-token-to-chat (103 in, 64 failing; 179 out),
#      slate-build (48 in, 42 failing; 63 out), admin-contest-setup (121 in, 89
#      failing; 230 out, re-derived across a mid-task merge of `accepted`).
#      The counts rose because the sweep cited claims the documents had been
#      making with no number beside them. THE TWO UNCITED
#      DOCUMENTS were cited in the same pass — live-scoring (72) and
#      submit-entry-decision-tree (70) — because every check here starts from a
#      parsed citation, so a document with none was not weakly guarded, it was
#      invisible, and no glob or floor could reach it.
#      WHAT ONLY READING THE CODE CAUGHT, and limit 2 below is why it matters:
#      sentences that were false, not merely mis-numbered — contest creation
#      described as writing its DB row only AFTER the chain confirmed (it now
#      writes a write-ahead `pending` row BEFORE the prize pool moves) and as a
#      client-side `connection.sendRawTransaction` broadcast (the server cosigns
#      and broadcasts); a `tokens-submitted` modal step that does not exist; a
#      cart snapshot said to be in sessionStorage that has always been in
#      localStorage; a mint `source_ref` keyed on the Stripe session id that is
#      keyed on the purchase row; `#enter` described as verifying a wallet
#      signature for a Phantom session it now refuses; the root redirect's
#      main-contest chain naming a resolver (`SeasonConfig.main_contest`) it does
#      not call.
#      KEEPING IT CLOSED is the "every workflow document opts into COVERAGE"
#      test below: a new document is red until it is measured and opted in, or
#      deliberately named in UNCITED_DOCS — which is the only honest way for the
#      split to re-open.
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
#   7. A TABLE ROW ANCHORS ONLY ON ITSELF — and until 2026-09-10 it anchored on
#      the WHOLE TABLE. prose_unit knows lists (a citation's own item plus its
#      ancestors) and paragraphs (blank-line delimited). A markdown row starts
#      with `|`, which list_item? does not match, so a row fell through to
#      paragraph() and got every row of its table: any symbol named in ANY row
#      satisfied every citation in it. Found by Carl reviewing PR 681 and proved
#      with this file's own machinery — two rows of live-scoring.md with their
#      coordinates SWAPPED stayed green, while the identical falsification in
#      running prose went red. It was dormant for a reason: 81 of 972 citations
#      sat in tables, 77 of them in the two documents PR 681 newly cited. The
#      fix: a row is its own unit — its cells, and NOT the header row, because a
#      header that names a 223-line action would re-create the same loose
#      anchor one level up. Turning it on reddened 30 rows (submit-entry-
#      decision-tree 26, live-scoring 4), every one leaning on its table's
#      header for the action it cited; each row now names its own owner. The
#      control is "a table-row citation anchors only on its own row" below.
#      STILL STANDING, stated rather than fixed: enclosing_names reads only the
#      FIRST line of each range (`innermost(defs, r.first)`), so a range that
#      starts in a gap, or runs across two definitions, is judged by that one
#      line. A citation meant to span definitions should list them separately
#      (`:12-18, 30-41`) — each part is then judged on its own first line.
#   8. A ROUTES CITATION IS CHECKED DIFFERENTLY, AND STILL NOT PERFECTLY.
#      Nothing cites the two methods config/routes.rb happens to define
#      (`SidekiqAdminMiddleware`, :7-42), so no citation into it reaches the
#      symbol branch and `enclosing_names` is empty for all 21 — see the
#      ROUTES_FILE note below for the measured drift that came of leaving those
#      on the plain fallback. They now anchor on their FIRST cited line, which
#      is where a route entry lives, so a number that has slipped off its route
#      reddens. What that still misses, measured 2026-09-16 over 21 routes
#      citations: a one-line insertion above a citation reddens 19 of them and a
#      deletion 17, and the four survivors are all the same shape — the prose
#      names a probe that the NEIGHBOURING line carries too (`signin_redirect`
#      is written on three consecutive lines; `vault_init#build` sits one line
#      under `vault_init#show`, and a citation naming all three anchors on
#      either). That is the routes-file form of limit 6: the anchor is tight
#      enough to catch a number that left its stanza, not tight enough to catch
#      one that moved within it.
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
    },
    # Swept 2026-09-09. AN EMPTY `fallback_only_files` IS AN OPT-OUT OF THAT ONE
    # CLAIM, NOT OF THE GUARD. The per-file roster is a claim about the files it
    # NAMES, and in this document the fallback is spread thin — three ERB
    # partials, six class-body declarations, one constant, one route, one schema
    # column — with no file whose whole citation set rides it and whose name
    # would tell a reader anything. The split counts in the preamble are asserted
    # EXACTLY either way, and they are what carries the honest part of the claim,
    # so an invented roster here would be a second number to maintain and no
    # extra proof. Same reasoning for the three documents below it.
    "docs/workflows/referral-google-tokens-to-chat.md" => {
      min_citations: 120, min_path: 60, min_bare: 45,
      fallback_only_files: []
    },
    "docs/workflows/email-signup-token-to-chat.md" => {
      min_citations: 155, min_path: 65, min_bare: 85,
      fallback_only_files: []
    },
    "docs/workflows/slate-build.md" => {
      min_citations: 55, min_path: 30, min_bare: 20,
      fallback_only_files: []
    },
    "docs/workflows/admin-contest-setup.md" => {
      min_citations: 190, min_path: 105, min_bare: 80,
      fallback_only_files: %w[
        app/views/layouts/application.html.erb
        app/views/shared/_contest_create_intent.html.erb
      ]
    },
    # The two documents that were UNCITED until 2026-09-09 (see UNCITED_DOCS).
    # Both name a fallback-only file for the same mechanical reason
    # market-snapshot does: `definitions` reads only `.rb` and inline JS in
    # `.erb`, so an extensionless script and a `.js` module can never anchor on
    # a symbol, whatever their prose says.
    "docs/workflows/live-scoring.md" => {
      min_citations: 60, min_path: 30, min_bare: 28,
      fallback_only_files: %w[bin/nfl-live-poll]
    },
    "docs/workflows/submit-entry-decision-tree.md" => {
      min_citations: 60, min_path: 26, min_bare: 30,
      fallback_only_files: %w[app/javascript/solana_utils.js]
    },
    # The two WALLET documents (see WALLET_DOCS). Their floors are small because
    # most of what they cite lives in GEMS, and a gem fact is a GEM_REF — file and
    # symbol, no line — so it is counted by MIN_WALLET_GEM_REFS, not here.
    "docs/WALLET_TRANSPORT_ARCHITECTURE.md" => {
      min_citations: 3, min_path: 3, min_bare: 0,
      fallback_only_files: []
    },
    "docs/WALLET_ADAPTER_EVALUATION.md" => {
      min_citations: 20, min_path: 16, min_bare: 4,
      fallback_only_files: []
    }
  }.freeze

  GUARDED_DOCS = COVERAGE.keys.freeze

  # EVERY WORKFLOW DOCUMENT, GLOBBED — not a list, because a list is what let a
  # document be unguarded by being unmentioned. COVERAGE above is an opt-IN to
  # the per-document claims (floors, the preamble split, the fallback-only
  # roster); this is an opt-OUT of nothing. The three checks that need no
  # per-document metadata — the cited file exists, the cited line is inside it,
  # the cited lines are not all blank — run over WORKFLOW_DOCS, so a new
  # workflow file is guarded the moment it is written rather than when someone
  # remembers to add it here.
  #
  # THE SPLIT THIS ONCE CARRIED IS CLOSED. The symbol check could not be widened
  # for free — it asks that the prose beside a citation NAME the definition the
  # number lands in, and the four documents the glob first reached held 323
  # citations nobody had swept against it. Paying that sweep put every workflow
  # document into COVERAGE (limit 1 above has the numbers), so the symbol check
  # now reaches every citation this glob parses. The glob still earns its keep
  # twice: it is what the three universal checks iterate, and it is what the
  # COVERAGE-completeness test compares COVERAGE against, so a new document
  # cannot slip past the symbol check by being unmentioned.
  WORKFLOW_DOCS = Dir[Rails.root.join("docs/workflows/*.md")]
                  .map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }
                  .reject { |p| File.basename(p).start_with?("_") || File.basename(p) == "README.md" }
                  .sort.freeze

  # THE WALLET DOCUMENTS, brought under this guard on 2026-09-10
  # (/tasks/guard-the-wallet-docs). They carry the safety argument for the page
  # that renders a DECRYPTED PRIVATE KEY — why wallet export must never cross the
  # redirect — and until this list nothing read a word of them. Typed, not
  # globbed: they sit in docs/ beside documents nobody has swept, and a glob
  # wide enough to reach them would reach those too.
  #
  # MEASURED the day they came in, by this file's own parser: 49 citations, 11 of
  # them landing on what they named. 22 were line numbers into GEM files, and
  # 14 of those no longer landed on what they named in the gems the lock
  # resolved that day (read by hand; the parse could not see them); 7 were bare `:NN`
  # with no file context; 5 named a file the parser could not resolve; 1 pointed
  # into node_modules; 3 landed on the wrong file or on no quoted word. The same
  # pass found what NO citation check can see — limit 2 above — in §7 of the
  # transport document, which had gone stale TWICE by naming the solana-studio
  # version Gemfile.lock resolved. That claim is now held by the §7 test below.
  #
  # ONE blind spot is inherited and each preamble says so: a citation that lands
  # can still sit beside a false sentence. The other is FIXED — a citation inside
  # a markdown table anchored on the WHOLE table when these documents came in
  # (/tasks/table-row-anchors-siblings), which is why every row in them names its
  # own symbol; limit 7 below scoped a row to itself on 2026-09-13
  # (/tasks/citation-anchors-across-table-rows), and those rows now anchor on the
  # symbol they name rather than on a neighbour's.
  WALLET_DOCS = %w[
    docs/WALLET_TRANSPORT_ARCHITECTURE.md
    docs/WALLET_ADAPTER_EVALUATION.md
  ].freeze

  # ------------------------------------------------------ the declaration layer
  #
  # WHAT THIS CLOSES. Until 2026-09-15 the parse read `docs/workflows/*.md` plus
  # two typed wallet documents, and NOTHING read the rest of `docs/`. Measured
  # that day: 21 documents under `docs/` carry `path:line` citations and 10 were
  # in scope — 11 documents and 251 citations that no check had ever read. The
  # drift that found it had been sitting in one of them for three weeks
  # (`_preferredProvider` 48 lines off, `provider.on('accountChanged')` 67,
  # `_reauth` 94), found twice by hand, by two agents, hours apart.
  #
  # WHY A WIDER GLOB WAS THE WRONG FIX. The worst-drifted document is a DATED
  # Phase-1 audit snapshot that says on its face "No refactor has been performed."
  # Its citations are true AS OF ITS DATE and are meant to be frozen, so a glob
  # wide enough to reach it would redden a document that is behaving correctly.
  # And some documents cite repositories this one cannot read at all — turf-vault
  # Rust sources, studio-engine partials — where a line number is unverifiable
  # here whatever its state.
  #
  # SO THE DEFECT WAS NEVER THE SCOPE. It was that "unguarded" and "deliberately
  # frozen" LOOKED IDENTICAL: both were a file nobody had mentioned. A document
  # now says which it is, IN ITS OWN TEXT, and the inventory test below makes
  # silence the one thing it cannot say:
  #
  #   <!-- citation-guard: enforced -->
  #   <!-- citation-guard: snapshot <date> (<N> citations) -->
  #   <!-- citation-guard: external (<N> citations) — <what it cites> -->
  #   <!-- citation-guard: unswept (<N> citations) — <what is wrong with them> -->
  #
  # THE THREE EXEMPTIONS SAY DIFFERENT THINGS AND ARE NOT INTERCHANGEABLE.
  # `snapshot` is finished work, true on a date, and nobody should touch it.
  # `external` is permanent: the citations name a repository this one cannot read,
  # so no line number written here can ever be checked. `unswept` is a CONFESSION
  # — live citations into this repo that nobody has verified — and it is the only
  # one that implies future work. Writing it is not a way to be left alone; it is
  # a way to be counted. Two documents carry it today because this task measured
  # their coordinates and found them drifted, and saying so beats qualifying their
  # paths until the three checks pass while the numbers stay wrong.
  #
  # AN EXEMPTION ASSERTS ITS OWN COUNT, and that is the half that keeps this from
  # being the old hole with a nicer name. A frozen document that grows a citation
  # reddens this file and forces a deliberate act; it cannot absorb new,
  # unchecked coordinates the way an unmentioned file could. Same doctrine as
  # UNCITED_DOCS below: a number asserted EXACTLY is a claim, a list is not.
  #
  # THE MARKER GOES AT THE END OF THE FILE, and that is not a style preference.
  # `docs/SOLANA.md` and `docs/FORMULAS.md` are cited BY LINE from other
  # documents, so a marker at the top would shift every line in the file and
  # break the citations pointing into it — a declaration must not move the thing
  # it declares.
  DOCS_GLOB    = "docs/**/*.md"
  DECLARATION  = /<!--\s*citation-guard:\s*(enforced|snapshot|external|unswept)([^>]*)-->/
  STATED_COUNT = /\((\d+)\s+citations?\)/

  def self.docs_tree
    Dir[Rails.root.join(DOCS_GLOB)]
      .map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }
      .reject { |p| File.basename(p) == "README.md" || File.basename(p).start_with?("_") }
      .sort
  end

  def self.declaration_for(doc)
    m = File.read(Rails.root.join(doc)).match(DECLARATION)
    return nil unless m

    { kind: m[1].to_sym, detail: m[2].to_s.strip, count: m[2][STATED_COUNT, 1]&.to_i }
  end

  DECLARATIONS  = docs_tree.filter_map { |d| [d, declaration_for(d)] if declaration_for(d) }.to_h.freeze
  ENFORCED_DOCS = DECLARATIONS.select { |_, v| v[:kind] == :enforced }.keys.sort.freeze
  EXEMPT_DOCS   = DECLARATIONS.reject { |_, v| v[:kind] == :enforced }.keys.sort.freeze

  # What the parse reads: every document that declares itself enforced. The two
  # constants above still carry their own claims — the workflow glob is what the
  # COVERAGE-completeness test compares against, and the wallet list is typed so a
  # rename fails loudly — and the test below pins both sets to a declaration, so a
  # guarded document cannot be quietly downgraded to an exemption.
  SCANNED_DOCS = (WORKFLOW_DOCS + WALLET_DOCS + ENFORCED_DOCS).uniq.sort.freeze

  # Paths a citation may name that are NOT this repo's code and are not present
  # in CI: node_modules is installed by npm, never committed, so a citation into
  # it is true or false depending on the machine. Such a citation is skipped, and
  # the document pins the package version in its sentence and says so in its
  # preamble.
  EXTERNAL_PREFIXES = %w[node_modules/].freeze

  # Documents that parse to ZERO citations, named so the hole is loud. A
  # directory-wide glob cannot see them — every check here starts from a parsed
  # citation, so a document that cites nothing is not weakly guarded, it is
  # invisible — and naming them is the only way the count stays honest. The
  # assertion is EQUALITY, both directions: a document going uncited is a
  # regression, and citing one listed here without striking it leaves a false
  # claim in the README that points at it.
  #
  # EMPTY SINCE 2026-09-09, and deliberately kept rather than deleted. It held
  # live-scoring.md and submit-entry-decision-tree.md until the sweep cited both.
  # An empty list asserted EXACTLY is still a claim — "no workflow document is
  # uncited" — and it is the one sanctioned way to exempt a document from the
  # COVERAGE-completeness test: name it here, and say so in the README.
  UNCITED_DOCS = [].freeze

  # The floor for the directory-wide parse, set below the 972 citations
  # WORKFLOW_DOCS held after the sweep (measured 2026-09-10 by this file's own
  # parser: admin-contest-setup 230, email-signup-token-to-chat 179,
  # web3-landing-to-entry 164, referral-google-tokens-to-chat 139, live-scoring
  # 72, submit-entry-decision-tree 70, slate-build 63, market-snapshot 55). It
  # was 500 against 542 before the sweep; raised deliberately, because a floor
  # left far below the real count stops catching a regex that half-matches.
  # Same reasoning as the per-document floors: a glob that stops matching — the
  # directory renamed, the citation style changed — passes every check above
  # having proved nothing, and this is what makes that a red test instead of a
  # quiet one.
  MIN_DIRECTORY_CITATIONS = 850

  # Tokens too common to anchor anything. A citation that only matches one of
  # these has not been verified by the literal branch.
  STOP_TOKENS = %w[
    true false nil null return raise status error success entry entries user users
    contest contests session cookies params render json post get put patch delete
    active cart admin slug name value data config script async await function var
  ].freeze

  MIN_LITERAL_TOKEN = 6

  # THE SAME JUDGEMENT AS STOP_TOKENS, MADE PER FILE — and this is the half that
  # was missing. STOP_TOKENS says a word can be too common to anchor anything;
  # it says it ONCE, globally, from a list someone wrote. But commonness is a
  # property of the FILE the number points into, and a word that is rare in
  # English can be everywhere in one document.
  #
  # MEASURED, the citation that proved it: admin-contest-setup.md:169 cited
  # `docs/SOLANA.md:542` for the claim that a Squad upgrade runs only the BPF
  # `upgrade` instruction. The sweep in /tasks/sweep-stale-signer-claims moved
  # that section, and :542 came to rest on
  #
  #     **upgrade** needs a buffer sized `37 + 545928` bytes, which rents for
  #
  # — buffer-rent arithmetic, saying nothing whatever about the BPF instruction.
  # It stayed GREEN, because the line holds the word `upgrade`: 7 characters,
  # longer than MIN_LITERAL_TOKEN, absent from STOP_TOKENS. `upgrade` occurs on
  # 22 of that document's 947 lines, so landing on one of them was worth nothing
  # — the number could have been any of 22 and passed. Its SIBLING citation in
  # the same sentence shifted too, landed on a blank line, and failed loudly; a
  # human caught this one. Half a pair is not a guard.
  #
  # SO A BARE WORD MUST ALSO BE RARE WHERE IT LANDS. A probe with no structure —
  # no `_`, `::`, `#`, `.`, `-`, no camelCase, no digit, no space — is an
  # ordinary word, and an ordinary word anchors only if the cited file says it
  # seldom. A STRUCTURED probe (`EXPECTED_IDL_HASH`, `Solana::Config.verify_idl!`,
  # `entry_pda`) is specific by construction and is left alone: capping it too
  # would redden correct citations when unrelated code grows a mention, which is
  # the failure this guard must never have.
  #
  # THE NUMBER, measured 2026-09-15 over all 215 fallback citations then in
  # scope, and re-derived in review the same day. The weakest honest bare-word
  # anchor in the corpus is `detect` in app/javascript/wallet_provider.js at 9
  # lines; every cap from 9 up costs nothing, 8 down to 4 costs three true
  # citations, and 3 or below costs more.
  #
  # COUNT THE DEFECT WITH THE MATCHER THIS CAP ENFORCES, which is the one place
  # this paragraph could mislead the reader it invites not to re-measure. At
  # 7c794bf4 `upgrade` was on 22 of docs/SOLANA.md's 947 lines BY SUBSTRING —
  # the OLD rule's matcher, and the right number for "the coordinate could have
  # been any of 22 and passed" — but on 17 of those same lines by the
  # WHOLE-TOKEN match this cap actually counts. Twelve clears the honest
  # maximum by three and rejects the defect under either figure. Tightening it
  # is a one-number change, and the distribution is written down here so the
  # next reader need not re-measure it — with each spread's matcher named,
  # because a spread means nothing without one.
  #
  # WHAT THIS STILL DOES NOT DO, said plainly. It does not prove a coordinate.
  # It proves the coordinate is not ARBITRARY — that the word the prose named is
  # not scattered so thickly through the file that any number would have passed.
  # A bare word on 8 lines still anchors on all 8. The symbol branch is what
  # proves a landing, and it runs first for exactly that reason.
  MAX_BARE_WORD_LINES = 12

  # NO CITATION INTO config/routes.rb REACHES THE SYMBOL BRANCH, and that is
  # why it rotted. `definitions` reads Ruby with Prism and collects DefNodes;
  # the routes a document cites are `draw do` entries, not method bodies, so
  # `enclosing_names` is empty for EVERY citation into it and every one of them
  # falls to the literal branch — not by an editor's choice, by construction.
  # The fallback then asks only that some prose token appear SOMEWHERE in the
  # cited span, and a routes stanza repeats its own words, so a span that has
  # slipped a line or two off its route still holds one.
  #
  # MEASURED, the drift this rule exists to reject: phantom-cashout-needs-sol
  # inserted ONE line (`post "offramp/cosign_send"`) and moved every route below
  # it by one. Five citations in three documents went stale and all five stayed
  # GREEN — admin-contest-setup.md:66 cited `vault_init#show, #build, #confirm`
  # at a span that opened on a blank line, held only `#show`, and dropped the
  # other two; live-scoring.md cited `resources :weeks` at a span whose first
  # line was the tail of a five-line comment. Each still contained one token, so
  # each passed. A wrong number that reads as verified is the defect this whole
  # file exists to prevent, and here the guard was issuing the certificate.
  #
  # SO A ROUTES CITATION ANCHORS ON ITS FIRST LINE, not anywhere in its span.
  # A route entry is ONE line — `get "vault_init", to: "vault_init#show"` — so
  # the line that carries the quoted token is the claim, and the number either
  # lands on it or is wrong. Shift the span and the first line changes; that is
  # what makes a one-line insertion redden here instead of six months later.
  #
  # WITH ONE EXEMPTION, because the documents cite routes COMMENTS deliberately
  # (limit 3): a route drawn by the engine now has no line of its own in this
  # file, only the comment block saying so. Such a citation anchors on any line
  # of that block — but the span must be the WHOLE block, bounded above and
  # below by non-comment lines. Citing a block exactly is a claim a shift breaks;
  # citing part of one is how `config.draw_geo_routes` came to be cited at a span
  # that opened on three transaction-log routes and a blank line.
  #
  # AND THE MATCH IS WHOLE-TOKEN, where the literal branch is a substring. The
  # substring rule reads `Studio::LinksController` as a hit for `Studio::Link`,
  # which is exactly how a shifted span keeps passing: the neighbouring line
  # says almost the same words. Whole-token is what the bare-word cap already
  # uses, applied here to every probe rather than only the ordinary words.
  ROUTES_FILE = "config/routes.rb"

  # The floor for the routes parse, below the 21 citations into config/routes.rb
  # that SCANNED_DOCS held when this rule landed (2026-09-16). Same reasoning as
  # every other floor here: a rule that matches nothing passes having proved
  # nothing.
  MIN_ROUTE_CITATIONS = 15

  # A real repo file used as the CONTROL for the blank-line rejection below. It
  # needs only two properties — it exists, and it holds both a blank line and a
  # non-blank one — and the control locates them at run time, so it cannot go
  # stale. Which file it is carries no other meaning; the per-document claim
  # about fallback-only files lives in COVERAGE above.
  BLANK_CONTROL_FILE = "app/views/layouts/application.html.erb"

  # The CONTROL for the table-row rule below: a real model with two sibling
  # methods, each located at run time so the control cannot go stale. Which
  # methods they are carries no meaning beyond being two distinct definitions.
  TABLE_CONTROL_FILE    = "app/models/entry.rb"
  TABLE_CONTROL_METHODS = %w[confirm! assert_enterable!].freeze

  # A citation: `path/to/file.rb:12`, `file.rb:12-18`, `:12`, `:12, 20-24`.
  LINES  = /\d+(?:-\d+)?(?:,\s*\d+(?:-\d+)?)*/
  CITE   = /`([^`]*?):(#{LINES})`/
  # A cross-repo reference: `studio-engine: app/models/session_context.rb`.
  ENGINE = /`studio-engine:\s*([\w.\/-]+\.rb)`/
  TOKEN  = /`([^`]+)`/

  # ---------------------------------------------------------------- the tests

  # DIRECTORY-WIDE (WORKFLOW_DOCS), not COVERAGE. A citation naming a file this
  # repo does not have is wrong on its face — no sweep, no prose read, and no
  # per-document metadata is needed to say so, and the remedy is one path.
  test "every cited file exists in this repo" do
    missing = all_citations.reject { |c| c[:path] && File.exist?(abs(c[:path])) }
    assert_empty missing.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]} -> #{c[:path] || 'UNRESOLVED FILE CONTEXT'}" },
                 "citation names a file this repo does not have"
  end

  # DIRECTORY-WIDE. This is the check that was missing when
  # admin-contest-setup.md:139 cited admin_controller.rb:353 into a 77-line file
  # — a citation that had been past EOF since long before the PR that made it
  # visible, in a document nothing guarded. A bounds failure is unambiguous and
  # its remedy is one number, which is exactly why it does not need COVERAGE.
  test "every cited line is inside its file" do
    over = all_citations.select do |c|
      next false unless c[:path] && File.exist?(abs(c[:path]))
      len = source(c[:path]).size
      c[:ranges].any? { |r| r.last > len }
    end
    assert_empty over.map { |c| "#{c[:doc]}:#{c[:line]} #{c[:raw]} -> #{c[:path]} has #{source(c[:path]).size} lines" },
                 "citation points past the end of the file"
  end

  # DIRECTORY-WIDE, and the reason is the whole ROUTES_FILE note above: this is
  # the one cited file where the symbol branch can never run, so without this
  # rule a routes citation gets the weakest check in the file. Measured 2026-09-16:
  # all 21 come from FIVE documents, every one of them in COVERAGE — so this
  # reaches nothing the symbol test misses today. It is the guard for the day an
  # `enforced` document outside COVERAGE cites a route.
  test "a config/routes.rb citation starts on the line that carries its route" do
    routes = all_citations.select { |c| c[:path] == ROUTES_FILE }
    assert_operator routes.size, :>=, MIN_ROUTE_CITATIONS,
                    "parsed #{routes.size} citations into #{ROUTES_FILE}; the parse or the path " \
                    "likely stopped matching"
    src = source(ROUTES_FILE)
    adrift = routes.reject { |c| route_anchored?(c) }
    assert_empty adrift.map { |c|
      first = c[:ranges].first.first
      "#{c[:doc]}:#{c[:line]}  #{c[:raw]}  opens on: #{src[first - 1].to_s.strip.inspect}  " \
        "prose names=[#{prose_probes(c).first(6).join(' ')}]"
    }, "a routes citation does not open on the line carrying the route its prose names. " \
       "A routes entry is one line — put the number on it, or cite the whole comment block"
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

  # THE GLOB IS PART OF THE GUARD. WORKFLOW_DOCS is derived, not typed, so the
  # way it fails is by resolving to less than it should — the directory moved,
  # the extension changed, a doc dropped its citations — and every check above it
  # would then pass having read nothing. This floor is what makes that red.
  test "the directory-wide parse still reaches every workflow document" do
    assert_operator WORKFLOW_DOCS.size, :>=, 8,
                    "the docs/workflows glob resolved #{WORKFLOW_DOCS.size} document(s): #{WORKFLOW_DOCS.inspect}"
    workflow = all_citations.count { |c| WORKFLOW_DOCS.include?(c[:doc]) }
    assert_operator workflow, :>=, MIN_DIRECTORY_CITATIONS,
                    "parsed #{workflow} citations across docs/workflows; the regex or the glob " \
                    "likely stopped matching"
    GUARDED_DOCS.each do |doc|
      assert_includes SCANNED_DOCS, doc,
                      "#{doc} carries per-document claims but the parse does not reach it"
    end
    # A typed list fails differently from a glob: a renamed file leaves the
    # name here pointing at nothing, and the parse then reads nothing of it.
    WALLET_DOCS.each do |doc|
      assert File.exist?(abs(doc)), "#{doc} is in WALLET_DOCS but does not exist — it moved, and " \
                                    "this guard silently stopped reading it"
      assert_includes GUARDED_DOCS, doc, "#{doc} is scanned but not in COVERAGE, so the SYMBOL check never reads it"
    end
  end

  # THE OTHER DIRECTION OF THE ONE ABOVE, AND THE TEST THAT KEEPS THE SPLIT
  # CLOSED. The loop above asserts every COVERAGE document is reached by the
  # glob; this asserts every globbed document is in COVERAGE (or deliberately
  # named in UNCITED_DOCS). Without it the split re-opens silently the day a
  # new workflow document is written: the three universal checks would guard
  # its coordinates, and nothing would check a single one of its symbols.
  test "every workflow document opts into COVERAGE" do
    unswept = WORKFLOW_DOCS - GUARDED_DOCS - UNCITED_DOCS
    assert_empty unswept,
                 "these docs/workflows/ documents are not in COVERAGE, so the SYMBOL check never " \
                 "reads them — only the three coordinate checks do. Opt each one in: make every " \
                 "citation land inside the definition its prose names, state the split in its " \
                 "preamble as **N of the M citations** / the other **K**, and add it to COVERAGE " \
                 "with floors measured just below its own counts."
  end

  # A document with no citations is INVISIBLE to every check here — each one
  # starts from a parsed citation — so the only honest guard is to name the set
  # and hold it exactly. Equality both ways: a third document going uncited is a
  # regression the glob cannot otherwise see, and citing one of these two without
  # striking it from UNCITED_DOCS leaves the README pointing a reader at a
  # warning that is no longer true.
  test "the documents that cite nothing are exactly the ones named as uncited" do
    measured = WORKFLOW_DOCS.reject { |doc| all_citations.any? { |c| c[:doc] == doc } }
    assert_equal UNCITED_DOCS.sort, measured.sort,
                 "docs/workflows/ documents parsing to ZERO citations changed. Every check in this " \
                 "file starts from a citation, so an uncited document is unguarded, not weakly " \
                 "guarded — cite it, or move it in UNCITED_DOCS and fix docs/workflows/README.md, " \
                 "which names this set to its readers."
  end

  # ------------------------------------------------------------- the inventory

  # THE TEST THAT MAKES SILENCE IMPOSSIBLE. Every check in this file starts from
  # a citation in a document the scope reads, so until now a document was
  # unguarded by the simple act of not being mentioned — and that looked exactly
  # like a document deliberately left frozen. This one runs the other way: it
  # starts from the DIRECTORY, finds every document that cites code, and asks
  # each one what it is. A document may answer `enforced`, `snapshot` or
  # `external`; what it may no longer do is fail to answer.
  test "every docs/ document that cites code says whether it is guarded" do
    report = undeclared_citing_docs.map { |d| "#{d} (#{parse_doc(d).size} citations)" }
    assert_empty report,
                 "these documents carry `path:line` citations and declare nothing, so no check " \
                 "in this file reads one of them — which is indistinguishable from a document " \
                 "deliberately frozen. End the file with ONE of:\n" \
                 "  <!-- citation-guard: enforced -->\n" \
                 "  <!-- citation-guard: snapshot <date> (<N> citations) -->\n" \
                 "  <!-- citation-guard: external (<N> citations) — <what it cites> -->\n" \
                 "  <!-- citation-guard: unswept (<N> citations) — <what is wrong with them> -->\n" \
                 "`enforced` puts it under the three coordinate checks; the other three are " \
                 "exemptions and must state their citation count, which this file holds exactly."
  end

  # AN EXEMPTION THAT DOES NOT COUNT ITSELF IS THE OLD HOLE WITH A NICER NAME.
  # A frozen document is allowed to keep citations nothing checks; it is NOT
  # allowed to quietly acquire new ones. Holding the stated count exactly means a
  # citation added to an exempt document reddens this file and forces a
  # deliberate act — either sweep the document into `enforced`, or restate the
  # number and say why it grew.
  test "an exemption states its citation count, and the count is exact" do
    wrong = EXEMPT_DOCS.filter_map do |doc|
      stated   = DECLARATIONS[doc][:count]
      measured = parse_doc(doc).size
      next if stated == measured

      "#{doc}: declares #{stated.inspect}, carries #{measured}"
    end
    assert_empty wrong,
                 "an exempt document's citation count moved. The count is the whole of what an " \
                 "exemption is held to — restate it, or put the document under the guard."
  end

  # A snapshot's claim is that its citations were true ON A DATE. Without the
  # date the word means only "not checked", which is the state this layer exists
  # to abolish.
  test "a snapshot declaration carries the date its citations are true as of" do
    undated = EXEMPT_DOCS.select { |d| DECLARATIONS[d][:kind] == :snapshot }
                         .reject { |d| DECLARATIONS[d][:detail].match?(/\b\d{4}-\d{2}-\d{2}\b/) }
    assert_empty undated,
                 "a snapshot must say what it is a snapshot OF: " \
                 "<!-- citation-guard: snapshot 2026-08-25 (175 citations) -->"
  end

  # THE TWO MECHANISMS ARE PINNED TO EACH OTHER. The workflow glob and the typed
  # wallet list are still the claims they always were, and this stops a guarded
  # document from being downgraded to an exemption by editing one line of its own
  # text — the declaration must agree with the scope it is already in.
  test "every workflow and wallet document declares itself enforced" do
    wrong = (WORKFLOW_DOCS + WALLET_DOCS).uniq.filter_map do |doc|
      kind = DECLARATIONS[doc]&.fetch(:kind)
      next if kind == :enforced

      "#{doc}: #{kind ? "declares #{kind}" : 'declares nothing'}"
    end
    assert_empty wrong,
                 "a document this file guards by glob or by name must also declare itself " \
                 "`enforced`, so the two mechanisms cannot drift apart"
  end

  # -------------------------------------------------------------- the controls

  # CONTROL FOR THE INVENTORY. The test above is VACUOUSLY green once every
  # document is declared, so this proves it still bites: a NEW document carrying
  # a citation, declaring nothing, must be named. Nothing is hard-coded — the
  # document is written at run time, cited against a file located from the
  # repository, and removed again — so the control cannot go stale, and it
  # exercises the shipped predicate rather than re-implementing it.
  test "the inventory catches a new document that cites code and declares nothing" do
    rel = "docs/citation-guard-inventory-control.md"
    File.write(abs(rel), "Control fixture. Cites `#{BLANK_CONTROL_FILE}:1` and declares nothing.\n")

    assert_includes self.class.docs_tree, rel,
                    "the inventory's glob does not reach a new document in docs/ — it is a list " \
                    "again, and a new document is unguarded the moment it is written"
    assert_nil self.class.declaration_for(rel), "the control fixture must declare nothing"
    assert_equal 1, parse_doc(rel).size, "the control fixture must parse to exactly one citation"
    assert_includes undeclared_citing_docs, rel,
                    "the inventory passed a document that cites code and declares nothing — it " \
                    "is inert, and hole 1 is open again"
  ensure
    File.delete(abs(rel)) if rel && File.exist?(abs(rel))
  end

  # CONTROL FOR THE ROUTES ANCHOR — the defect rebuilt from the repository
  # rather than described, and the half that matters is the SECOND assertion:
  # green alone would prove only that the new rule is not reddening a correct
  # citation. The control takes a live routes citation, shifts it the way an
  # inserted route shifts every citation below it, and shows the rule this
  # replaced ACCEPTED that span while this one rejects it. Every coordinate is
  # located at run time, so a later route insertion cannot make the control lie.
  #
  # THE CORPUS FLOORS BELOW are the breadth half, and they are floors rather
  # than equalities because the rule does not claim to catch every shift.
  # Measured 2026-09-16 over the 21 routes citations then in scope: a one-line
  # INSERTION above a citation reddens 19 of 21, a DELETION 17 of 21. What
  # survives is stated in limit 8 above — a probe the prose names that occurs on
  # the neighbouring line too, which is the routes-file form of the weakness the
  # bare-word cap addresses elsewhere.
  ROUTE_CONTROL_PROBE   = "vault_init#show"
  MIN_INSERTION_CAUGHT  = 19
  MIN_DELETION_CAUGHT   = 17

  test "a one-line routes shift is rejected where the literal fallback accepted it" do
    routes = all_citations.select { |c| c[:path] == ROUTES_FILE }
    assert_operator routes.size, :>=, MIN_ROUTE_CITATIONS,
                    "parsed #{routes.size} citations into #{ROUTES_FILE} — the control has nothing to shift"

    live = routes.find { |c| prose_probes(c).include?(ROUTE_CONTROL_PROBE) }
    assert live, "no guarded document cites #{ROUTES_FILE} beside `#{ROUTE_CONTROL_PROBE}` any more — " \
                 "re-point this control at whatever carries that shape now"
    assert route_anchored?(live),
           "the live citation #{live[:doc]}:#{live[:line]} #{live[:raw]} stopped anchoring — the " \
           "rule is over-tight and is reddening a correct citation"

    shifted = shift_citation(live, -1)
    assert old_literal_anchored?(shifted),
           "the shifted span #{shifted[:raw]} no longer satisfies the rule this replaced, so the " \
           "control proves nothing — it has to reproduce a span the OLD rule passed"
    refute route_anchored?(shifted),
           "a citation shifted one line off its route still anchors:\n" \
           "    #{source(ROUTES_FILE)[shifted[:ranges].first.first - 1].to_s.strip}\n" \
           "That is exactly what one inserted route did to five citations in three documents, " \
           "every one of them staying green while naming the wrong lines."

    insertion = routes.count { |c| !route_anchored?(shift_citation(c, -1)) }
    deletion  = routes.count { |c| !route_anchored?(shift_citation(c, 1)) }
    assert_operator insertion, :>=, MIN_INSERTION_CAUGHT,
                    "a one-line insertion now reddens only #{insertion} of #{routes.size} routes " \
                    "citations; it caught #{MIN_INSERTION_CAUGHT} when this rule landed"
    assert_operator deletion, :>=, MIN_DELETION_CAUGHT,
                    "a one-line deletion now reddens only #{deletion} of #{routes.size} routes " \
                    "citations; it caught #{MIN_DELETION_CAUGHT} when this rule landed"
  end

  # CONTROL FOR THE BARE-WORD RULE — the defect, rebuilt from the repository
  # rather than described. It takes the real citation into docs/SOLANA.md, proves
  # it anchors where it points now, then moves ONLY the number onto a line that
  # merely says `upgrade`, and proves three things about that line: the old rule
  # passed it, the word is too common in that file to mean anything, and the rule
  # now rejects it. Every coordinate is located at run time, so the sweep that
  # moved the section the first time cannot make this control lie.
  test "a bare word too common in the cited file no longer anchors a number" do
    real = citations.find { |c| c[:path] == "docs/SOLANA.md" && bare_word_probes(c).include?("upgrade") }
    assert real, "expected a guarded document to cite docs/SOLANA.md beside the word `upgrade` — " \
                 "the control is stale; re-point it at whatever carries that shape now"
    assert anchored?(real), "the live citation #{real[:doc]}:#{real[:line]} #{real[:raw]} stopped " \
                            "anchoring — the rule is over-tight and is reddening a correct citation"

    src   = source("docs/SOLANA.md")
    rx    = whole_token("upgrade")
    spread = src.count { |l| l.match?(rx) }
    assert_operator spread, :>, MAX_BARE_WORD_LINES,
                    "`upgrade` now occurs on only #{spread} lines of docs/SOLANA.md, at or under " \
                    "the cap — the file changed and this control no longer reproduces the defect"

    others = (prose_probes(real) - ["upgrade"])
    decoy  = src.each_index.find do |i|
      src[i].match?(rx) && others.none? { |p| src[i].include?(p) } && !real[:ranges].any? { |r| r.cover?(i + 1) }
    end
    assert decoy, "docs/SOLANA.md no longer has a line that says `upgrade` and nothing else this " \
                  "citation names — the control cannot be built"

    moved = real.merge(raw: "docs/SOLANA.md:#{decoy + 1}", ranges: [(decoy + 1)..(decoy + 1)])
    assert src[decoy].include?("upgrade"),
           "the control's decoy line must satisfy the OLD literal test, or this proves nothing"
    refute anchored?(moved),
           "a citation moved onto docs/SOLANA.md:#{decoy + 1} still anchors:\n" \
           "    #{src[decoy].strip}\n" \
           "That line carries the word `upgrade` and nothing else the prose names, and `upgrade` " \
           "is on #{spread} of this file's #{src.size} lines — the number could be any of them. " \
           "This is the near-miss the bare-word cap exists to reject."
  end

  # CONTROL FOR THE EXEMPTIONS — the false-positive half, and the reason this
  # task did not simply widen the glob. A dated snapshot must stay GREEN. Green
  # alone proves nothing, so this also measures what enforcing it WOULD cost:
  # the document has to carry citations that a universal check would reject, or
  # its exemption is not load-bearing and it should just be swept in.
  test "a dated snapshot stays exempt, and its exemption is doing work" do
    snapshots = EXEMPT_DOCS.select { |d| DECLARATIONS[d][:kind] == :snapshot }
    assert_operator snapshots.size, :>=, 1, "expected at least one dated snapshot under docs/"

    snapshots.each do |doc|
      refute_includes SCANNED_DOCS, doc,
                      "#{doc} declares itself a snapshot but the parse reads it anyway — the " \
                      "declaration is decorative"
    end

    load_bearing = snapshots.select do |doc|
      parse_doc(doc).any? { |c| c[:path].nil? || !File.exist?(abs(c[:path])) }
    end
    assert_operator load_bearing.size, :>=, 1,
                    "every snapshot's citations would pass the universal checks today, so nothing " \
                    "is being spared — sweep them into `enforced` rather than exempting them"
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
  # DIRECTORY-WIDE, for the same reason as the two above: "these lines are all
  # blank" is decidable from the file alone.
  test "no citation lands on lines that are entirely blank" do
    blank = all_citations.select { |c| blank_citation?(c) }
    assert_empty blank.map { |c| "#{c[:doc]}:#{c[:line]}  #{c[:raw]}  -> #{c[:path]}" },
                 "citation points at blank lines, which name nothing — cite the code, " \
                 "not the gap after it"
  end

  # The guard above is VACUOUSLY green on a correct document, so this proves it
  # bites. Nothing is hard-coded: a blank line and a non-blank line are located
  # at run time, so the control cannot itself go stale.
  # A TABLE ROW IS ITS OWN PROSE UNIT. A markdown row starts with `|`, which
  # list_item? does not match, so prose_unit used to fall through to
  # paragraph() — blank-line delimited, i.e. THE WHOLE TABLE — and any symbol
  # named in ANY row anchored every citation in it. Found by Carl reviewing
  # PR 681: two rows of live-scoring.md with their coordinates SWAPPED stayed
  # green. The fixture is built from two real sibling methods located at run
  # time, so it cannot go stale, and it is checked in all three shapes: honest
  # rows anchor, a single falsified row does not, a swapped pair does not.
  test "a table-row citation anchors only on its own row" do
    honest = table_fixture(TABLE_CONTROL_METHODS.map { |m| [m, m] })
    assert honest.all? { |c| anchored?(c) },
           "honest table rows stopped anchoring — the table rule is over-tight: " \
           "#{honest.reject { |c| anchored?(c) }.map { |c| c[:raw] }.join(", ")}"

    first, second = TABLE_CONTROL_METHODS
    falsified = table_fixture([[first, second], [second, second]])
    refute anchored?(falsified.first),
           "a row naming #{first} but citing a line inside #{second} anchored — a sibling " \
           "row naming #{second} is still satisfying it, so rows are NOT scoped"

    swapped = table_fixture([[first, second], [second, first]])
    assert swapped.none? { |c| anchored?(c) },
           "a SWAPPED row pair anchored — each row is being satisfied by the other row's symbol"
  end

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

  # ------------------------------------------------- the wallet documents' gems

  # A GEM FACT NAMES A SYMBOL, NOT A LINE — limit 4's rule, which the wallet
  # documents broke 22 times with `wallet_transport.js:310-319`-style numbers
  # into solana-studio and studio-engine. 14 had rotted by the day they were
  # checked, because the gems moved under them. The form they use now carries the
  # symbol INSIDE the reference, so the claim cannot drift from the thing it
  # names: `solana-studio: app/assets/.../wallet_transport.js#requireField`, or
  # several at once, `...#codec,PROFILES,requireField`.
  GEM_REF = /`(solana-studio|studio-engine):\s*([\w.\/-]+\.(?:rb|js|erb))#([\w$!?]+(?:,[\w$!?]+)*)`/
  # Below the 19 symbol references the wallet documents carried when they came
  # in, for the reason every floor here exists: a reference style that stops
  # matching must go red, not pass having read nothing.
  MIN_WALLET_GEM_REFS = 15

  test "a wallet document's gem references name symbols the resolved gem defines" do
    refs = gem_references.select { |r| WALLET_DOCS.include?(r[:doc]) }
    assert_operator refs.size, :>=, MIN_WALLET_GEM_REFS,
                    "parsed #{refs.size} gem references in the wallet documents; GEM_REF likely stopped matching"
    broken = refs.reject { |r| gem_defines?(r[:gem], r[:path], r[:symbol]) }
    assert_empty broken.map { |r|
      "#{r[:doc]}:#{r[:line]} #{r[:gem]} #{Gem.loaded_specs[r[:gem]]&.version}: #{r[:path]} should define #{r[:symbol]}"
    }, "a gem reference names a file or symbol the RESOLVED gem does not define — the gem moved " \
       "under the document, or the document named the wrong thing"
  end

  # The check above is vacuously green on a correct document, so this proves it
  # bites: a defined symbol passes, and an undefined one, a mere CALL, and a
  # missing file each fail.
  test "the gem-symbol check rejects what the resolved gem does not define" do
    file = "app/assets/javascripts/solana_studio/wallet_transport.js"
    assert gem_defines?("solana-studio", file, "requireField"), "the check rejected a symbol the gem defines — it is over-tight"
    refute gem_defines?("solana-studio", file, "requireFieldNowhere"), "the check passed a symbol the gem never names"
    refute gem_defines?("solana-studio", file, "encodeURIComponent"), "the check passed a CALL as a definition"
    refute gem_defines?("solana-studio", "app/assets/javascripts/solana_studio/no_such_file.js", "requireField"),
           "the check passed a file the gem does not ship"
  end

  # ------------------------------------------------ what the lock resolves

  # NAMING THE LOCKED VERSION IS THE DEFECT, NOT THE NUMBER. §7 of the transport
  # document said "solana-studio 0.9.3, which Gemfile.lock resolves" — true when
  # written, false one lock bump later, and read in the present tense by every
  # agent about to reason about a private key. It had gone stale once before for
  # the same reason. A sentence like that is false the day the lock moves and
  # nothing marks it, so these documents may name a FLOOR (the Gemfile's, checked
  # below) or the release a behaviour ARRIVED in, and never what the lock holds.
  # A regex over prose catches only the phrasings it knows; the control below
  # names them, and the two sentences that actually went stale are among them.
  LOCKED_GEMS = %w[solana-studio studio-engine].freeze

  STALE_LOCK_CLAIMS = [
    "Since then\nsolana-studio **0.9.3**, which `Gemfile.lock` resolves, journals `redirectLink`",
    "installed gem the lock resolves (solana-studio **0.9.3**, studio-engine\n**0.74.7**).",
    "solana-studio **0.10.0**, tagged 2026-09-10\n00:28 MDT and not yet in our lock, takes the same four files",
    "the lock now resolves studio-engine 0.74.9"
  ].freeze

  DATED_VERSION_SENTENCES = [
    "Both arrived in **0.9.3**: one commit adds both",
    "The Gemfile floor is `>= 0.9.2`, one patch below that release",
    "the gems the lock held when this was written (solana-studio 0.9.3, studio-engine\n0.74.7)",
    "tagged 2026-09-10 00:28 MDT (our lock reached it after this was written)"
  ].freeze

  test "no wallet document says what the lock resolves" do
    claims = WALLET_DOCS.flat_map { |doc| lock_claims(File.read(abs(doc))).map { |c| c.merge(doc: doc) } }
    assert_empty claims.map { |c|
      "#{c[:doc]}: \"#{c[:text]}\" names #{c[:gem]} #{c[:version]} as locked; " \
        "Gemfile.lock resolves #{Gem.loaded_specs[c[:gem]]&.version} today"
    }, "a wallet document names the version the lock resolves. That sentence goes false on the next " \
       "bundle update and nothing marks it. Name the Gemfile's floor or the release the behaviour " \
       "arrived in instead"
  end

  test "the lock-claim check catches the sentences that went stale, and only those" do
    STALE_LOCK_CLAIMS.each do |sentence|
      refute_empty lock_claims(sentence), "the lock-claim check missed: #{sentence.inspect}"
    end
    DATED_VERSION_SENTENCES.each do |sentence|
      assert_empty lock_claims(sentence), "the lock-claim check flagged a dated or floor sentence: #{sentence.inspect}"
    end
  end

  # §7's version claim, clause by clause. The paragraph dates the gem half of
  # the redirect_link fix by the release that shipped it, names the Gemfile
  # floor, and says the turf-side default stays because the floor is below that
  # release. Each clause is re-derived here rather than trusted:
  #
  #   * the floor it names is the Gemfile's floor, to the patch;
  #   * that floor is still BELOW the release it names — the day it is not, the
  #     turf-side default is dead weight, and this goes red naming it;
  #   * the RESOLVED gem still does both things §7 says it does. A lock bump that
  #     drops either one reddens here, not in a wallet on a phone. This is the gem
  #     half of the retirement trigger;
  #     test/integration/phantom_callback_redirect_link_test.rb holds the engine half.
  #
  # Measured 2026-09-10: on the installed solana-studio 0.9.2 tree, both
  # behaviour predicates below come back false; on 0.9.3, 0.10.0 and 0.11.0,
  # both come back true. So the predicates read the code, not the lockfile.
  SECTION_SEVEN_DOC = "docs/WALLET_TRANSPORT_ARCHITECTURE.md"
  SECTION_SEVEN_ARRIVAL = Gem::Version.new("0.9.3")

  test "section 7 dates the redirect_link fix by its release, and the resolved gem still carries it" do
    text = section_text(SECTION_SEVEN_DOC, "### 7. ")
    assert text, "#{SECTION_SEVEN_DOC} has no \"### 7. \" section any more — the §7 claim moved or was deleted"
    flat = flatten_prose(text)

    arrival = flat[/Both arrived in (\d+\.\d+\.\d+)/, 1]
    said_floor = flat[/The Gemfile floor is >= (\d+\.\d+\.\d+)/, 1]
    retirement = flat[/until the floor reaches (\d+\.\d+\.\d+)/, 1]
    assert arrival, "§7 must date the fix by the release that shipped it, written **Both arrived in X.Y.Z**"
    assert said_floor, "§7 must state the Gemfile floor, written The Gemfile floor is `>= X.Y.Z`"
    assert retirement, "§7 must name the floor that retires the turf-side default"
    arrival = Gem::Version.new(arrival)
    assert_equal SECTION_SEVEN_ARRIVAL, arrival,
                 "§7 moved the fix from its verified first release, #{SECTION_SEVEN_ARRIVAL}, to #{arrival}"
    assert_equal arrival, Gem::Version.new(retirement),
                 "§7 says the turf-side default retires at #{retirement}, but dates the gem fix to #{arrival}"

    # The relation is asserted FIRST, so the day someone raises the pin the red
    # names the default to retire, not merely the sentence to edit.
    floor = gemfile_floor("solana-studio")
    assert_operator floor, :<, arrival,
                    "the Gemfile floor (#{floor}) has reached #{arrival}, the release that journals " \
                    "redirectLink. The turf-side default — the walletOps.resume wrapper in " \
                    "app/views/shared/_contest_entry_intent.html.erb — is dead weight now: retire it, " \
                    "and rewrite §7, which says it stays until this day"
    assert_equal floor, Gem::Version.new(said_floor),
                 "§7 says the Gemfile floor is >= #{said_floor}; the Gemfile's solana-studio requirement " \
                 "floors at #{floor}. Move the sentence with the pin"

    resolved = Gem.loaded_specs.fetch("solana-studio").version
    assert_operator resolved, :>=, arrival,
                    "Gemfile.lock resolves solana-studio #{resolved}, below the #{arrival} §7 says the fix arrived in"
    assert journals_redirect_link?(gem_file("solana-studio", "app/assets/javascripts/solana_studio/redirect_provider.js")),
           "solana-studio #{resolved}: beginConnect no longer journals redirectLink, so hop two can leave " \
           "without a redirect_link again, and §7's \"the gem half is fixed\" is false"
    assert refuses_missing_redirect_link?(gem_file("solana-studio", "app/assets/javascripts/solana_studio/wallet_transport.js")),
           "solana-studio #{resolved}: the connect and method URL builders no longer both refuse a " \
           "request without redirect_link, which §7 says they do"
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

  # A two-column table of `Entry#<named>` rows, each citing the DEFINITION LINE of
  # <cited> in TABLE_CONTROL_FILE. Seeded straight into the doc_lines memo under a
  # key no real document can have, so prose_unit reads it exactly as it reads a
  # real document — the rule under test is exercised, not re-implemented.
  def table_fixture(rows)
    defs = definitions(TABLE_CONTROL_FILE)
    line_of = ->(name) do
      d = defs.find { |x| x[:name] == name }
      assert d, "expected #{TABLE_CONTROL_FILE} to define #{name} — the table control is stale"
      d[:first]
    end
    key = "fixture/table-#{rows.flatten.join("-")}.md"
    lines = ["| Claim | Where |", "|---|---|"] +
            rows.map { |named, cited| "| `Entry##{named}` | `#{TABLE_CONTROL_FILE}:#{line_of.(cited)}` |" }
    (@doc_lines ||= {})[key] = lines
    rows.each_with_index.map do |(_named, cited), i|
      n = line_of.(cited)
      { doc: key, line: i + 3, raw: "#{TABLE_CONTROL_FILE}:#{n}", kind: :path,
        path: TABLE_CONTROL_FILE, ranges: [n..n] }
    end
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
  # The citations in the documents COVERAGE opts in. The per-document claims read
  # this; the three universal checks read `all_citations`. One parser, two scopes
  # — deliberately not two parsers, because the defect this file exists to catch
  # is two answers to one question.
  def citations = all_citations.select { |c| GUARDED_DOCS.include?(c[:doc]) }

  def all_citations = @all_citations ||= SCANNED_DOCS.flat_map { |doc| parse_doc(doc) }

  # THE PARSE FOR ONE DOCUMENT, reachable on a document the scope does NOT read.
  # That is what lets the inventory below count the citations in an unguarded
  # file — the count an exemption has to state — and what lets its control count
  # them in a file that does not exist until the control writes it. One parser,
  # every scope: the defect this whole file exists to catch is two answers to one
  # question, and a second counter written for the inventory would be exactly
  # that.
  def parse_doc(doc)
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
        # A URL IS NOT A CITATION. `http://localhost:3100` matches the citation shape
        # exactly — head `http://localhost`, "line" 3100 — and it is written in prose
        # all over these documents. It cost nothing while the parse read only
        # docs/workflows; the day the scope widened, two of them in
        # docs/CDP_RAMP_INTEGRATION.md were reported as citations naming a file this
        # repo does not have. A scheme separator is the tell and cannot occur in a
        # path. Skipped ENTIRELY rather than reset like an external prefix, because it
        # was never a citation and must not disturb the file context a real one set.
        next if head.include?("://")
        # Not this repo's code (EXTERNAL_PREFIXES): skip it, and let no bare
        # `:NN` after it inherit a file it cannot read.
        if EXTERNAL_PREFIXES.any? { |pre| head.start_with?(pre) }
          context = nil
          next
        end
        kind = head.empty? ? :bare : :path
        # A slash-less head is a basename cited elsewhere with its path, or a
        # file at the repo root (`playwright.config.js`) that has no path.
        path =
          if kind == :bare then context
          elsif head.include?("/") then head
          else basenames[head] || (File.file?(abs(head)) ? head : nil)
          end
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

    # A TABLE ROW IS ITS OWN UNIT — its cells, and nothing else: not a sibling
    # row, and not the header row either. A row names its symbol in one cell and
    # cites in another, and both are on this one physical line, so the row is
    # exactly the prose a reader credits the citation to. Without this, a row
    # fell through to paragraph() below and got the whole table (limit 7).
    return lines[idx] if table_row?(lines[idx])

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
  def table_row?(line) = line.to_s.lstrip.start_with?("|")
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
    # ONE PREDICATE, NOT TWO. The routes rule is reached from here rather than
    # living in its own test, so the symbol test over COVERAGE and the
    # directory-wide routes test below cannot give two answers to one question.
    return route_anchored?(citation) if citation[:path] == ROUTES_FILE

    tokens = prose_tokens(citation)
    enclosing = enclosing_names(citation)
    if enclosing.any?
      names = tokens.flat_map { |t| t.scan(/[A-Za-z_][\w]*[!?]?/) }.uniq
      return enclosing.any? { |n| names.include?(n) }
    end

    src   = source(citation[:path])
    cited = citation[:ranges].flat_map { |r| src[(r.first - 1)..(r.last - 1)] || [] }.join("\n")
    tokens.any? do |t|
      probe = t.sub(/\A[#.:]/, "").split("(").first.to_s.strip
      next false if probe.length < MIN_LITERAL_TOKEN
      next false if STOP_TOKENS.include?(probe.downcase)
      next cited.include?(probe) unless bare_word?(probe)

      # A bare word is matched WHOLE, never as a fragment: `detect` inside
      # `detectProvider` is a different word, and the looser test is what lets a
      # near-miss read as a hit.
      rx = whole_token(probe)
      cited.match?(rx) && src.count { |l| l.match?(rx) } <= MAX_BARE_WORD_LINES
    end
  end

  # Every document under docs/ that cites code and answers nothing. Read at CALL
  # time, not from DECLARATIONS, so the control can write a document and have
  # this see it — a predicate its own control cannot reach is not controlled.
  def undeclared_citing_docs
    self.class.docs_tree
        .reject { |d| self.class.declaration_for(d) }
        .select { |d| parse_doc(d).any? }
  end

  # A citation into config/routes.rb. It anchors on the FIRST cited line, which
  # is the line a route entry lives on — see the ROUTES_FILE note above. The one
  # exemption is a citation of a whole comment block, which may anchor on any of
  # its lines because the block is the unit a reader is being sent to.
  def route_anchored?(citation)
    src    = source(ROUTES_FILE)
    probes = prose_probes(citation)
    return false if probes.empty?

    lines = citation[:ranges].flat_map { |r| (r.first..r.last).to_a }
    return false if lines.empty? || lines.any? { |n| n > src.size }

    carries = ->(n) { probes.any? { |p| src[n - 1].to_s.match?(whole_token(p)) } }
    return lines.any?(&carries) if whole_comment_block?(src, lines)

    carries.call(lines.first)
  end

  # The same citation, moved by `delta` lines — what an inserted or deleted route
  # above it does to the number without anyone touching the document.
  def shift_citation(citation, delta)
    moved = citation[:ranges].map { |r| (r.first + delta)..(r.last + delta) }
    citation.merge(ranges: moved,
                   raw: "#{ROUTES_FILE}:#{moved.map { |r| r.first == r.last ? r.first : "#{r.first}-#{r.last}" }.join(", ")}")
  end

  # THE RULE THIS ONE REPLACED, kept so the control can prove the difference
  # rather than assert it: a prose token appearing ANYWHERE in the cited span,
  # by substring. It is the literal branch of `anchored?` with the routes
  # delegation taken out, and nothing but the control calls it.
  def old_literal_anchored?(citation)
    src   = source(citation[:path])
    cited = citation[:ranges].flat_map { |r| src[(r.first - 1)..(r.last - 1)] || [] }.join("\n")
    prose_probes(citation).any? { |probe| cited.include?(probe) }
  end

  def comment_line?(line) = line.to_s.strip.start_with?("#")

  # Exactly a maximal run of comment lines: every cited line is a comment, the
  # run is contiguous, and the lines on either side of it are not comments. A
  # span that merely OVERLAPS a comment block is not one — that is the shape the
  # geo citation had drifted into.
  def whole_comment_block?(src, lines)
    return false unless lines == (lines.first..lines.last).to_a
    return false unless lines.all? { |n| comment_line?(src[n - 1]) }

    above = lines.first >= 2 ? src[lines.first - 2] : nil
    below = src[lines.last]
    (above.nil? || !comment_line?(above)) && (below.nil? || !comment_line?(below))
  end

  # The probes a citation's prose offers the literal branch, and the bare-word
  # subset of them. Shared with `anchored?` so the controls test the rule rather
  # than a copy of it.
  def prose_probes(citation)
    prose_tokens(citation).filter_map do |t|
      probe = t.sub(/\A[#.:]/, "").split("(").first.to_s.strip
      next if probe.length < MIN_LITERAL_TOKEN
      next if STOP_TOKENS.include?(probe.downcase)

      probe
    end.uniq
  end

  def bare_word_probes(citation) = prose_probes(citation).select { |p| bare_word?(p) }

  # An ordinary word: letters only, no camelCase hump. Everything else — an
  # underscore, a `::`, a `#`, a dot, a hyphen, a digit, a space, a bang — is
  # structure a writer had to mean, and structure is what makes a token specific.
  def bare_word?(probe) = probe.match?(/\A[A-Za-z]+\z/) && !probe.match?(/[a-z][A-Z]/)

  def whole_token(probe) = /(?<![A-Za-z0-9_$])#{Regexp.escape(probe)}(?![A-Za-z0-9_$])/

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

  # --- the wallet documents: gems, the lock, and §7 --------------------------

  # Markdown emphasis, code spans, blockquote markers and hard wraps are
  # typography; a claim must not escape a check by being bolded, quoted, or by
  # landing on a line break.
  def flatten_prose(text) = text.gsub(/^[ \t]*>[ \t]?/, "").gsub(/[*`]/, "").gsub(/\s+/, " ")

  # The body of the section whose heading starts with `prefix`, up to the next
  # heading of the same or a higher level.
  def section_text(doc, prefix)
    lines = doc_lines(doc)
    start = lines.index { |l| l.start_with?(prefix) }
    return nil unless start
    level = prefix[/\A#+/].size
    fin = ((start + 1)...lines.size).find { |i| lines[i][/\A#+(?=\s)/].to_s.size.between?(1, level) }
    lines[start...(fin || lines.size)].join("\n")
  end

  # Every sentence shape that says which version a locked gem RESOLVES to, in
  # the present tense. The shapes are the ones the wallet documents actually
  # used; STALE_LOCK_CLAIMS is their control.
  def lock_claims(text)
    flat = flatten_prose(text)
    gem  = "(#{LOCKED_GEMS.map { |g| Regexp.escape(g) }.join('|')})"
    ver  = '(\d+\.\d+\.\d+)'
    lock = '(?:Gemfile\.lock|the lock(?:file)?|our lock(?:file)?)'
    now  = "(?:now |already |still |currently )?"
    out = []
    flat.scan(/#{gem} #{ver},? which #{lock} #{now}resolves\b/) do
      out << { gem: $1, version: $2, text: $& }
    end
    flat.scan(/#{lock} #{now}resolves\b([^)]{0,80})/) do
      said = $&
      $1.scan(/#{gem} #{ver}/) { |g, v| out << { gem: g, version: v, text: said } }
    end
    flat.scan(/#{gem} #{ver}[^.]{0,100}? not yet in (?:our|the) lock/) do
      out << { gem: $1, version: $2, text: $& }
    end
    out.uniq { |c| [c[:gem], c[:version], c[:text]] }
  end

  # The least version the Gemfile's requirement list for `name` admits, read
  # from the declaration with its comment stripped (the solana-studio line
  # carries a long floor note that must not vote).
  def gemfile_floor(name)
    decl = Rails.root.join("Gemfile").read[/^\s*gem\s+["']#{Regexp.escape(name)}["'].*$/]
    assert decl, "no gem #{name.inspect} line in the Gemfile"
    reqs = decl.sub(/#.*/, "").scan(/["']([^"']+)["']/).flatten.drop(1)
    Gem::Requirement.new(reqs).requirements.filter_map { |op, v| v if %w[>= ~> =].include?(op) }.max
  end

  def gem_file(gem, path)
    File.read(File.join(Gem.loaded_specs.fetch(gem).full_gem_path, path))
  end

  def gem_references
    @gem_references ||= SCANNED_DOCS.flat_map do |doc|
      doc_lines(doc).each_with_index.flat_map do |line, i|
        line.scan(GEM_REF).flat_map do |gem, path, symbols|
          symbols.split(",").map { |sym| { doc: doc, line: i + 1, gem: gem, path: path, symbol: sym } }
        end
      end
    end
  end

  # Whether the RESOLVED gem's file DEFINES `symbol` — a definition, not a
  # mention: Ruby def/class/module; JS `function name(`, `var name =`, a
  # `name: function` member, or a `name(args) {` / `get name() {` shorthand.
  def gem_defines?(gem, path, symbol)
    spec = Gem.loaded_specs[gem]
    file = spec && File.join(spec.full_gem_path, path)
    return false unless file && File.file?(file)
    s = Regexp.escape(symbol)
    src = File.read(file)
    if path.end_with?(".rb")
      src.match?(/\b(?:def|class|module)\s+(?:self\.)?#{s}(?![\w!?])/)
    else
      src.match?(/^\s*(?:(?:async\s+)?function\s+#{s}\s*\(|(?:var|let|const)\s+#{s}\s*=|(?:async\s+|get\s+)?#{s}\s*\([^)]*\)\s*\{|#{s}\s*:\s*(?:async\s+)?function\b)/)
    end
  end

  # The text of a JS `name: function (...) {` member or `function name(...) {`,
  # found by brace balance like erb_js_definitions above.
  def js_member_body(src, name)
    n = Regexp.escape(name)
    lines = src.lines
    start = lines.index { |l| l.match?(/^\s*(?:#{n}\s*:\s*(?:async\s+)?function\b|(?:async\s+)?function\s+#{n}\s*\()/) }
    return nil unless start
    depth = 0
    (start...lines.size).each do |j|
      depth += lines[j].count("{") - lines[j].count("}")
      return lines[start..j].join if depth <= 0
    end
    nil
  end

  # §7, clause one: beginConnect writes redirectLink into the JOURNAL it returns,
  # not merely into the URL it builds — the journal is what survives the page
  # death and reaches hop two.
  def journals_redirect_link?(redirect_provider_src)
    body = js_member_body(redirect_provider_src, "beginConnect").to_s
    journal = body[/journal:\s*newJournal\((.*?)\}\s*\)/m, 1]
    journal.to_s.match?(/\bredirectLink\s*:/)
  end

  # §7, clause two: BOTH URL builders refuse a request with no redirect_link.
  def refuses_missing_redirect_link?(wallet_transport_src)
    wallet_transport_src.match?(/function requireField\s*\(/) &&
      %w[connect method].all? do |member|
        js_member_body(wallet_transport_src, member).to_s
          .match?(/requireField\([^;]*redirectLink[^;]*'redirect_link'/)
      end
  end
end
