require "test_helper"

# [integration] THE TERMS AND THE AGENT PAGES STATE ONE RULE.
#
# The Terms of Service ("Acceptable use") say what a player may do with an AI
# agent. /agents and the agent guide repeat it, so a player and an agent can
# read it where they are. Two statements of one rule drift, so this holds them
# together:
#
#   * the Terms carry the wording Alex approved on 2026-10-01 VERBATIM, as two
#     list items, and the sentence they replaced is gone;
#   * /agents and the guide each link the Terms, and each name the permission
#     (official API, own account, own key), the player's responsibility and
#     each of the three prohibitions, in the Terms' own phrases;
#   * the guide names both halves of the official API (REST and MCP), on the
#     same host the rest of the guide uses;
#   * neither page widens the rule into something the Terms do not say.
#
# The approved text is TYPED here, not read from the view: this is the test's
# own copy of binding copy, so an edit to the Terms has to be made twice, on
# purpose.
class AgentTermsConsistencyTest < ActionDispatch::IntegrationTest
  NO_CHEATING = "Do not cheat, collude, or exploit bugs.".freeze
  AI_AGENTS = "You may use an AI agent or other software to play through our official API, " \
              "on your own account and with your own API key. You remain responsible for " \
              "everything it does. Do not use automation to run more than one account, to " \
              "coordinate entries with other players, or to reach the game by any route " \
              "other than the official API.".freeze

  # The phrases of the rule, as the Terms spell them. Each must be IN the
  # approved text (checked below), so this list cannot name something the Terms
  # do not say; and each must be on every page that restates the rule.
  PROHIBITIONS = [
    "run more than one account",
    "coordinate entries with other players",
    "by any route other than the official API"
  ].freeze
  PERMISSION = [ "official API", "own account", "own API key" ].freeze
  RESPONSIBILITY = /remains? responsible for everything/

  def squish(text)
    text.gsub(/\s+/, " ").strip
  end

  def terms_doc
    get terms_path
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def acceptable_use_items
    heading = terms_doc.css("h2").find { |h2| h2.text.strip == "Acceptable use" }
    assert heading, "the Terms have an Acceptable use section"
    heading.parent.css("ul > li").map { |li| squish(li.text) }
  end

  # The words of each page's statement of the rule, links flattened to text.
  def agents_rule
    get agents_path
    assert_response :success
    node = Nokogiri::HTML(response.body).at_css('[data-test="agents-terms-rule"]')
    assert node, "/agents states the Terms rule"
    node
  end

  def guide_rule
    get agents_guide_markdown_path
    assert_response :success
    section = response.body[/^### What the Terms permit\n(.*?)^## /m, 1]
    assert section, "the guide has a section on what the Terms permit"
    section
  end

  test "the Terms carry the approved wording verbatim, as two items, among the others" do
    items = acceptable_use_items

    assert_equal NO_CHEATING, items[0]
    assert_equal AI_AGENTS, items[1]
    assert_equal 4, items.size, "the two approved items, then the two that were already there"
    assert_match(/\ADo not attempt to access other users/, items[2])
    assert_match(/\AWe may suspend or terminate accounts/, items[3])
  end

  test "the sentence the approved wording replaced is nowhere on the Terms page" do
    text = squish(terms_doc.text)

    assert_no_match(/automated agents/i, text)
    assert_no_match(/unfair advantage/i, text)
  end

  # The date is the day the wording last changed, not the day of the visit:
  # the Terms tell the reader to judge a change by it. Move it with the copy.
  test "the Terms' last-updated date is fixed at the day of the approved change" do
    travel_to Time.zone.local(2027, 3, 15, 12) do
      assert_includes squish(terms_doc.text), "Last updated October 01, 2026."
    end
  end

  test "every phrase this guard holds the pages to is in the approved Terms text" do
    (PROHIBITIONS + PERMISSION).each { |phrase| assert_includes AI_AGENTS, phrase }
    assert_match RESPONSIBILITY, AI_AGENTS
    assert_equal 3, AI_AGENTS[/Do not use automation to (.*)\z/, 1].split(/, (?:or )?/).size,
                 "the Terms name three prohibitions; a fourth needs a phrase here and on the pages"
  end

  test "/agents states the rule in the Terms' phrases and links the Terms at the clause" do
    node = agents_rule
    text = squish(node.text)

    assert node.at_css(%(a[href="#{terms_path(anchor: "ai-agents")}"])), "links the Terms clause"
    (PERMISSION + PROHIBITIONS).each { |phrase| assert_includes text, phrase }
    assert_match RESPONSIBILITY, text
  end

  test "the guide states the rule in the Terms' phrases and links the Terms at the clause" do
    section = guide_rule
    text = squish(section)
    host = TurfMonster::HostConfig::DEFAULT_APP_HOST

    assert_includes section, "(https://#{host}#{terms_path(anchor: "ai-agents")})"
    (PERMISSION + PROHIBITIONS).each { |phrase| assert_includes text, phrase }
    assert_match RESPONSIBILITY, text
    assert_equal 3, section.scan(/^- \*\*Not permitted:\*\*/).size, "three prohibitions, as in the Terms"
  end

  test "the anchor the pages link to exists on the Terms page, on the approved item" do
    item = terms_doc.at_css("#ai-agents")

    assert item, "the Terms have an element with id ai-agents"
    assert_equal AI_AGENTS, squish(item.text)
  end

  test "the guide says the official API is the REST API and the MCP endpoint" do
    section = guide_rule
    host = TurfMonster::HostConfig::DEFAULT_APP_HOST

    assert_includes section, "`https://#{host}/api/v1`"
    assert_includes section, "`https://#{host}#{mcp_path}`"
  end

  test "the rendered guide carries the same section, with a working link to the Terms" do
    get agents_guide_path
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    host = TurfMonster::HostConfig::DEFAULT_APP_HOST

    assert doc.css("h3").any? { |h3| h3.text.strip == "What the Terms permit" }
    assert doc.at_css(%(a[href="https://#{host}#{terms_path(anchor: "ai-agents")}"]))
    PROHIBITIONS.each { |phrase| assert_includes squish(doc.text), phrase }
  end

  # The pages may not say more than the Terms do. These are the widenings a
  # well-meant edit would reach for; none is in the approved text.
  test "neither page widens the rule beyond the Terms" do
    [ squish(agents_rule.text), squish(guide_rule) ].each do |text|
      assert_no_match(/any (account|key|API)\b/i, text)
      assert_no_match(/(accounts|keys) (you|they) (control|manage|hold)/i, text)
      assert_no_match(/\b(bots?|scripts?) (are|is) (welcome|allowed|permitted)/i, text)
      assert_no_match(/unfair advantage/i, text)
      assert_no_match(/on (someone|anyone) else's|for (other|another) (players?|people|person)/i, text)
    end
  end
end
