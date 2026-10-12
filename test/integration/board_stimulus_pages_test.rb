require "test_helper"

# [integration] The contest page and the lobby, where they left Alpine: each
# converted control renders its controller's hooks and its safe initial state
# in the markup, and no Alpine inside the converted region. Every controller
# here is static (registered in turf_stimulus.js and preloaded), so the markup
# is pressable from first paint; these tests pin the state it starts in.
class BoardStimulusPagesTest < ActionDispatch::IntegrationTest
  ALPINE = /\A(?:x-|@|:)/

  setup do
    @contest = contests(:one)
    @alex = users(:alex)
  end

  def roots_for(identifier)
    assert_response :success
    css_select(%([data-controller~="#{identifier}"])).tap { |roots| assert_not_empty roots, "no #{identifier} controller on the page" }
  end

  # `except` names descendants that are still Alpine on purpose (an engine
  # store, a nested partial that is not this card's).
  def assert_no_alpine(root, except: [])
    kept = except.flat_map { |selector| root.css(selector).flat_map { |node| [ node, *node.css("*") ] } }
    carriers = ([ root, *root.css("*") ] - kept).select { |node| node.attribute_nodes.any? { |attribute| attribute.name.match?(ALPINE) } }
    assert_empty carriers.map { |node| node.to_html[0, 120] }
    assert_empty (root.css("script").to_a - kept).reject { |script| script["type"] == "application/json" }
    assert_empty ([ root, *root.css("*") ] - kept).flat_map(&:attribute_nodes).map(&:name).grep(/\Aon[a-z]+\z/)
  end

  test "the leaderboard starts folded, both pill layouts hidden until it has measured its column" do
    log_in_as(@alex)
    get contest_path(@contest)
    root = roots_for("leaderboard").first

    assert_no_alpine root
    assert_includes root["data-action"], "resize@window->leaderboard#resized"
    assert_includes root["data-action"], "turbo:before-cache@document->leaderboard#reset"
    root.css('[data-leaderboard-target="picks"]').each do |picks|
      assert_equal "false", picks["data-open"]
      assert picks.at_css('[data-leaderboard-target="narrow"][hidden]'), "the narrow layout shows before it is measured"
      assert picks.at_css('[data-leaderboard-target="full"][hidden]'), "the full layout shows before it is measured"
      pills = picks.css('[data-leaderboard-target="pill"]')
      next if pills.empty?

      assert_equal (0...pills.size).map(&:to_s), pills.map { |pill| pill["data-index"] }
      assert_equal [ pills.size.to_s ], pills.map { |pill| pill["data-count"] }.uniq
    end
    root.css('[data-leaderboard-target="tail"]').each { |row| assert row.key?("hidden"), "a folded seat shows" }
    assert_empty root.css('[data-leaderboard-target="more"][hidden]')
    root.css('[data-leaderboard-target="less"]').each { |less| assert less.key?("hidden") }
  end

  test "a long leaderboard folds past eight seats, with the fold's two controls" do
    @contest.update_columns(max_entries: 12)
    get contest_path(@contest)
    root = roots_for("leaderboard").first

    assert_equal 4, root.css('[data-leaderboard-target="tail"]').size
    assert_equal "leaderboard#expand", root.at_css('[data-leaderboard-target="more"]')["data-action"].split("->").last
    assert_equal "leaderboard#collapse", root.at_css('button[data-leaderboard-target="less"][hidden]')["data-action"]
  end

  test "the leaderboard and chat tabs start on the leaderboard" do
    get contest_path(@contest)
    root = roots_for("tabs").first

    assert_no_alpine root, except: [ '[data-key="chat"]', "#leaderboard-container" ]
    assert_equal "leaderboard", root["data-tabs-initial-value"]
    assert_includes root["data-action"], "turbo:before-cache@document->tabs#reset"
    leaderboard_tab, chat_tab = root.css('[data-tabs-target="tab"]')
    assert_includes leaderboard_tab["class"].split, "bg-primary"
    assert_includes chat_tab["class"].split, "text-secondary"
    assert_includes root.at_css('[data-tabs-target="panel"][data-key="chat"]')["class"].split, "hidden"
    assert_not_includes root.at_css('[data-tabs-target="panel"][data-key="leaderboard"]')["class"].split, "hidden"
  end

  test "the header's menu and start tooltip start closed, and the admin's chain buttons carry the slug" do
    log_in_as(@alex)
    get contest_path(@contest)
    menu, tip = roots_for("disclosure").first(2)

    assert_includes menu["data-controller"].split, "contest-chain"
    assert_equal @contest.slug, menu["data-contest-chain-slug-value"]
    [ menu, tip ].each do |root|
      assert_no_alpine root, except: [ '[x-data^="{"]' ]
      assert_includes root["data-action"], "click@window->disclosure#outside"
      assert_includes root["data-action"], "turbo:before-cache@document->disclosure#reset"
      assert root.at_css('[data-disclosure-target="panel"][hidden]')
      assert_equal "false", root.at_css('[data-disclosure-target="trigger"]')["aria-expanded"]
    end
    assert_equal "opacity-0 scale-95", menu.at_css('[data-disclosure-target="panel"]')["data-enter-start"]
    assert_equal "click->disclosure#toggle keydown.enter->disclosure#toggle:prevent keydown.space->disclosure#toggle:prevent",
                 tip.at_css('[role="button"]')["data-action"]
    assert_not_includes response.body, "lockContestViaPhantom("
    assert_not_includes response.body, "concludeContestViaPhantom("
  end

  test "the share invite starts idle and closed, and copies the invite link" do
    log_in_as(@alex)
    get contest_path(@contest)
    root = css_select('[data-controller~="copy-link"]').first
    assert root, "the entered viewer's quest card carries the share invite"

    assert_no_alpine root
    assert_equal "disclosure copy-link", root["data-controller"]
    assert_equal root.at_css('[data-action="click->copy-link#copy"]').text, root["data-copy-link-text-value"]
    assert_includes root["data-action"], "keydown.esc@window->disclosure#close"
    assert root.at_css('[data-disclosure-target="panel"][hidden]')
    button = root.at_css('[data-copy-link-target="button"]')
    assert_includes button["class"].split, "btn-primary"
    assert_not button.at_css('[data-copy-link-target="idle"]').key?("hidden")
    assert button.at_css('[data-copy-link-target="done"][hidden]')
  end

  test "the contest page polls and scrolls through controllers, not inline script" do
    log_in_as(@alex)
    get contest_path(@contest)

    poll = roots_for("leaderboard-poll").first
    assert_equal @contest.slug, poll["data-leaderboard-poll-slug-value"]
    assert_equal @contest.updated_at.to_i.to_s, poll["data-leaderboard-poll-version-value"]
    assert_equal 1, roots_for("arrival-scroll").size
    inline = css_select("script:not([src])").reject { |script| script["type"].to_s.match?(/json|importmap/) }.map(&:text)
    assert_empty inline.grep(/leaderboard_poll/), "the poll is back in an inline script"
    assert_empty inline.grep(/params\.get\('scroll'\)/), "the arrival scroll is back in an inline script"
  end

  test "the lobby hides settled contests behind the admin toggle, and rows link to their contest" do
    log_in_as(@alex)
    @contest.update_columns(status: "settled")
    get contests_path
    root = roots_for("settled-filter").first

    assert_no_alpine root, except: [ "[data-contest-card]" ]
    toggle = root.at_css('[data-settled-filter-target="toggle"]')
    assert_equal [ "btn btn-outline", "false", "Show Settled" ], [ toggle["class"], toggle["aria-pressed"], toggle.text.strip ]
    row = root.at_css(%([data-contest-band="all"] [data-contest-row="#{@contest.slug}"]))
    assert row.key?("hidden")
    assert_equal "row", row["data-settled-filter-target"]
    assert_equal "click->row-link#visit", row["data-action"]
    assert_equal contest_path(@contest), row["data-row-link-url-param"]
    assert_empty root.css("a[onclick], tr[onclick]")
  end

  test "the featured rail measures its fade in a controller" do
    get contests_path
    root = roots_for("contest-rail").first

    assert_no_alpine root, except: [ "[data-contest-card]", ".hold-stack" ]
    viewport = root.at_css('[data-contest-rail-target="viewport"]')
    assert_equal "scroll->contest-rail#measure:passive", viewport["data-action"]
    assert_nil viewport["style"]
  end
end
