# Renders the SUBSET of Markdown the agent guide is written in, as HTML.
#
# WHY THIS EXISTS. The agent guide has two readers and must have one source: an
# LLM reads it as plain Markdown at /agents/guide.md, and a person reads the same
# text as a page at /agents/guide. The source is Markdown (the form the agent
# needs verbatim); this turns that same string into the page, so the two cannot
# say different things. The app carries no Markdown gem, and one page does not
# earn one.
#
# WHAT IT UNDERSTANDS, and nothing else:
#
#   # .. ####  headings (each gets an id, so the page can link to a section)
#   paragraphs  consecutive text lines, joined
#   - item      unordered lists, one level; a continuation line is indented
#   1. item     ordered lists, one level
#   ```lang     fenced code blocks
#   | a | b |   tables with a header row and a |---| separator
#   `code`  **bold**  [text](url)  inline
#
# IT REFUSES WHAT IT DOES NOT UNDERSTAND. A block quote, an image, an indented
# code block, a table row with the wrong number of cells, an unclosed fence, a
# link to anything but this site, https or mailto: each raises Unsupported rather
# than passing through as literal text. A page that silently showed raw Markdown
# would be the two readers drifting apart in the one way a test of the SOURCE
# cannot see, so the failure is loud and test/services/mini_markdown_test.rb
# renders the real guide through it.
#
# Everything is HTML-escaped before any tag is added; the source is ours, but a
# JSON example full of angle brackets and ampersands has to survive either way.
class MiniMarkdown
  class Unsupported < StandardError; end

  Heading = Struct.new(:level, :text, :id)

  HEADING = /\A(\#{1,4}) (\S.*)\z/
  FENCE = /\A```(\w*)\z/
  BULLET = /\A- (\S.*)\z/
  NUMBERED = /\A\d+\. (\S.*)\z/
  TABLE_ROW = /\A\|.*\|\z/
  TABLE_RULE = /\A\|(\s*:?-{3,}:?\s*\|)+\z/
  LINK = /\[([^\]]+)\]\(([^)\s]+)\)/
  LINK_TARGET = %r{\A(?:/|#|https://|mailto:)}
  REFUSED = /\A(?:>|!\[|\t| {4,}\S|<)/

  HEADING_CLASSES = {
    1 => "text-3xl md:text-4xl font-extrabold text-heading mb-4",
    2 => "text-2xl font-bold text-heading mt-12 mb-4 scroll-mt-24",
    3 => "text-lg font-bold text-heading mt-8 mb-3 scroll-mt-24 break-words",
    4 => "text-base font-semibold text-heading mt-6 mb-2 scroll-mt-24"
  }.freeze

  def self.to_html(source)
    new(source).to_html
  end

  # Every heading, in order, with the id its element carries on the page.
  def self.headings(source)
    new(source).headings
  end

  def initialize(source)
    @lines = source.to_s.lines.map(&:chomp)
    @ids = Hash.new(0)
  end

  def headings
    in_fence = false
    ids = Hash.new(0)
    @lines.filter_map do |line|
      in_fence = !in_fence if line.match?(FENCE)
      next if in_fence
      next unless (match = line.match(HEADING))

      Heading.new(match[1].size, plain(match[2]), unique_id(match[2], ids))
    end
  end

  def to_html
    out = []
    index = 0
    while index < @lines.size
      line = @lines[index]
      if line.strip.empty?
        index += 1
      elsif (match = line.match(FENCE))
        index = fence(out, index, match[1])
      elsif (match = line.match(HEADING))
        out << heading(match[1].size, match[2])
        index += 1
      elsif line.match?(TABLE_ROW)
        index = table(out, index)
      elsif line.match?(BULLET) || line.match?(NUMBERED)
        index = list(out, index, ordered: line.match?(NUMBERED))
      else
        index = paragraph(out, index)
      end
    end
    out.join("\n").html_safe
  end

  private

  def refuse!(what, line)
    raise Unsupported, "#{what}: #{line.inspect}"
  end

  def block_start?(line)
    line.strip.empty? || line.match?(FENCE) || line.match?(HEADING) || line.match?(TABLE_ROW) ||
      line.match?(BULLET) || line.match?(NUMBERED)
  end

  def fence(out, index, language)
    body = []
    index += 1
    until index >= @lines.size || @lines[index].match?(/\A```\z/)
      body << @lines[index]
      index += 1
    end
    refuse!("unclosed code fence", "```#{language}") if index >= @lines.size

    label = language.empty? ? "" : %( data-language="#{h(language)}")
    out << %(<pre class="bg-inset border border-subtle rounded-lg p-3 my-4 overflow-x-auto text-xs leading-relaxed"#{label}>) +
           %(<code class="font-mono text-body">#{h(body.join("\n"))}</code></pre>)
    index + 1
  end

  def heading(level, text)
    id = unique_id(text, @ids)
    %(<h#{level} id="#{id}" class="#{HEADING_CLASSES.fetch(level)}">#{inline(text)}</h#{level}>)
  end

  def table(out, index)
    rows = []
    while index < @lines.size && @lines[index].match?(TABLE_ROW)
      rows << @lines[index]
      index += 1
    end
    refuse!("table without a |---| rule under its header", rows.first) unless rows.size >= 2 && rows[1].match?(TABLE_RULE)

    header = cells(rows.first)
    body = rows.drop(2).map do |row|
      row_cells = cells(row)
      refuse!("table row with #{row_cells.size} cells under #{header.size} headings", row) unless row_cells.size == header.size
      row_cells
    end

    head_html = header.map { |cell| %(<th class="px-3 py-2 text-left text-xs font-semibold text-muted uppercase tracking-wider align-bottom">#{inline(cell)}</th>) }.join
    body_html = body.map do |row_cells|
      "<tr>" + row_cells.map { |cell| %(<td class="px-3 py-2 align-top text-body">#{inline(cell)}</td>) }.join + "</tr>"
    end.join("\n")

    out << %(<div class="card overflow-x-auto my-4"><table class="w-full text-sm">) +
           %(<thead><tr class="border-b border-subtle">#{head_html}</tr></thead>) +
           %(<tbody class="divide-y divide-subtle">#{body_html}</tbody></table></div>)
    index
  end

  # A cell may hold a pipe only inside a code span; split around those.
  def cells(row)
    inner = row[1..-2]
    parts = [ +"" ]
    in_code = false
    inner.each_char do |char|
      in_code = !in_code if char == "`"
      if char == "|" && !in_code
        parts << +""
      else
        parts.last << char
      end
    end
    parts.map(&:strip)
  end

  def list(out, index, ordered:)
    marker = ordered ? NUMBERED : BULLET
    items = []
    while index < @lines.size
      line = @lines[index]
      if (match = line.match(marker))
        items << match[1].dup
      elsif line.match?(/\A {2,3}\S/) && items.any?
        items.last << " " << line.strip
      else
        break
      end
      index += 1
    end

    tag = ordered ? "ol" : "ul"
    style = ordered ? "list-decimal" : "list-disc"
    out << %(<#{tag} class="#{style} pl-5 space-y-2 my-4 text-body leading-relaxed">) +
           items.map { |item| "<li>#{inline(item)}</li>" }.join + "</#{tag}>"
    index
  end

  def paragraph(out, index)
    refuse!("not in the supported subset", @lines[index]) if @lines[index].match?(REFUSED)

    text = []
    while index < @lines.size && !block_start?(@lines[index])
      refuse!("not in the supported subset", @lines[index]) if @lines[index].match?(REFUSED)
      text << @lines[index].strip
      index += 1
    end
    out << %(<p class="text-body leading-relaxed my-4">#{inline(text.join(" "))}</p>)
    index
  end

  # Code spans first, so nothing inside one is read as bold or a link.
  def inline(text)
    refuse!("unbalanced backtick", text) if text.count("`").odd?

    @bold_open = false
    html = text.split(/(`[^`]*`)/).map do |part|
      if part.start_with?("`") && part.end_with?("`") && part.size >= 2
        %(<code class="font-mono text-[0.85em] bg-inset rounded px-1 py-0.5 text-heading break-words">#{h(part[1..-2])}</code>)
      else
        prose(part)
      end
    end.join
    refuse!("unclosed ** emphasis", text) if @bold_open
    html
  end

  # `**` toggles, so bold may wrap a code span: **one `Idempotency-Key`**.
  def prose(text)
    html = h(text).gsub("**") do
      @bold_open = !@bold_open
      @bold_open ? %(<strong class="text-heading font-semibold">) : "</strong>"
    end

    html.gsub(LINK) do
      label = Regexp.last_match(1)
      target = CGI.unescapeHTML(Regexp.last_match(2))
      refuse!("link target outside this site, https or mailto", target) unless target.match?(LINK_TARGET)
      %(<a href="#{h(target)}" class="text-primary hover:underline break-words">#{label}</a>)
    end
  end

  def plain(text)
    text.delete("`").gsub("**", "").gsub(LINK) { Regexp.last_match(1) }
  end

  def unique_id(text, seen)
    base = plain(text).downcase.gsub(/[^a-z0-9\s-]/, "").strip.gsub(/\s+/, "-")
    base = "section" if base.empty?
    seen[base] += 1
    seen[base] == 1 ? base : "#{base}-#{seen[base]}"
  end

  def h(text)
    ERB::Util.html_escape(text)
  end
end
