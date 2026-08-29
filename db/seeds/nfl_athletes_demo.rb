# A small, OFFLINE set of NFL athletes so /nfl-players has something to show on
# a freshly seeded database — dev, CI, and the e2e lane alike.
#
# The real dataset is ~2,900 players and arrives via `bin/rails nfl:players_seed`,
# which downloads a 7MB CSV from nflverse and uploads headshots to S3. Neither
# belongs in db:seed: seeds must run with no network and no AWS. So this file
# creates a handful of well-known starters with no cached headshots — the player
# card renders their initials, which is the same path ~3% of the real league
# takes anyway.
#
# Every value below is copied from the nflverse feed (2026 actives), including
# the gsis_id, so `nfl:players_seed` MATCHES these rows and updates them in
# place rather than creating twins. Positions are stored already normalized
# (PFF's HB/DI/T/ED folded to RB/DT/OT/EDGE by PositionConcern), which is what
# the importer would write.
puts "\n─── NFL athletes (demo set) ─────────────────────────────"

DEMO_ATHLETES = [
  # first,       last,          team,                   pos,    #,  ht, wt,  gsis_id,      college
  ["Josh",       "Allen",       "buffalo-bills",        "QB",   17, 77, 237, "00-0034857", "Wyoming"],
  ["James",      "Cook",        "buffalo-bills",        "RB",    4, 71, 190, "00-0037248", "Georgia"],
  ["Khalil",     "Shakir",      "buffalo-bills",        "WR",   10, 72, 190, "00-0037261", "Boise State"],
  ["Patrick",    "Mahomes",     "kansas-city-chiefs",   "QB",   15, 74, 225, "00-0033873", "Texas Tech"],
  ["Travis",     "Kelce",       "kansas-city-chiefs",   "TE",   87, 77, 250, "00-0030506", "Cincinnati"],
  ["Chris",      "Jones",       "kansas-city-chiefs",   "DT",   95, 78, 310, "00-0032762", "Mississippi State"],
  ["Jalen",      "Hurts",       "philadelphia-eagles",  "QB",    1, 73, 223, "00-0036389", "Oklahoma"],
  ["Saquon",     "Barkley",     "philadelphia-eagles",  "RB",   26, 72, 232, "00-0034844", "Penn State"],
  ["Lane",       "Johnson",     "philadelphia-eagles",  "OT",   65, 78, 325, "00-0030561", "Oklahoma"],
  ["CeeDee",     "Lamb",        "dallas-cowboys",       "WR",   88, 74, 198, "00-0036358", "Oklahoma"],
  # Traded since the 2025 season — kept accurate on purpose, because a stale
  # team here would read as a bug in the team filter rather than in this list.
  ["Micah",      "Parsons",     "green-bay-packers",    "EDGE",  1, 75, 250, "00-0036932", "Penn State"],
  ["Trevon",     "Diggs",       "seattle-seahawks",     "CB",   16, 73, 203, "00-0036361", "Alabama"],
  ["Justin",     "Jefferson",   "minnesota-vikings",    "WR",   18, 73, 195, "00-0036322", "LSU"],
  # The OTHER Justin Jefferson — a linebacker in Cleveland. Two active players
  # share this name, which is exactly why every importer here matches on
  # gsis_id and never on a name.
  ["Justin",     "Jefferson",   "cleveland-browns",     "LB",   17, 72, 223, "00-0041075", "Alabama"],
  ["Nick",       "Bosa",        "san-francisco-49ers",  "EDGE", 97, 76, 266, "00-0035717", "Ohio State"],
  ["Christian",  "McCaffrey",   "san-francisco-49ers",  "RB",   23, 71, 210, "00-0033280", "Stanford"]
].freeze

created = 0

DEMO_ATHLETES.each do |first, last, team_slug, position, jersey, height, weight, gsis_id, college|
  # Skip quietly if this app's team set does not carry the franchise — the demo
  # set is a convenience, never a reason for db:seed to fail.
  next unless Team.exists?(slug: team_slug)

  # gsis_id first: the two Justin Jeffersons resolve to one Person by name, so
  # looking up by person_slug alone would let the second overwrite the first.
  athlete = Athlete.find_by(gsis_id: gsis_id)

  if athlete.nil?
    person = Person.find_or_create_by_name!(first, last, athlete: true)

    # Same rule the nflverse importer uses: if that Person already has an
    # athlete, this is a DIFFERENT human sharing the name, and they get their
    # own Person with a stable slug suffix.
    if Athlete.exists?(person_slug: person.slug)
      person = Person.create!(first_name: first, last_name: last, athlete: true,
                              disambiguator: gsis_id.gsub(/\D/, "").last(4))
    end

    athlete = Athlete.new(person_slug: person.slug)
    created += 1
  end

  athlete.assign_attributes(
    sport: "football", team_slug: team_slug, position: position,
    jersey_number: jersey, height_inches: height, weight_lbs: weight,
    gsis_id: gsis_id, college_name: college
  )
  athlete.save!
end

# ONE ATHLETE WITH A CACHED HEADSHOT, and it is not decoration.
#
# The real roster is ~97% photographed, but this offline set cached nothing —
# so every environment seeded from it had ImageCache.count == 0 and EVERY card
# took the initials path. That made a whole class of bug untestable: a browser
# spec written for the headshot fallback passed identically on the fix and on
# the bug, because the scenario it described could not occur. Measured, not
# assumed: the spec's own trace showed one state throughout, and it was the
# correct one, on code that still had the defect.
#
# The key points at a real object in the shared bucket. Nothing fetches it in a
# test — a spec that cares routes the request — but its PRESENCE is what makes
# the photographed path reachable at all.
photographed = Athlete.find_by(person_slug: "josh-allen")
if photographed && photographed.image_caches.none? { |c| c.purpose == "headshot" }
  %w[original 100 400].each do |variant|
    ImageCache.create!(
      owner: photographed, purpose: "headshot", variant: variant,
      s3_key: "headshots/nfl/buffalo-bills/josh-allen/#{variant}.png",
      source_url: "https://a.espncdn.com/i/headshots/nfl/players/full/3918298.png",
      content_type: "image/png"
    )
  end
  photographed.update!(espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/3918298.png")
end

puts "  #{created} created, #{Athlete.count} athletes total (#{Person.athletes.count} people)"
puts "  #{ImageCache.where(purpose: "headshot").count} cached headshot variant(s) — the photographed path"
puts "  Full league: bin/rails nfl:players_seed  (then nfl:upload_headshots for avatars)"
