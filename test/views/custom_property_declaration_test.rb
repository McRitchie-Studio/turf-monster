require "test_helper"
require "tmpdir"

# EVERY CUSTOM PROPERTY A VIEW READS MUST BE WRITTEN SOMEWHERE.
#
# An undefined custom property makes the whole declaration invalid at
# computed-value time. `background: var(--nope)` paints NOTHING — the element
# is transparent and shows whatever is behind it — and `border: 2px dashed
# var(--nope)` drops the entire shorthand, so there is no border at all. The
# page does not error; it silently renders one layer short.
#
# FIVE SUCH NAMES SHIPPED, and all five are a Tailwind UTILITY name written as
# if it were a custom property. The utility `bg-surface` reads `--color-surface`
# — `bg-` is a utility PREFIX, never part of the variable — so `--color-bg-surface`
# names nothing. Measured 2026-09-22 on origin/accepted:
#
#   --color-bg-surface     10 reads  (admin forms, seeds_lab)  <- `bg-surface`
#   --color-text-primary    5 reads  (the same lines)          <- `text-primary`
#   --bg-page               1 read   (contests/_hero avatar)   <- `bg-page`
#   --color-border-subtle   1 read   (admin/navbar preview)    <- `border-subtle`
#   --color-subtle          1 read   (accounts referral slots) <- `border-subtle`
#
# WHY THIS IS A SEPARATE FILE from violet_text_contrast_test.rb, which already
# walks inline styles: that file's lanes are structurally unable to see two of
# the ten. `parse_elements` blanks every `<% %>` before scanning, and
# TAG_HELPER_STYLE needs a literal `style: `, so a Ruby local —
# `<% field_style = "background: var(--color-bg-surface)" %>` in
# admin/landing_pages/_form and admin/entry_gifts/index — reaches neither lane.
# This guard reads TEXT rather than elements, so a string literal counts.
#
# It also asks a different question. That file measures CONTRAST and therefore
# needs a resolved colour; an unresolvable name returns nil from `static_color`
# and is SKIPPED rather than failed, which is exactly how these five survived.
# This guard asks only whether the NAME resolves, so it needs no colour at all.
class CustomPropertyDeclarationTest < ActiveSupport::TestCase
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze

  # Where a view may read a custom property from.
  READ_ROOTS = %w[app/views app/helpers app/assets/tailwind].freeze

  # Where one may be WRITTEN. The engine is a first-class source: it sets
  # --nav-h and --nav-bottom from layouts/studio/_head, and the fizz layer's
  # --ft/--fd from Studio::FizzHelper, none of which this repo declares.
  ENGINE_ROOT = Pathname(Studio::Engine.root).freeze
  WRITE_ROOTS = %w[app lib config].freeze

  # A read whose name is built at render time — `var(--bench-<%= line.key %>)`
  # in the benchmarks charts. The concrete names ARE declared (benchmarks/index
  # writes --bench-full and --bench-bye); only the spelling is dynamic, so there
  # is no static name to check. Asserted non-empty below so that "the dynamic
  # form stopped appearing" cannot quietly widen into "nothing is scanned".
  DYNAMIC_READ = /var\(\s*--[\w-]*<%/

  # The SAME read, matched as a whole `var(...)` call so it can be blanked out
  # of a line rather than costing the line. `DYNAMIC_READ` above matches only
  # the opening, which is all the vacuity control needs to COUNT these; `reads`
  # needs the closing paren too, so that what it removes is exactly the dynamic
  # call and every static sibling on that line is still scanned.
  DYNAMIC_READ_CALL = /var\(\s*--[\w-]*<%.*?%>[^)]*\)/

  # A read this file has measured and deliberately allows, with the reason.
  # EMPTY, and that is the claim: every name a view reads today is written
  # somewhere. A new entry here needs a measured reason, the same doctrine as
  # violet_text_contrast_test.rb's allow-lists.
  ALLOWED_UNWRITTEN = {}.freeze

  # A read pinned so the scanner cannot go blind and pass vacuously.
  PINNED_READ = [ "app/views/seeds_lab/index.html.erb", "--color-cta" ].freeze

  # The five names this task retired. None may come back as a writer either —
  # declaring one would make the typo legal and the guard toothless.
  RETIRED = %w[--color-bg-surface --color-text-primary --bg-page
               --color-border-subtle --color-subtle].freeze

  # ERB comments are stripped: `<%# ... %>` never reaches the browser, so a
  # name quoted in one is prose, not a read. accounts/confirm_email_change
  # quotes the engine's `var(--btn-primary-fg, #fff)` contract in exactly that
  # way. HTML comments are NOT stripped — they are served, and a `var()` inside
  # one is still shipped text.
  #
  # THE BLANKING PRESERVES NEWLINES, so a multi-line `<%# %>` does not shift
  # every line number below it. Reporting a read at the wrong line sends the
  # next reader to innocent markup, which is how a guard gets distrusted.
  def readable_source(text) = text.gsub(/<%#.*?%>/m) { |m| "\n" * m.count("\n") }

  def source_files(root, exts)
    Dir[Pathname(root).join("**/*.{#{exts}}")].reject { |p| p.include?("assets/builds") }.sort
  end

  # Every name read through `var()`, by file:line.
  def reads
    @reads ||= Hash.new { |h, k| h[k] = [] }.tap do |out|
      READ_ROOTS.each do |root|
        source_files(Rails.root.join(root), "erb,rb,css,js").each do |path|
          rel = Pathname(path).relative_path_from(Rails.root).to_s
          readable_source(File.read(path)).each_line.with_index do |line, i|
            # BLANK THE DYNAMIC READ, DO NOT SKIP ITS LINE. Skipping the whole
            # line made every OTHER `var()` on it invisible, and one line in
            # this repo carries both: `benchmarks/_two_line_svg.html.erb:82`
            # reads `var(--bench-<%= line.key %>)` and `var(--color-surface)`
            # in the same tag. Measured 2026-09-22 — a retired name planted as
            # that second read passed the whole suite, `control: the retired
            # utility-shaped names are still written nowhere` included, because
            # the read never entered this hash for either test to see.
            scannable = line.gsub(DYNAMIC_READ_CALL, "")
            scannable.scan(/var\(\s*(--[\w-]+)\s*[,)]/).flatten.each { |name| out[name] << "#{rel}:#{i + 1}" }
          end
        end
      end
    end
  end

  # Every name written anywhere that can reach a page: the compiled stylesheet,
  # the runtime theme block, this repo's source, and the engine's.
  def writers
    @writers ||= begin
      texts = [ COMPILED_CSS.read, Studio::ThemeResolver.new(ThemeSetting.current.resolved_colors).to_css ]
      WRITE_ROOTS.each do |root|
        [ Rails.root.join(root), ENGINE_ROOT.join(root) ].each do |base|
          next unless base.exist?

          source_files(base, "erb,rb,css,js").each { |p| texts << File.read(p) }
        end
      end
      texts.flat_map do |text|
        text.scan(/(--[\w-]+)\s*:/).flatten + text.scan(/setProperty\(\s*["'](--[\w-]+)["']/).flatten
      end.to_set
    end
  end

  test "every custom property a view reads is written somewhere" do
    assert COMPILED_CSS.exist?, "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` first"

    orphans = reads.keys.reject { |n| writers.include?(n) || ALLOWED_UNWRITTEN.key?(n) }.sort

    assert_empty orphans.map { |n| "#{n} (#{reads[n].first(3).join(', ')})" },
                 "these custom properties are READ but written nowhere — not in the compiled stylesheet, not by " \
                 "Studio::ThemeResolver, not in this repo, not in studio-engine. An undefined custom property " \
                 "makes the whole declaration invalid, so each of these paints NOTHING. Check whether the name " \
                 "is a Tailwind utility written as a variable: `bg-surface` reads --color-surface, not " \
                 "--color-bg-surface."
  end

  # VACUITY GUARD ONE: the read scan still finds real reads. Without this, a
  # regex that stopped matching would leave the test above asserting nothing.
  test "control: the read scan still sees a known real read" do
    path, name = PINNED_READ
    assert_includes reads.fetch(name, []).map { |site| site.split(":").first }, path,
                    "#{path} no longer registers a `var(#{name})` read, so the scan above may be finding nothing"
    assert_operator reads.size, :>=, 40,
                    "only #{reads.size} distinct custom properties are read across #{READ_ROOTS.join(', ')}; " \
                    "63 were read when this was written, so the scanner has probably narrowed"

    dynamic = READ_ROOTS.sum do |root|
      source_files(Rails.root.join(root), "erb,rb,css,js").sum do |p|
        readable_source(File.read(p)).each_line.count { |l| l.match?(DYNAMIC_READ) }
      end
    end
    assert_operator dynamic, :>, 0,
                    "no dynamically-named `var(--prefix-<%= ... %>)` read is left, so DYNAMIC_READ is now " \
                    "excluding nothing; drop it rather than leaving a blind spot with no reason to exist"
  end

  # VACUITY GUARD TWO: the writer index has not gone so broad that it would
  # accept anything. The five retired names must still be absent from it — if
  # one were ever declared, the typo would resolve and this guard would stop
  # being able to tell a real token from a utility name.
  test "control: the retired utility-shaped names are still written nowhere" do
    RETIRED.each do |name|
      refute_includes writers, name,
                      "#{name} is now WRITTEN somewhere. It is a Tailwind utility name, not a token — declaring " \
                      "it makes every mis-spelled read resolve and this guard stops biting. Remove the " \
                      "declaration, or retire this name from RETIRED with a measured reason."
      assert_empty reads.fetch(name, []),
                   "#{name} is read again at #{reads.fetch(name, []).join(', ')}; it resolves to nothing"
    end
  end

  # CONTROL: a planted undeclared read is actually caught. Planted in a TMPDIR
  # rather than under app/views, because a fixture written into a scanned
  # directory is read by the sibling forks CI runs this suite in.
  test "control: the scanner finds a planted undeclared read and passes a declared one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "planted.html.erb")

      File.write(path, %(<div style="background: var(--color-bg-surface);"></div>\n))
      found = readable_source(File.read(path)).scan(/var\(\s*(--[\w-]+)\s*[,)]/).flatten
      assert_equal [ "--color-bg-surface" ], found, "the read scanner no longer finds a planted `var()` in a style attribute"
      refute_includes writers, found.first, "the planted name is written somewhere, so this control cannot fail"

      # A Ruby LOCAL, which is the form violet_text_contrast_test.rb cannot see.
      File.write(path, %(<% field_style = "background: var(--color-bg-surface);" %>\n))
      assert_equal [ "--color-bg-surface" ],
                   readable_source(File.read(path)).scan(/var\(\s*(--[\w-]+)\s*[,)]/).flatten,
                   "a `var()` inside an ERB-assigned Ruby local is no longer scanned — that is two of this " \
                   "task's ten sites"

      # And the declared form is NOT a finding, so the guard is not just
      # failing on everything.
      File.write(path, %(<div style="background: var(--color-surface);"></div>\n))
      declared = readable_source(File.read(path)).scan(/var\(\s*(--[\w-]+)\s*[,)]/).flatten
      assert_includes writers, declared.first,
                      "--color-surface is not in the writer index, so the guard would red on correct code too"
    end
  end

  # CONTROL: A DYNAMIC READ COSTS ONLY ITSELF, NOT ITS WHOLE LINE.
  #
  # `reads` used to `next` past any line matching DYNAMIC_READ, so a static
  # `var()` sharing that line was never scanned. This is not hypothetical:
  # `benchmarks/_two_line_svg.html.erb:82` reads `var(--bench-<%= line.key %>)`
  # and `var(--color-surface)` in one tag, and a retired name planted as that
  # second read passed the entire suite — this file's RETIRED control included,
  # because the name never entered `reads` for it to find.
  #
  # Asserted on the real line rather than a fixture, so that the line moving or
  # losing its dynamic read is a visible failure rather than a quiet one.
  test "control: a static var() sharing a line with a dynamic one is still scanned" do
    mixed = %(  r="<%= dot_r %>" fill="var(--bench-<%= line.key %>)" stroke="var(--color-surface)"\n)

    assert_match DYNAMIC_READ, mixed, "the fixture no longer contains a dynamic read, so it tests nothing"
    assert_equal [ "--color-surface" ],
                 mixed.gsub(DYNAMIC_READ_CALL, "").scan(/var\(\s*(--[\w-]+)\s*[,)]/).flatten,
                 "blanking the dynamic call must leave the static sibling — and must not leave the dynamic " \
                 "name itself, which has no static spelling to check"

    live = reads.fetch("--color-surface", [])
    assert_includes live, "app/views/benchmarks/_two_line_svg.html.erb:82",
                    "the live mixed-read line is no longer registering its static `var(--color-surface)`. " \
                    "Either the line moved — re-pin it — or `reads` is skipping whole lines again, which is " \
                    "the blind spot this control exists to hold closed."
  end
end
