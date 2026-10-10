require "test_helper"

# [integration] The public pages that left Alpine: each renders its
# controller's hooks and its initial state in the markup, and no Alpine inside
# the converted region. Every one of these controllers is static (registered in
# turf_stimulus.js and preloaded), so its markup is pressable from first paint;
# these tests pin the safe state that markup starts in.
class MarketingStimulusPagesTest < ActionDispatch::IntegrationTest
  ALPINE = /\A(?:x-|@|:)/

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

  test "how to play opens one section at a time, all closed at first" do
    get help_how_to_play_path
    root = root_for("accordion")

    assert_no_alpine root
    assert_includes root["data-action"], "turbo:before-cache@document->accordion#collapse"
    keys = root.css('button[data-action="accordion#toggle"]').map { |button| button["data-accordion-key-param"] }
    assert_equal %w[picks turfScores scoring payouts], keys
    assert_equal keys, root.css('[data-accordion-target="panel"][hidden]').map { |panel| panel["data-key"] }
    assert_empty root.css('[data-accordion-target="icon"].rotate-180')
    # A visitor without JavaScript still reads every section.
    assert response.body.include?('<noscript><style>@layer base { [data-accordion-target="panel"][hidden] { display: block !important; } }</style></noscript>'),
      "how to play lost the noscript rule that shows every panel without JavaScript"
  end

  test "the contract calculator carries the measured lamports and the default price" do
    get contract_path
    root = root_for("cost-calculator")

    assert_no_alpine root
    assert_operator root["data-cost-calculator-perm-lamports-value"].to_i, :>, 0
    assert_operator root["data-cost-calculator-float-lamports-value"].to_i, :>, root["data-cost-calculator-perm-lamports-value"].to_i
    assert_equal "165", root.at_css('input[data-cost-calculator-target="price"]')["value"]
    figures = root.css('[data-cost-calculator-target="output"]').map { |output| output["data-figure"] }
    assert_equal %w[floatSol floatUsd permSol permUsd bufferSol bufferUsd floatSolApprox], figures
    assert_not_includes response.body, "contractCostCalculator"
  end

  test "the drop unsubscribe form submits itself on connect, with its button as the fallback" do
    signup = DropSignup.create!(email: "fan@example.com", slate_key: NextSlateDrop::SLATE_KEY)
    get drop_unsubscribe_path(token: signup.unsubscribe_token)
    root = root_for("auto-submit")

    assert_equal "drop-unsubscribe-form", root["id"]
    assert_no_alpine root
    assert root.at_css('button[type="submit"]')
    assert_empty css_select('[data-test="drop-unsubscribe"] ~ script')
  end

  test "players start unfiltered, All pressed, with the count rendered" do
    Player.create!(name: "Pat Striker", slug: "pat-striker", position: "FW", team_slug: "team-a")
    Player.create!(name: "Kim Keeper", slug: "kim-keeper", position: "GK", team_slug: "team-a")
    get players_path
    root = root_for("card-filter")

    assert_no_alpine root
    assert_equal "[data-player-card]", root["data-card-filter-selector-value"]
    assert_equal "2 players", root.at_css('[data-card-filter-target="count"]').text.strip
    pressed = root.css('[data-card-filter-target="option"][aria-pressed="true"]')
    assert_equal [ "all" ], pressed.map { |option| option["data-card-filter-value-param"] }
    assert_includes pressed.first["class"].split, "btn-primary"
    assert_equal %w[FW GK], root.css('[data-card-filter-target="option"][aria-pressed="false"].btn-outline').map { |option| option["data-card-filter-value-param"] }
    assert_empty root.css("[data-player-card][hidden]")
  end

  test "a team roster filters its athlete cards by search" do
    get nfl_players_path(team: "team-a")
    root = root_for("card-filter")

    assert_no_alpine root
    cards = root.css("[data-athlete-card]")
    assert_operator cards.size, :>, 0
    assert_equal "#{cards.size} players", root.at_css('[data-card-filter-target="count"]').text.strip
    assert root.at_css('input[data-card-filter-target="search"][data-action="input->card-filter#search"]')
  end

  test "teams filter by league and copy swatches, every tip hidden" do
    get teams_path
    root = root_for("card-filter")

    assert_no_alpine root
    assert_equal "#{root.css('[data-team-card]').size} teams", root.at_css('[data-card-filter-target="count"]').text.strip
    strips = root.css('[data-controller="swatch-copy"]')
    assert_not_empty strips
    strips.each { |strip| assert_includes strip["data-action"], "turbo:before-cache@document->swatch-copy#reset" }
    swatches = root.css("button[data-hex]")
    assert_not_empty swatches
    swatches.each do |swatch|
      assert_equal "mouseenter->swatch-copy#hover mouseleave->swatch-copy#unhover swatch-copy#copy", swatch["data-action"]
      assert_equal swatch["data-hex"], swatch.at_css('[data-swatch-copy-target="tip"][hidden]').text
    end
  end

  test "proof of reserves renders its contests and the loading state, Refresh disabled" do
    contest = contests(:one)
    contest.update_columns(onchain_contest_id: "4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T",
                           onchain_tx_signature: "5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4tjF3ZpRzrFmBV6UjKdiSZkQUW")
    get proof_of_reserves_path
    root = root_for("proof-of-reserves")

    assert_no_alpine root
    assert_equal Solana::Config.public_rpc_url, root["data-proof-of-reserves-rpc-url-value"]
    assert_equal "text-danger-ink", root.at_css('[data-proof-of-reserves-target="label"]')["data-warn-class"]

    button = root.at_css('button[data-proof-of-reserves-target="refresh"]')
    assert button.key?("disabled")
    assert root.at_css('[data-proof-of-reserves-target="idle"][hidden]')
    assert root.at_css('[data-proof-of-reserves-target="busy"]:not([hidden])')
    assert_equal "Checking…", root.at_css('[data-proof-of-reserves-target="label"]').text.strip
    assert root.at_css('[data-proof-of-reserves-target="bannerError"][hidden][role="status"]')

    row = root.at_css(%([data-proof-of-reserves-target="row"][data-contest-pda="#{contest.onchain_contest_id}"]))
    assert row, "the listed on-chain contest has no row"
    assert row["data-prize-pool-pda"].present?
    assert_equal "Loading…", row.at_css('[data-field="status"]').text.strip
    assert row.at_css('[data-field="loading"]:not([hidden])')
    assert row.at_css('[data-field="decoded"][hidden]')
    assert row.at_css('[data-field="error"][hidden]')
    assert row.at_css(%(a[href="https://explorer.solana.com/tx/#{contest.onchain_tx_signature}?cluster=#{Solana::Config::NETWORK}"])) unless Solana::Config::NETWORK == "mainnet-beta"
    assert_equal "4Nd1…DB4T", row.at_css(%(a[href*="#{contest.onchain_contest_id}"] .font-mono > span)).text
    assert root.at_css('template[data-proof-of-reserves-target="payout"]')
  end

  test "proof of reserves with no on-chain contest says so" do
    get proof_of_reserves_path
    assert_response :success
    assert_includes response.body, "No on-chain contests right now."
    assert_empty css_select('[data-proof-of-reserves-target="row"]')
  end
end
