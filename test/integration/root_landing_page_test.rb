require "test_helper"

# Root serves the LANDING PAGE (/tasks/turf-root-serves-landing-page, Alex
# 2026-10-06). remove-world-cup-survivor had made "/" the contests lobby; now
# "/" is the turf_monster_v2 explainer for a signed-out visitor, a signed-in
# visitor goes on to the lobby, and the lobby lives at /contests.
#
# Every return flow that used to land on "/" because "/" was the lobby is held
# here: each must still end on the lobby, by name or through the one redirect.
class RootLandingPageTest < ActionDispatch::IntegrationTest
  LANDING = '[data-test="turf-monster-v2"]'.freeze

  # --- the route table -----------------------------------------------------

  test "[unit] root routes to pages#home and the lobby to contests#index" do
    assert_recognizes({ controller: "pages", action: "home" }, "/")
    assert_recognizes({ controller: "contests", action: "index" }, "/contests")
    assert_recognizes({ controller: "pages", action: "turf_monster_v2" }, "/turf-monster-v2")
  end

  # --- signed out: the landing page ----------------------------------------

  test "[integration] a signed-out GET / renders the landing page, not the lobby" do
    get root_path

    assert_response :success
    assert_equal "pages", @controller.controller_name
    assert_equal "home", @controller.action_name
    assert_select LANDING, 1
    assert_select "h1", { text: "Contests", count: 0 }, "the lobby's heading must not render at root"
  end

  test "[integration] control: /contests renders the lobby, not the landing page" do
    get contests_path

    assert_response :success
    assert_select "h1", text: "Contests"
    assert_select LANDING, 0
  end

  test "[integration] the legacy World Cup paths 301 to / and land a signed-out visitor on the landing" do
    %w[/world-cup /world_cup].each do |path|
      get path
      assert_response :moved_permanently, path
      assert_redirected_to "http://www.example.com/"
      follow_redirects!
      assert_select LANDING, 1
    end
  end

  test "the landing's Play now links go to the lobby, never back to /" do
    get root_path

    play_now = css_select("a").select { |a| a.text.strip == "Play now" }
    assert_not_empty play_now, "the landing's live band carries a Play now link"
    assert_equal [contests_path], play_now.map { |a| a["href"] }.uniq
  end

  test "[component] root hands a signed-out visitor's saved cart back; /turf-monster-v2 does not" do
    get root_path
    script = css_select("script").map(&:text).find { |js| js.include?("pendingContestEntry") }
    assert script, "root used to be the lobby, which hands a saved cart back; the landing at root keeps that"
    assert_includes script, "'/contests/' + encodeURIComponent(parsed.contestSlug) + '/contest'"

    get turf_monster_v2_path
    assert_select LANDING, 1
    assert_not(css_select("script").any? { |s| s.text.include?("pendingContestEntry") },
               "the hand-back belongs to root, not to the explainer's own URL")
  end

  # --- signed in: on to the lobby ------------------------------------------

  test "[integration] a signed-in GET / redirects to the lobby, query kept" do
    log_in_as(users(:jordan))

    get root_path
    assert_redirected_to contests_path

    get root_path(reference: "tiktok")
    assert_redirected_to contests_path(reference: "tiktok")
    follow_redirect!
    assert_select "h1", text: "Contests"
  end

  test "[integration] a flash sent to root survives the hop to the lobby" do
    log_in_as(users(:jordan))

    # EmailVerificationsController#verify still redirects to root_path with an
    # alert on a bad token: the one hop root adds must not eat it.
    get email_verifications_verify_path(token: "not-a-real-token")
    assert_redirected_to root_path
    follow_redirects!

    assert_equal "/contests", path
    assert_includes response.body, "Verification link is invalid or expired"
  end

  # --- the sign-in return flows that relied on root being the lobby --------

  test "[integration] a magic link with no destination lands on the lobby" do
    user = users(:jordan)
    post magic_link_consume_path(token: Studio::Link.create_magic_link(email: user.email).token)
    assert_redirected_to contests_path
  end

  test "[integration] a magic link asked for from the landing (return_to /) lands on the lobby" do
    user = users(:jordan)
    token = Studio::Link.create_magic_link(email: user.email, return_to: "/").token
    post magic_link_consume_path(token: token)
    assert_redirected_to contests_path
  end

  test "[integration] a returning Phantom sign-in is sent to the lobby, not to /" do
    log_in_as_onchain(users(:jordan))

    redirect = JSON.parse(response.body)["redirect"]
    assert_equal contests_path, redirect
    get redirect
    assert_select "h1", text: "Contests"
  end

  test "[integration] control: a magic link with a real destination still lands there" do
    user = users(:jordan)
    token = Studio::Link.create_magic_link(email: user.email, return_to: "/account").token
    post magic_link_consume_path(token: token)
    assert_redirected_to "/account"
  end
end
