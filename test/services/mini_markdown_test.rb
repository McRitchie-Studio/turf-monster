require "test_helper"

# [unit] The Markdown subset behind /agents/guide.
#
# Two things are held here: each construct renders as the element it should,
# and anything outside the subset is REFUSED rather than passed through as
# literal text. The second is the one that matters. The guide is served twice
# from one source, and the only way the two can part company is the page
# showing raw Markdown the plain-text twin renders fine.
class MiniMarkdownTest < ActiveSupport::TestCase
  def html(source)
    Nokogiri::HTML.fragment(MiniMarkdown.to_html(source))
  end

  test "headings carry ids a section link can target" do
    doc = html("# Title\n\n## How to win\n\n### `GET /api/v1/me`\n")

    assert_equal "Title", doc.at_css("h1").text
    assert_equal "how-to-win", doc.at_css("h2")["id"]
    assert_equal "get-apiv1me", doc.at_css("h3")["id"]
    assert_equal "GET /api/v1/me", doc.at_css("h3 code").text
  end

  test "a repeated heading gets its own id" do
    ids = MiniMarkdown.headings("## Errors\n\n## Errors\n").map(&:id)

    assert_equal %w[errors errors-2], ids
    assert_equal ids, html("## Errors\n\n## Errors\n").css("h2").map { |node| node["id"] }
  end

  test "headings lists what the page renders, and skips a # inside a code fence" do
    source = "# One\n\n```bash\n# not a heading\n```\n\n## Two\n"

    assert_equal [ [ 1, "One", "one" ], [ 2, "Two", "two" ] ], MiniMarkdown.headings(source).map(&:to_a)
    assert_equal 2, html(source).css("h1, h2").size
  end

  test "consecutive lines are one paragraph and a blank line starts another" do
    doc = html("first line\nsecond line\n\nthird\n")

    assert_equal [ "first line second line", "third" ], doc.css("p").map(&:text)
  end

  test "lists, with a continuation line folded into its item" do
    doc = html("- one\n  more of one\n- two\n\n1. first\n2. second\n")

    assert_equal [ "one more of one", "two" ], doc.css("ul li").map(&:text)
    assert_equal %w[first second], doc.css("ol li").map(&:text)
  end

  test "a code fence keeps its text exactly, escaped, and scrolls in its own box" do
    doc = html("```json\n{ \"a\": \"<b> & **not bold**\" }\n  indented\n```\n")
    pre = doc.at_css("pre")

    assert_equal "{ \"a\": \"<b> & **not bold**\" }\n  indented", pre.text
    assert_equal "json", pre["data-language"]
    assert_includes pre["class"], "overflow-x-auto"
    assert_nil doc.at_css("pre b"), "markup inside a fence must stay text"
    assert_nil doc.at_css("pre strong")
  end

  test "a table renders header and rows inside a scrolling wrapper" do
    doc = html("| Code | Meaning |\n|---|---|\n| `a_b` | first |\n| `c` | a `x | y` pipe in code |\n")

    assert_equal %w[Code Meaning], doc.css("th").map(&:text)
    assert_equal [ [ "a_b", "first" ], [ "c", "a x | y pipe in code" ] ],
                 doc.css("tbody tr").map { |row| row.css("td").map(&:text) }
    assert_includes doc.at_css("table").parent["class"], "overflow-x-auto"
  end

  test "inline code, bold and links" do
    doc = html("Send `allow_usdc` **only** when told. See [How to win](#how-to-win) or [terms](https://example.test/terms).\n")

    assert_equal "allow_usdc", doc.at_css("p code").text
    assert_equal "only", doc.at_css("p strong").text
    assert_equal [ "#how-to-win", "https://example.test/terms" ], doc.css("p a").map { |a| a["href"] }
    # A section link is the browser's to follow, not Turbo's; any other link is not marked.
    assert_equal [ "false", nil ], doc.css("p a").map { |a| a["data-turbo"] }
  end

  test "bold may wrap a code span" do
    doc = html("- **One entry, one `Idempotency-Key`.** Reuse it.\n")

    assert_equal "One entry, one Idempotency-Key.", doc.at_css("li strong").text
    assert_equal "Idempotency-Key", doc.at_css("li strong code").text
  end

  test "prose is escaped, and emphasis markers inside code are left alone" do
    doc = html("Use `Bearer <key>` & `**kwargs` < here\n")

    assert_equal "Use Bearer <key> & **kwargs < here", doc.at_css("p").text
    assert_nil doc.at_css("key")
    assert_nil doc.at_css("strong")
  end

  # ── Refusals ────────────────────────────────────────────────────────────────

  {
    "a block quote" => "> quoted\n",
    "an image" => "![alt](/x.png)\n",
    "raw HTML" => "<div>hello</div>\n",
    "an indented code block" => "text\n\n    indented code\n",
    "an unclosed fence" => "```json\n{}\n",
    "an unclosed bold" => "a **b\n",
    "an unbalanced backtick" => "a `b\n",
    "a table without its rule" => "| a | b |\n| 1 | 2 |\n",
    "a table row with a stray cell" => "| a | b |\n|---|---|\n| 1 | 2 | 3 |\n",
    "a link to another scheme" => "[x](javascript:alert(1))\n",
    "a plain http link" => "[x](http://example.test)\n"
  }.each do |what, source|
    test "refuses #{what}" do
      assert_raises(MiniMarkdown::Unsupported) { MiniMarkdown.to_html(source) }
    end
  end
end
