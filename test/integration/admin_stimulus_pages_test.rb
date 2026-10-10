require "test_helper"

# [integration] The admin pages that left Alpine: each renders its controller's
# hooks and its initial state in the markup, and no Alpine inside the converted
# region.
class AdminStimulusPagesTest < ActionDispatch::IntegrationTest
  ALPINE = /\A(?:x-|@|:)/

  setup { log_in_as(users(:alex)) }

  def root_for(identifier)
    assert_response :success
    css_select(%([data-controller~="#{identifier}"])).first.tap { |root| assert root, "no #{identifier} controller on the page" }
  end

  def assert_no_alpine(root)
    carriers = [ root, *root.css("*") ].select { |node| node.attribute_nodes.any? { |attribute| attribute.name.match?(ALPINE) } }
    assert_empty carriers.map { |node| node.to_html[0, 120] }
    assert_empty root.css("script").reject { |script| script["type"] == "application/json" }
    assert_empty [ root, *root.css("*") ].flat_map(&:attribute_nodes).map(&:name).grep(/\Aon[a-z]+\z/)
  end

  test "the schema page filters its tables, with the clear button and the empty state hidden" do
    get admin_schema_path
    root = root_for("filter")

    assert_no_alpine root
    assert root.at_css('input[data-filter-target="input"]')
    assert root.at_css('button[data-filter-target="clear"][hidden]')
    assert root.at_css('[data-filter-target="empty"][hidden] [data-filter-target="query"]')
    items = root.css('[data-filter-target="item"]')
    assert_includes items.map { |item| item["data-filter-text"] }, "users"
    assert_empty items.select { |item| item.key?("hidden") }
  end

  test "the dashboard lists five users and hides the rest behind Show more" do
    7.times { |i| User.create!(email: "show-more-#{i}@example.com", username: "showmore#{i}") }
    get admin_dashboard_path
    root = root_for("show-more")

    assert_no_alpine root
    rows = root.css("ul > li")
    assert_operator rows.size, :>, 5
    assert_equal rows.drop(5), rows.select { |row| row.key?("hidden") && row["data-show-more-target"] == "extra" }
    assert root.at_css('button[data-action="show-more#toggle"] [data-show-more-target="more"]:not([hidden])')
    assert root.at_css('button[data-action="show-more#toggle"] [data-show-more-target="less"][hidden]')
  end

  test "the hub's two actions are buttons on the hub-actions controller" do
    get admin_hub_path
    root = root_for("hub-actions")

    assert_no_alpine root
    assert_equal "Refresh Balance", root.at_css('button[data-action="hub-actions#refreshBalance"]').text.strip
    assert_equal "Replay Level", root.at_css('button[data-action="hub-actions#replayLevel"]').text.strip
  end

  test "the drop announcement renders its Send disabled, with the count and the confirm on the gate" do
    DropSignup.create!(email: "gate@example.com", slate_key: NextSlateDrop::SLATE_KEY)
    travel_to(NextSlateDrop.drops_at - 1.day) do
      get admin_drop_signups_announcement_path
      root = root_for("send-gate")

      assert_no_alpine root
      assert_equal "1", root["data-send-gate-count-value"]
      assert_equal "true", root["data-send-gate-needs-early-value"]
      assert_equal "Send the drop announcement to 1 address? This cannot be undone.", root["data-send-gate-confirm-value"]
      assert_includes root.at_css("form")["data-action"], "submit->send-gate#confirm"
      assert root.at_css('input[type="submit"][disabled][data-send-gate-target="submit"]')
      assert root.at_css('input[data-send-gate-target="typed"][data-action="input->send-gate#update"]')
      assert root.at_css('input[type="checkbox"][data-send-gate-target="early"][data-action="change->send-gate#update"]')
    end

    travel_to(NextSlateDrop.drops_at + 1.hour) do
      get admin_drop_signups_announcement_path
      root = root_for("send-gate")
      assert_equal "false", root["data-send-gate-needs-early-value"]
      assert_nil root.at_css('[data-send-gate-target="early"]')
    end
  end

  test "the seeds lab renders every loop on the server, at zero" do
    get seeds_lab_path
    root = root_for("seeds-lab")

    assert_no_alpine root
    assert_empty root.css("template")
    assert_equal 5, root.css('[data-seeds-lab-target="shimmer"][hidden]').size
    assert_equal (0..100).map(&:to_s), root.at_css('[data-style="roller"]').css("span").map(&:text)
    assert_equal %w[1 2 3 4 5], root.css('[data-seeds-lab-target="sprout"]').map { |sprout| sprout["data-index"] }
    assert_equal %w[1 2 3 4 5] * 2, root.css('[data-seeds-lab-target="sectionFill"]').map { |fill| fill["data-index"] }
    assert_equal 5, root.css('[data-seeds-lab-target~="pop"][data-label="levelBadge"]').size
    assert_equal 5, root.css('button[data-seeds-lab-target="simButton"]').size
    assert root.at_css('[data-seeds-lab-target="pulseOnly"][hidden]')
    widths = root.css(".seeds-bar-continuous").first.css("div > div:first-child").map { |fill| fill["style"][/calc\(\(var\(--bar-progress\) - (\d+)\)/, 1] }
    assert_equal %w[0 20 40 60 80], widths
  end

  test "the toast test page carries each toast as a button's detail, and each demo by name" do
    get "/toast_test"
    root = root_for("toast-demo")

    assert_no_alpine root
    details = root.css('button[data-action="toast-demo#fire"]').map { |button| JSON.parse(button["data-toast-demo-detail-param"]) }
    assert_equal 10, details.size
    assert_includes details, { "type" => "notice", "title" => "Custom Title", "message" => "With explicit title text.", "duration" => 10000 }
    assert_includes details, { "type" => "alert", "message" => "Connection lost. Retrying...", "dismissible" => false }
    assert_equal %w[invite delete undo blurButtons stack stackSlow],
                 root.css('button[data-action="toast-demo#demo"]').map { |button| button["data-toast-demo-name-param"] }
  end

  test "the goal console draws each fixture from a template, with no goal markup of its own" do
    game = games(:past_game)
    slate_matchups(:m1).update!(game_slug: game.slug)
    get admin_scoring_path
    root = root_for("scoring-filter")

    assert_no_alpine root
    assert_includes root["data-action"], "game-scorer:changed->scoring-filter#update"
    card = root.at_css('[data-controller="game-scorer"][data-scoring-filter-target="card"]')
    assert_equal (game.status == "completed").to_s, card["data-done"]
    assert card.at_css('[data-game-scorer-target="goals"][hidden]')
    template = card.at_css('template[data-game-scorer-target="goalTemplate"]')
    pill = Nokogiri::HTML.fragment(template.inner_html)
    assert pill.at_css("[data-goal-emoji]") && pill.at_css("[data-goal-minute]") && pill.at_css("[data-goal-tick]")
    assert pill.at_css('button[data-goal-remove][data-action="game-scorer#removeGoal"][data-game-scorer-target="control"]')
    assert_equal "bg-emerald-500/15 text-emerald-400", card["data-game-scorer-final-class"]
  end
end
