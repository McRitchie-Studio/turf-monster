require "test_helper"

# [component] + [integration] The agent pages: /agents, /agents/guide, its
# Markdown twin, and /llms.txt.
#
# What a server test can hold: the pages are public, the prompt on the page is
# the prompt the copy button carries, the two forms of the guide are one text,
# and the things these pages must never say are not said. That a tap really
# reaches the clipboard, and that nothing scrolls sideways on a phone, are
# e2e/agents_pages.spec.js.
class AgentsControllerTest < ActionDispatch::IntegrationTest
  # What a real key looks like. Nothing shaped like one may appear on any page.
  REAL_KEY_SHAPE = /tmk_[A-Za-z0-9]{#{ApiKey::TOKEN_LENGTH}}/
  # A user agent `allow_browser` would answer 406: what an LLM's fetch tool sends.
  AGENT_UA = { "User-Agent" => "python-requests/2.32" }.freeze
  PATHS = %w[/agents /agents/guide /agents/guide.md /llms.txt].freeze

  def guide_markdown
    get agents_guide_markdown_path
    response.body
  end

  def page_text(selector)
    Nokogiri::HTML(response.body).at_css(selector).text.gsub(/\s+/, " ").strip
  end

  # ── Public, to people and to programs ───────────────────────────────────────

  PATHS.each do |path|
    test "#{path} answers a signed-out program's user agent" do
      get path, headers: AGENT_UA

      assert_response :success
    end

    test "#{path} shows no key-shaped string and no connector address" do
      get path

      assert_no_match REAL_KEY_SHAPE, response.body
      # The MCP endpoint is not built. A page naming one sends an agent to a 404.
      assert_no_match(%r{/mcp\b}i, response.body.gsub(%r{<(script|style)\b.*?</\1>}m, ""))
    end
  end

  test "a browser that allow_browser would refuse elsewhere still gets the pages" do
    old_safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4"

    get agents_path, headers: { "User-Agent" => old_safari }
    assert_response :success
  end

  # ── The human page ──────────────────────────────────────────────────────────

  test "/agents leads with the starter prompt, and the copy button carries the same text" do
    get agents_path
    doc = Nokogiri::HTML(response.body)
    page = doc.at_css('[data-test="agents-page"]')

    shown = page.at_css('[data-test="starter-prompt"]').text
    copied = page.at_css('[data-test="starter-prompt-copy"] button')["data-copy-text"]
    assert_equal shown.strip, copied.strip
    assert_operator shown.length, :>, 800

    # First things first: the prompt comes before the steps and the table.
    order = page.css("h1, h2").map(&:text)
    assert_equal "Starter prompt", order[1]
    assert_operator order.index("Starter prompt"), :<, order.index("Three steps")
  end

  test "the starter prompt says what a cold model needs" do
    get agents_path
    prompt = Nokogiri::HTML(response.body).at_css('[data-test="starter-prompt"]').text
    host = TurfMonster::HostConfig::DEFAULT_APP_HOST

    assert_includes prompt, "https://#{host}/agents/guide.md"
    assert_includes prompt, "https://#{host}/api/v1"
    assert_includes prompt, "Authorization: Bearer"
    assert_includes prompt, "[PASTE YOUR API KEY HERE]"
    assert_includes prompt, "GET /api/v1/me"
    assert_includes prompt, "Idempotency-Key"
    assert_includes prompt, "allow_usdc"
    assert_match(/before you submit anything/i, prompt)
    assert_no_match(/localhost|127\.0\.0\.1|example\.com/, prompt)
    # Prose to a colleague, not a wall of capitals: the only shouting allowed is
    # the placeholder and the names the API itself spells in capitals.
    shouted = prompt.scan(/\b[A-Z]{4,}\b/).uniq - %w[PASTE YOUR HERE USDC]
    assert_empty shouted
  end

  test "/agents has three steps, a link to the account page and the guide, and the short table" do
    get agents_path
    doc = Nokogiri::HTML(response.body).at_css('[data-test="agents-page"]')

    assert_equal 3, doc.css("ol > li").size
    assert doc.at_css(%(a[href="#{account_path}"])), "the key step links to the account page"
    assert doc.at_css(%(a[href="#{agents_guide_path}"]))
    assert doc.at_css(%(a[href="#{agents_guide_markdown_path}"]))
    assert doc.at_css(%(a[href="#{terms_path}"]))

    rows = doc.css('[data-test="agents-endpoints"] tbody tr')
    assert_operator rows.size, :>=, 6
    assert_includes rows.map { |row| row.at_css("td").text }, "POST /api/v1/contests/:slug/entries"
    assert_includes doc.text, "#{(ApiKey::LIFETIME / 1.day).to_i} days"
  end

  test "/agents carries a title and a description" do
    get agents_path

    assert_select "title", /Play with your AI assistant/
    assert_select 'meta[name="description"][content*="starter prompt"]'
  end

  test "the footer links to /agents from another page" do
    get terms_path

    assert_select "footer a[href=?]", agents_path
  end

  # ── One guide, two forms ────────────────────────────────────────────────────

  test "the Markdown twin is served as text/markdown, with no layout around it" do
    get agents_guide_markdown_path

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_equal "utf-8", response.charset
    assert response.body.start_with?("# Turf Monster agent guide\n")
    assert_no_match(/<html|<body|<nav/i, response.body)
    assert_no_match(/<%|%>/, response.body, "an ERB tag reached the output")
  end

  test "the page and the Markdown say the same thing, section for section" do
    markdown = guide_markdown
    get agents_guide_path
    assert_response :success
    doc = Nokogiri::HTML(response.body).at_css('[data-test="agent-guide"] article')

    headings = MiniMarkdown.headings(markdown)
    assert_operator headings.size, :>, 30
    assert_equal headings.map(&:text), doc.css("h1, h2, h3, h4").map(&:text)
    assert_equal headings.map(&:id), doc.css("h1, h2, h3, h4").map { |node| node["id"] }

    # Every code example, byte for byte: these are what an agent copies.
    fences = markdown.scan(/^```\w*\n(.*?)\n```$/m).flatten
    assert_operator fences.size, :>, 15
    assert_equal fences, doc.css("pre").map(&:text)

    # And every table row made it across with all of its cells.
    markdown_rows = markdown.lines.count { |line| line.start_with?("|") && !line.match?(/\A\|[-|: ]+\|\s*\z/) }
    assert_equal markdown_rows, doc.css("tr").size
  end

  test "the page shows no raw Markdown" do
    get agents_guide_path
    text = Nokogiri::HTML(response.body).at_css('[data-test="agent-guide"] article')
    text.css("pre, code").each(&:remove)

    assert_no_match(/\*\*|```|^\#{1,4} |\]\(|^\|/, text.text)
  end

  test "every section link on the page has a section to land on" do
    get agents_guide_path
    doc = Nokogiri::HTML(response.body).at_css('[data-test="agent-guide"]')
    targets = doc.css('a[href^="#"]').map { |a| a["href"].delete_prefix("#") }

    assert_operator targets.size, :>, 15
    targets.each { |id| assert doc.at_css(%([id="#{id}"])), "nothing on the page has id #{id}" }
  end

  test "llms.txt is plain text and points at the Markdown guide" do
    get llms_txt_path

    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_includes response.body, "https://#{TurfMonster::HostConfig::DEFAULT_APP_HOST}/agents/guide.md"
    assert response.body.start_with?("# Turf Monster\n")
  end

  # ── What the guide must cover, and must not say ─────────────────────────────

  test "the guide has the sections an agent needs" do
    sections = MiniMarkdown.headings(guide_markdown).select { |heading| heading.level == 2 }.map(&:text)

    [
      "What Turf Monster is", "The rules of Turf Totals", "Scoring", "Contest lifecycle", "Locks",
      "Entry limits and duplicate lineups", "Prizes, ties and short fields", "Eligibility",
      "Free entry tokens and funding", "Endpoints", "Errors", "Retries and idempotency", "Rate limits",
      "Results and payouts", "What the API cannot do yet", "How to win"
    ].each { |section| assert_includes sections, section }
  end

  test "the guide's numbers are the code's numbers" do
    markdown = guide_markdown
    key = Rack::Attack.throttles.fetch("api/key")

    assert_includes markdown, "#{key.limit} requests per #{key.period.to_i} seconds"
    assert_includes markdown, "#{(ApiKey::LIFETIME / 1.day).to_i} days"
    assert_includes markdown, "Entry score: **#{format('%.1f', TurfMonsterRules.lineup_total)}**"
    AgePolicy::MINIMUM_AGE_BY_STATE.each_key { |state| assert_includes markdown, state }
    Studio::GeoSetting.banned_subdivision_codes.each { |state| assert_includes markdown, state }

    # The example board obeys the pricing rule the guide states: rank 5 of 6,
    # one game of two.
    bye = SlateMatchup.turf_score_for(5, 6, sport: "nfl", game_factor: Slate.game_factor(2, 1))
    assert_includes markdown, %("turf_score": #{bye},)
    assert_includes markdown, %("points": #{(17 * bye).round(1)})
  end

  test "the multiplier table in the guide is the curve, rank by rank" do
    table = guide_markdown[/\| Turf Score \| Ranks \|\n\|---\|---\|\n((?:\|.*\|\n)+)/, 1]
    printed = table.lines.flat_map do |line|
      score, ranks = line.split("|").map(&:strip).reject(&:empty?)
      first, last = ranks.split(" to ").map(&:to_i)
      (first..(last || first)).map { |rank| [ rank, score.to_f ] }
    end.to_h

    expected = (1..TurfMonsterRules::TEAM_COUNT).to_h do |rank|
      [ rank, SlateMatchup.turf_score_for(rank, TurfMonsterRules::TEAM_COUNT, sport: "nfl") ]
    end
    assert_equal expected, printed
  end

  test "neither page says what the Terms allow an agent to do, or promises a result" do
    [ agents_path, agents_guide_markdown_path, llms_txt_path ].each do |path|
      get path
      body = path == agents_path ? page_text('[data-test="agents-page"]') : response.body

      assert_no_match(/terms (of service )?(permit|allow|let|forbid|prohibit)/i, body)
      assert_no_match(/(permitted|allowed|prohibited) (by|under) (the|our) terms/i, body)
      assert_no_match(/unfair advantage/i, body)
      assert_no_match(/guaranteed? (to )?win|will win|sure to win/i, body)
      assert_no_match(/within \d+ (minutes|hours|days)|instant(ly)? paid|paid (out )?(instantly|immediately|automatically)/i, body)
    end
  end

  test "the stale copy elsewhere on the site is not repeated" do
    markdown = guide_markdown

    assert_no_match(/devnet|seeds/i, markdown)
    assert_match(/Grading is a manual step/, markdown)
    assert_match(/pool the prizes of the places they cover/, markdown)
  end
end
