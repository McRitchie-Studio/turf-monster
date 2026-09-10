require "test_helper"

# Integration tier: colors are a function of seeding. The NFL seed assigns the
# full palette keyed by intrinsic lightness (dark/light plus alts and a
# disposition) and is idempotent — reseeding corrects a drifted color without
# duplicating team rows (the operator's "reseed to correct" guarantee).
class NflTeamColorsSeedTest < ActiveSupport::TestCase
  def seed!
    silence_warnings { load Rails.root.join("db/seeds/nfl_2026.rb") }
  end

  test "seed assigns the lightness-keyed palette per the reorganized rules" do
    seed!

    bills = Team.find_by!(slug: "buffalo-bills")
    assert_equal "#00338D", bills.color_dark,       "dark = royal-blue field"
    assert_equal "#C60C30", bills.color_light,      "light = red mascot text"
    assert_equal "#FFFFFF", bills.color_light_alt,  "white kept as light alt"
    assert_equal "#041E42", bills.color_dark_alt,   "navy kept as dark alt"
    assert bills.disposition_dark?,                 "Bills stay dark-disposition"

    assert_equal "#9E7C0C", Team.find_by!(slug: "baltimore-ravens").color_light, "Ravens mascot = gold"
    assert_equal "#C60C30", Team.find_by!(slug: "baltimore-ravens").color_alt, "Ravens red parked in the alt slot"
    assert_equal "#B3995D", Team.find_by!(slug: "san-francisco-49ers").color_light, "49ers mascot = gold"
    assert_nil Team.find_by!(slug: "new-york-jets").color_light_alt, "Jets are a simple two-color team"
    assert_nil Team.find_by!(slug: "new-york-jets").color_grey, "no team curates a grey yet"
    assert Team.find_by!(slug: "new-orleans-saints").disposition_dark?, "Saints now ride their dark field"
  end

  test "reseeding corrects a drifted color without duplicating teams" do
    seed!
    bills = Team.find_by!(slug: "buffalo-bills")
    bills.update!(color_light: "#000000") # simulate a bad/manual edit

    seed!

    assert_equal 1, Team.where(slug: "buffalo-bills").count, "reseed must not duplicate a team"
    assert_equal "#C60C30", bills.reload.color_light, "reseed restores the canonical color"
  end
end
