# frozen_string_literal: true

require "test_helper"

# [component] EVERY PAGE ON THE APP LAYOUT NAMES ITS LANGUAGE AND HAS ONE MAIN
# (task: turf-every-visitor-lang-main-cache; audit 2026-10-24, lane UI P1).
#
# The app layout shipped a bare `<html>` and no `<main>`: a screen reader guessed
# the page's language and had no landmark to skip to, and axe flagged
# html-has-lang and landmark-one-main on every page that uses it. The landing
# layout already carried `lang`, so it is not tested here.
#
# Two claims, each with a falsifier the other cannot satisfy:
#
#   LANG   the root element says `lang="en"` — asserted on the element, not as a
#          substring, because `lang="en"` also appears on inner nodes.
#   MAIN   exactly ONE `<main>`, and the page's own content is INSIDE it. A
#          `<main>` wrapped around nothing would pass a count alone.
class EveryVisitorLangMainTest < ActionDispatch::IntegrationTest
  setup { SeasonConfig.set_current!(1) }

  { "the lobby" => :contests_path, "getting started" => :getting_started_path }.each do |label, path|
    test "[component] #{label} renders html lang=en and exactly one main around the page" do
      get public_send(path)

      assert_response :success
      assert_select "html[lang='en']", count: 1
      assert_select "main", count: 1
      assert_select "main *", minimum: 1
      assert_select "footer main", count: 0, message: "the footer must sit outside the main landmark"
    end
  end

  test "[component] the lobby's contest rail renders inside main" do
    get contests_path

    assert_response :success
    assert_select "main [data-contest-card]", minimum: 1
  end
end
