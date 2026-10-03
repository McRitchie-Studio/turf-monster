require "test_helper"

# [component] Turf Monster's footer is studio-engine's site footer, declared as
# facts in config/initializers/studio.rb (config.site_footer) and rendered by
# `studio_site_footer` at the end of the application layout.
#
# WHAT THIS DEFENDS. The footer is a legitimacy surface: wallet scanners, link
# unfurlers and payment underwriters look for About, Contact, Terms, Privacy,
# Responsible Gaming and State Eligibility on a new domain. The move from the
# hand-built partial to the engine must not lose a link, retarget one, gain an
# address, a map or a phone number (the operator's instruction), or change
# which pages carry the footer.
#
# Asserted by RENDER, not by reading the initializer: a fact row with a typo'd
# key, or a link the engine refuses, would still read fine in the source.
class SiteFooterTest < ActionDispatch::IntegrationTest
  FOOTER = "footer[data-site-footer]".freeze

  # Every link the hand-built footer carried, by column, in its order, with its
  # label and its target. Sixteen in all.
  def expected_columns
    {
      "Play" => [
        [ "Contests", contests_path ],
        [ "Rules", turf_monster_v1_path ],
        [ "NFL Totals", nfl_team_totals_path ],
        [ "How to Play", help_how_to_play_path ],
        [ "Help Center", help_path ],
        [ "Play with AI", agents_path ]
      ],
      "Transparency" => [
        [ "Transparency Center", transparency_path ],
        [ "Proof of Reserves", proof_of_reserves_path ],
        [ "Smart Contract", contract_path ],
        [ "Phantom Wallet", help_phantom_path ]
      ],
      "Company" => [
        [ "About", about_path ],
        [ "Contact", contact_path ],
        [ "Terms of Service", terms_path ],
        [ "Privacy Policy", privacy_path ],
        [ "Responsible Gaming", responsible_gaming_path ],
        [ "State Eligibility", state_eligibility_path ]
      ]
    }
  end

  test "the footer carries all sixteen links, in their columns, with their targets" do
    get about_path
    assert_response :success

    assert_select FOOTER, count: 1 do
      columns = css_select("nav.ftr-col")
      assert_equal expected_columns.keys, columns.map { |nav| nav.at_css(".ftr-heading")&.text&.strip },
                   "three columns, Play, Transparency and Company, in that order"

      columns.each do |nav|
        heading = nav.at_css(".ftr-heading").text.strip
        links = nav.css("ul.ftr-list a").map { |a| [ a.text.strip, a["href"] ] }
        assert_equal expected_columns.fetch(heading), links,
                     "the #{heading} column must keep every label and target, in order"
      end
      assert_equal 16, css_select("nav.ftr-col ul.ftr-list a").size
    end
  end

  test "the footer keeps the brand, tagline, copyright, play-responsibly link and email" do
    get about_path

    assert_select FOOTER do
      assert_select "a.ftr-home[href=?]", root_path
      assert_select ".ftr-wordmark", text: "TurfMonster"
      assert_select ".ftr-wordmark .ftr-wordmark-accent", text: "Monster"
      assert_select "img.ftr-logo[src=?]", "/icon-192.png"
      assert_select ".ftr-tagline", text: /Skill-based World Cup pick’em contests\. Pick up to 6 matchups, stack Turf Scores, and win cash prizes — with every payout verifiable on our transparency pages\./
      assert_select ".ftr-email a[href=?]", "mailto:alex@turfmonster.media", text: "alex@turfmonster.media"
      assert_select ".ftr-copyright", text: "© #{Time.current.year} McRitchie Studio. Turf Monster is a game of skill."
      assert_select ".ftr-legal a[href=?]", responsible_gaming_path, text: "Play responsibly"
      assert_select ".ftr-legal a[href=?]", terms_path, text: "Terms of Service"
      assert_select ".ftr-legal a[href=?]", privacy_path, text: "Privacy Policy"
    end
  end

  test "the footer has no address, no map and no phone" do
    get about_path

    assert_select FOOTER do
      assert_select "address", count: 0
      assert_select "[data-footer-location]", count: 0
      assert_select "[data-footer-map]", count: 0
      assert_select "a[href^='tel:']", count: 0
      assert_select ".ftr-socials", count: 0
    end
    # Leaflet is only named when an address with coordinates is declared.
    assert_no_match(/leaflet/i, response.body)
    assert_no_match(/tile\.openstreetmap\.org/, response.body)
  end

  test "a signed-in viewer keeps the footer, as on the hand-built one" do
    log_in_as(users(:alex))
    get contests_path
    assert_response :success

    assert_select FOOTER, count: 1
    assert_select "#{FOOTER} a[href=?]", state_eligibility_path
  end

  test "the landing funnel layout has no site footer" do
    get landing_page_path(landing_pages(:launch))
    assert_response :success

    assert_select FOOTER, count: 0
    assert_select "footer", count: 0
    assert_select "[data-test='funnel-footer']", count: 1
  end

  test "the hand-built footer partial is gone" do
    refute_path_exists Rails.root.join("app/views/shared/_footer.html.erb").to_s
  end
end
