puts "Seeding Turf Picks..."

# Users (shared definitions across all seed files)
load Rails.root.join("db/seeds/users.rb")
core_users = seed_core_users!
admin = core_users["alex"]

# ─── Teams (all 48 World Cup 2026) ──────────────────────────────
# All 48 confirmed (playoff spots decided March 26-31, 2026)
TEAMS_DATA = [
  # Group A
  { name: "Mexico", short_name: "MEX", location: "Mexico", emoji: "🇲🇽", color_primary: "#006847", color_secondary: "#CE1126", group: "A" },
  { name: "South Korea", short_name: "KOR", location: "South Korea", emoji: "🇰🇷", color_primary: "#CD2E3A", color_secondary: "#0047A0", group: "A" },
  { name: "South Africa", short_name: "RSA", location: "South Africa", emoji: "🇿🇦", color_primary: "#007A4D", color_secondary: "#FFB612", group: "A" },
  { name: "Czechia", short_name: "CZE", location: "Czechia", emoji: "🇨🇿", color_primary: "#D7141A", color_secondary: "#11457E", group: "A" },
  # Group B
  { name: "Canada", short_name: "CAN", location: "Canada", emoji: "🇨🇦", color_primary: "#FF0000", color_secondary: "#FFFFFF", group: "B" },
  { name: "Bosnia and Herzegovina", short_name: "BIH", location: "Bosnia and Herzegovina", emoji: "🇧🇦", color_primary: "#003DA5", color_secondary: "#FCD116", group: "B" },
  { name: "Qatar", short_name: "QAT", location: "Qatar", emoji: "🇶🇦", color_primary: "#8A1538", color_secondary: "#FFFFFF", group: "B" },
  { name: "Switzerland", short_name: "SUI", location: "Switzerland", emoji: "🇨🇭", color_primary: "#FF0000", color_secondary: "#FFFFFF", group: "B" },
  # Group C
  { name: "Brazil", short_name: "BRA", location: "Brazil", emoji: "🇧🇷", color_primary: "#009C3B", color_secondary: "#FFDF00", group: "C" },
  { name: "Morocco", short_name: "MAR", location: "Morocco", emoji: "🇲🇦", color_primary: "#C1272D", color_secondary: "#006233", group: "C" },
  { name: "Haiti", short_name: "HAI", location: "Haiti", emoji: "🇭🇹", color_primary: "#00209F", color_secondary: "#D21034", group: "C" },
  { name: "Scotland", short_name: "SCO", location: "Scotland", emoji: "🏴󠁧󠁢󠁳󠁣󠁴󠁿", color_primary: "#003399", color_secondary: "#FFFFFF", group: "C" },
  # Group D
  { name: "United States", short_name: "USA", location: "United States", emoji: "🇺🇸", color_primary: "#002868", color_secondary: "#BF0A30", group: "D" },
  { name: "Paraguay", short_name: "PAR", location: "Paraguay", emoji: "🇵🇾", color_primary: "#D52B1E", color_secondary: "#0038A8", group: "D" },
  { name: "Australia", short_name: "AUS", location: "Australia", emoji: "🇦🇺", color_primary: "#00843D", color_secondary: "#FFCD00", group: "D" },
  { name: "Türkiye", short_name: "TUR", location: "Türkiye", emoji: "🇹🇷", color_primary: "#E30A17", color_secondary: "#FFFFFF", group: "D" },
  # Group E
  { name: "Germany", short_name: "GER", location: "Germany", emoji: "🇩🇪", color_primary: "#000000", color_secondary: "#DD0000", group: "E" },
  { name: "Curaçao", short_name: "CUW", location: "Curaçao", emoji: "🇨🇼", color_primary: "#003DA5", color_secondary: "#F9E814", group: "E" },
  { name: "Ivory Coast", short_name: "CIV", location: "Ivory Coast", emoji: "🇨🇮", color_primary: "#FF8200", color_secondary: "#009A44", group: "E" },
  { name: "Ecuador", short_name: "ECU", location: "Ecuador", emoji: "🇪🇨", color_primary: "#FFD100", color_secondary: "#003DA5", group: "E" },
  # Group F
  { name: "Netherlands", short_name: "NED", location: "Netherlands", emoji: "🇳🇱", color_primary: "#FF6600", color_secondary: "#FFFFFF", group: "F" },
  { name: "Japan", short_name: "JPN", location: "Japan", emoji: "🇯🇵", color_primary: "#000080", color_secondary: "#FFFFFF", group: "F" },
  { name: "Sweden", short_name: "SWE", location: "Sweden", emoji: "🇸🇪", color_primary: "#006AA7", color_secondary: "#FECC02", group: "F" },
  { name: "Tunisia", short_name: "TUN", location: "Tunisia", emoji: "🇹🇳", color_primary: "#E70013", color_secondary: "#FFFFFF", group: "F" },
  # Group G
  { name: "Belgium", short_name: "BEL", location: "Belgium", emoji: "🇧🇪", color_primary: "#ED2939", color_secondary: "#FAE042", group: "G" },
  { name: "Egypt", short_name: "EGY", location: "Egypt", emoji: "🇪🇬", color_primary: "#CE1126", color_secondary: "#FFFFFF", group: "G" },
  { name: "Iran", short_name: "IRN", location: "Iran", emoji: "🇮🇷", color_primary: "#239F40", color_secondary: "#DA0000", group: "G" },
  { name: "New Zealand", short_name: "NZL", location: "New Zealand", emoji: "🇳🇿", color_primary: "#000000", color_secondary: "#FFFFFF", group: "G" },
  # Group H
  { name: "Spain", short_name: "ESP", location: "Spain", emoji: "🇪🇸", color_primary: "#AA151B", color_secondary: "#F1BF00", group: "H" },
  { name: "Cape Verde", short_name: "CPV", location: "Cape Verde", emoji: "🇨🇻", color_primary: "#003893", color_secondary: "#CF2028", group: "H" },
  { name: "Saudi Arabia", short_name: "KSA", location: "Saudi Arabia", emoji: "🇸🇦", color_primary: "#006C35", color_secondary: "#FFFFFF", group: "H" },
  { name: "Uruguay", short_name: "URU", location: "Uruguay", emoji: "🇺🇾", color_primary: "#5CBFEB", color_secondary: "#FFFFFF", group: "H" },
  # Group I
  { name: "France", short_name: "FRA", location: "France", emoji: "🇫🇷", color_primary: "#002395", color_secondary: "#FFFFFF", group: "I" },
  { name: "Senegal", short_name: "SEN", location: "Senegal", emoji: "🇸🇳", color_primary: "#00853F", color_secondary: "#FDEF42", group: "I" },
  { name: "Iraq", short_name: "IRQ", location: "Iraq", emoji: "🇮🇶", color_primary: "#007A33", color_secondary: "#FFFFFF", group: "I" },
  { name: "Norway", short_name: "NOR", location: "Norway", emoji: "🇳🇴", color_primary: "#EF2B2D", color_secondary: "#002868", group: "I" },
  # Group J
  { name: "Argentina", short_name: "ARG", location: "Argentina", emoji: "🇦🇷", color_primary: "#75AADB", color_secondary: "#FFFFFF", group: "J" },
  { name: "Algeria", short_name: "ALG", location: "Algeria", emoji: "🇩🇿", color_primary: "#006633", color_secondary: "#FFFFFF", group: "J" },
  { name: "Austria", short_name: "AUT", location: "Austria", emoji: "🇦🇹", color_primary: "#ED2939", color_secondary: "#FFFFFF", group: "J" },
  { name: "Jordan", short_name: "JOR", location: "Jordan", emoji: "🇯🇴", color_primary: "#000000", color_secondary: "#007A3D", group: "J" },
  # Group K
  { name: "Portugal", short_name: "POR", location: "Portugal", emoji: "🇵🇹", color_primary: "#006600", color_secondary: "#FF0000", group: "K" },
  { name: "DR Congo", short_name: "COD", location: "DR Congo", emoji: "🇨🇩", color_primary: "#007FFF", color_secondary: "#CE1021", group: "K" },
  { name: "Uzbekistan", short_name: "UZB", location: "Uzbekistan", emoji: "🇺🇿", color_primary: "#0099CC", color_secondary: "#1EB53A", group: "K" },
  { name: "Colombia", short_name: "COL", location: "Colombia", emoji: "🇨🇴", color_primary: "#FCD116", color_secondary: "#003893", group: "K" },
  # Group L
  { name: "England", short_name: "ENG", location: "England", emoji: "🏴󠁧󠁢󠁥󠁮󠁧󠁿", color_primary: "#FFFFFF", color_secondary: "#CF081F", group: "L" },
  { name: "Croatia", short_name: "CRO", location: "Croatia", emoji: "🇭🇷", color_primary: "#FF0000", color_secondary: "#FFFFFF", group: "L" },
  { name: "Ghana", short_name: "GHA", location: "Ghana", emoji: "🇬🇭", color_primary: "#006B3F", color_secondary: "#FCD116", group: "L" },
  { name: "Panama", short_name: "PAN", location: "Panama", emoji: "🇵🇦", color_primary: "#DA121A", color_secondary: "#003893", group: "L" },
]

teams = {}
TEAMS_DATA.each do |data|
  team = Team.find_or_initialize_by(slug: data[:name].parameterize)
  team.assign_attributes(
    name: data[:name],
    short_name: data[:short_name],
    location: data[:location],
    emoji: data[:emoji],
    color_dark: data[:color_primary],
    color_light: data[:color_secondary],
    sport: "soccer",
    league: "fifa",
    division: "Group #{data[:group]}",
    rivals: []
  )
  team.save!
  teams[data[:short_name]] = team
end

puts "  Created #{Team.count} teams"

# ─── Games (all 72 group stage matches) ──────────────────────────
# Times are ET (EDT in June = UTC-4)
def et(year, month, day, hour, min = 0)
  Time.new(year, month, day, hour, min, 0, "-04:00")
end

GAMES_DATA = [
  # ── Matchday 1 ──────────────────────────────────────────────────
  # June 11
  { home: "MEX", away: "RSA", kickoff_at: et(2026, 6, 11, 15, 0),  venue: "Estadio Azteca, Mexico City",            group: "A" },
  { home: "KOR", away: "CZE", kickoff_at: et(2026, 6, 11, 22, 0),  venue: "Estadio Akron, Guadalajara",             group: "A" },
  # June 12
  { home: "CAN", away: "BIH", kickoff_at: et(2026, 6, 12, 15, 0),  venue: "BMO Field, Toronto",                     group: "B" },
  { home: "USA", away: "PAR", kickoff_at: et(2026, 6, 12, 21, 0),  venue: "SoFi Stadium, Los Angeles",              group: "D" },
  # June 13
  { home: "AUS", away: "TUR", kickoff_at: et(2026, 6, 13, 0, 0),   venue: "BC Place, Vancouver",                    group: "D" },
  { home: "QAT", away: "SUI", kickoff_at: et(2026, 6, 13, 15, 0),  venue: "Levi's Stadium, San Francisco",          group: "B" },
  { home: "BRA", away: "MAR", kickoff_at: et(2026, 6, 13, 18, 0),  venue: "MetLife Stadium, East Rutherford",       group: "C" },
  { home: "HAI", away: "SCO", kickoff_at: et(2026, 6, 13, 21, 0),  venue: "Gillette Stadium, Foxborough",           group: "C" },
  # June 14
  { home: "GER", away: "CUW", kickoff_at: et(2026, 6, 14, 13, 0),  venue: "NRG Stadium, Houston",                   group: "E" },
  { home: "NED", away: "JPN", kickoff_at: et(2026, 6, 14, 16, 0),  venue: "AT&T Stadium, Arlington",                group: "F" },
  { home: "CIV", away: "ECU", kickoff_at: et(2026, 6, 14, 19, 0),  venue: "Lincoln Financial Field, Philadelphia",  group: "E" },
  { home: "SWE", away: "TUN", kickoff_at: et(2026, 6, 14, 22, 0),  venue: "Estadio BBVA, Monterrey",                group: "F" },
  # June 15
  { home: "ESP", away: "CPV", kickoff_at: et(2026, 6, 15, 12, 0),  venue: "Mercedes-Benz Stadium, Atlanta",         group: "H" },
  { home: "BEL", away: "EGY", kickoff_at: et(2026, 6, 15, 15, 0),  venue: "Lumen Field, Seattle",                   group: "G" },
  { home: "KSA", away: "URU", kickoff_at: et(2026, 6, 15, 18, 0),  venue: "Hard Rock Stadium, Miami",               group: "H" },
  { home: "IRN", away: "NZL", kickoff_at: et(2026, 6, 15, 21, 0),  venue: "SoFi Stadium, Los Angeles",              group: "G" },
  # June 16
  { home: "FRA", away: "SEN", kickoff_at: et(2026, 6, 16, 15, 0),  venue: "MetLife Stadium, East Rutherford",       group: "I" },
  { home: "IRQ", away: "NOR", kickoff_at: et(2026, 6, 16, 18, 0),  venue: "Gillette Stadium, Foxborough",           group: "I" },
  { home: "ARG", away: "ALG", kickoff_at: et(2026, 6, 16, 21, 0),  venue: "Arrowhead Stadium, Kansas City",         group: "J" },
  { home: "AUT", away: "JOR", kickoff_at: et(2026, 6, 17, 0, 0),   venue: "Levi's Stadium, San Francisco",          group: "J" },
  # June 17
  { home: "POR", away: "COD", kickoff_at: et(2026, 6, 17, 13, 0),  venue: "NRG Stadium, Houston",                   group: "K" },
  { home: "ENG", away: "CRO", kickoff_at: et(2026, 6, 17, 16, 0),  venue: "AT&T Stadium, Arlington",                group: "L" },
  { home: "GHA", away: "PAN", kickoff_at: et(2026, 6, 17, 19, 0),  venue: "BMO Field, Toronto",                     group: "L" },
  { home: "UZB", away: "COL", kickoff_at: et(2026, 6, 17, 22, 0),  venue: "Estadio Azteca, Mexico City",            group: "K" },

  # ── Matchday 2 ──────────────────────────────────────────────────
  # June 18
  { home: "CZE", away: "RSA", kickoff_at: et(2026, 6, 18, 12, 0),  venue: "Mercedes-Benz Stadium, Atlanta",         group: "A" },
  { home: "SUI", away: "BIH", kickoff_at: et(2026, 6, 18, 15, 0),  venue: "SoFi Stadium, Los Angeles",              group: "B" },
  { home: "CAN", away: "QAT", kickoff_at: et(2026, 6, 18, 18, 0),  venue: "BC Place, Vancouver",                    group: "B" },
  { home: "MEX", away: "KOR", kickoff_at: et(2026, 6, 18, 21, 0),  venue: "Estadio Akron, Guadalajara",             group: "A" },
  # June 19
  { home: "USA", away: "AUS", kickoff_at: et(2026, 6, 19, 15, 0),  venue: "Lumen Field, Seattle",                   group: "D" },
  { home: "SCO", away: "MAR", kickoff_at: et(2026, 6, 19, 18, 0),  venue: "Gillette Stadium, Foxborough",           group: "C" },
  { home: "BRA", away: "HAI", kickoff_at: et(2026, 6, 19, 21, 0),  venue: "Lincoln Financial Field, Philadelphia",  group: "C" },
  { home: "TUR", away: "PAR", kickoff_at: et(2026, 6, 20, 0, 0),   venue: "Levi's Stadium, San Francisco",          group: "D" },
  # June 20
  { home: "NED", away: "SWE", kickoff_at: et(2026, 6, 20, 13, 0),  venue: "NRG Stadium, Houston",                   group: "F" },
  { home: "GER", away: "CIV", kickoff_at: et(2026, 6, 20, 16, 0),  venue: "BMO Field, Toronto",                     group: "E" },
  { home: "ECU", away: "CUW", kickoff_at: et(2026, 6, 20, 20, 0),  venue: "Arrowhead Stadium, Kansas City",         group: "E" },
  { home: "TUN", away: "JPN", kickoff_at: et(2026, 6, 21, 0, 0),   venue: "Estadio BBVA, Monterrey",                group: "F" },
  # June 21
  { home: "ESP", away: "KSA", kickoff_at: et(2026, 6, 21, 12, 0),  venue: "Mercedes-Benz Stadium, Atlanta",         group: "H" },
  { home: "BEL", away: "IRN", kickoff_at: et(2026, 6, 21, 15, 0),  venue: "SoFi Stadium, Los Angeles",              group: "G" },
  { home: "URU", away: "CPV", kickoff_at: et(2026, 6, 21, 18, 0),  venue: "Hard Rock Stadium, Miami",               group: "H" },
  { home: "NZL", away: "EGY", kickoff_at: et(2026, 6, 21, 21, 0),  venue: "BC Place, Vancouver",                    group: "G" },
  # June 22
  { home: "ARG", away: "AUT", kickoff_at: et(2026, 6, 22, 13, 0),  venue: "AT&T Stadium, Arlington",                group: "J" },
  { home: "FRA", away: "IRQ", kickoff_at: et(2026, 6, 22, 17, 0),  venue: "Lincoln Financial Field, Philadelphia",  group: "I" },
  { home: "NOR", away: "SEN", kickoff_at: et(2026, 6, 22, 20, 0),  venue: "MetLife Stadium, East Rutherford",       group: "I" },
  { home: "JOR", away: "ALG", kickoff_at: et(2026, 6, 22, 23, 0),  venue: "Levi's Stadium, San Francisco",          group: "J" },
  # June 23
  { home: "POR", away: "UZB", kickoff_at: et(2026, 6, 23, 13, 0),  venue: "NRG Stadium, Houston",                   group: "K" },
  { home: "ENG", away: "GHA", kickoff_at: et(2026, 6, 23, 16, 0),  venue: "Gillette Stadium, Foxborough",           group: "L" },
  { home: "PAN", away: "CRO", kickoff_at: et(2026, 6, 23, 19, 0),  venue: "BMO Field, Toronto",                     group: "L" },
  { home: "COL", away: "COD", kickoff_at: et(2026, 6, 23, 22, 0),  venue: "Estadio Akron, Guadalajara",             group: "K" },

  # ── Matchday 3 ──────────────────────────────────────────────────
  # June 24
  { home: "SUI", away: "CAN", kickoff_at: et(2026, 6, 24, 15, 0),  venue: "BC Place, Vancouver",                    group: "B" },
  { home: "BIH", away: "QAT", kickoff_at: et(2026, 6, 24, 15, 0),  venue: "Lumen Field, Seattle",                   group: "B" },
  { home: "SCO", away: "BRA", kickoff_at: et(2026, 6, 24, 18, 0),  venue: "Hard Rock Stadium, Miami",               group: "C" },
  { home: "MAR", away: "HAI", kickoff_at: et(2026, 6, 24, 18, 0),  venue: "Mercedes-Benz Stadium, Atlanta",         group: "C" },
  { home: "CZE", away: "MEX", kickoff_at: et(2026, 6, 24, 21, 0),  venue: "Estadio Azteca, Mexico City",            group: "A" },
  { home: "RSA", away: "KOR", kickoff_at: et(2026, 6, 24, 21, 0),  venue: "Estadio BBVA, Monterrey",                group: "A" },
  # June 25
  { home: "CUW", away: "CIV", kickoff_at: et(2026, 6, 25, 16, 0),  venue: "Lincoln Financial Field, Philadelphia",  group: "E" },
  { home: "ECU", away: "GER", kickoff_at: et(2026, 6, 25, 16, 0),  venue: "MetLife Stadium, East Rutherford",       group: "E" },
  { home: "JPN", away: "SWE", kickoff_at: et(2026, 6, 25, 19, 0),  venue: "AT&T Stadium, Arlington",                group: "F" },
  { home: "TUN", away: "NED", kickoff_at: et(2026, 6, 25, 19, 0),  venue: "Arrowhead Stadium, Kansas City",         group: "F" },
  { home: "TUR", away: "USA", kickoff_at: et(2026, 6, 25, 22, 0),  venue: "SoFi Stadium, Los Angeles",              group: "D" },
  { home: "PAR", away: "AUS", kickoff_at: et(2026, 6, 25, 22, 0),  venue: "Levi's Stadium, San Francisco",          group: "D" },
  # June 26
  { home: "NOR", away: "FRA", kickoff_at: et(2026, 6, 26, 15, 0),  venue: "Gillette Stadium, Foxborough",           group: "I" },
  { home: "SEN", away: "IRQ", kickoff_at: et(2026, 6, 26, 15, 0),  venue: "BMO Field, Toronto",                     group: "I" },
  { home: "CPV", away: "KSA", kickoff_at: et(2026, 6, 26, 20, 0),  venue: "NRG Stadium, Houston",                   group: "H" },
  { home: "URU", away: "ESP", kickoff_at: et(2026, 6, 26, 20, 0),  venue: "Estadio Akron, Guadalajara",             group: "H" },
  { home: "EGY", away: "IRN", kickoff_at: et(2026, 6, 26, 23, 0),  venue: "Lumen Field, Seattle",                   group: "G" },
  { home: "NZL", away: "BEL", kickoff_at: et(2026, 6, 26, 23, 0),  venue: "BC Place, Vancouver",                    group: "G" },
  # June 27
  { home: "PAN", away: "ENG", kickoff_at: et(2026, 6, 27, 17, 0),  venue: "MetLife Stadium, East Rutherford",       group: "L" },
  { home: "CRO", away: "GHA", kickoff_at: et(2026, 6, 27, 17, 0),  venue: "Lincoln Financial Field, Philadelphia",  group: "L" },
  { home: "COL", away: "POR", kickoff_at: et(2026, 6, 27, 19, 30), venue: "Hard Rock Stadium, Miami",               group: "K" },
  { home: "COD", away: "UZB", kickoff_at: et(2026, 6, 27, 19, 30), venue: "Mercedes-Benz Stadium, Atlanta",         group: "K" },
  { home: "ALG", away: "AUT", kickoff_at: et(2026, 6, 27, 22, 0),  venue: "Arrowhead Stadium, Kansas City",         group: "J" },
  { home: "JOR", away: "ARG", kickoff_at: et(2026, 6, 27, 22, 0),  venue: "AT&T Stadium, Arlington",                group: "J" },
]

GAMES_DATA.each do |data|
  home_team = teams[data[:home]]
  away_team = teams[data[:away]]

  next unless home_team && away_team

  Game.find_or_create_by!(home_team_slug: home_team.slug, away_team_slug: away_team.slug) do |g|
    g.kickoff_at = data[:kickoff_at]
    g.venue = data[:venue]
    g.status = "scheduled"
  end
end

puts "  Created #{Game.count} games"

# ─── Players (notable starters, ~3-5 per team) ──────────────────
PLAYERS_DATA = {
  "ARG" => [
    { name: "Lionel Messi", position: "Forward", jersey_number: 10 },
    { name: "Julián Álvarez", position: "Forward", jersey_number: 9 },
    { name: "Enzo Fernández", position: "Midfielder", jersey_number: 24 },
    { name: "Emiliano Martínez", position: "Goalkeeper", jersey_number: 23 },
  ],
  "BRA" => [
    { name: "Vinícius Júnior", position: "Forward", jersey_number: 7 },
    { name: "Rodrygo", position: "Forward", jersey_number: 11 },
    { name: "Endrick", position: "Forward", jersey_number: 9 },
    { name: "Alisson", position: "Goalkeeper", jersey_number: 1 },
  ],
  "FRA" => [
    { name: "Kylian Mbappé", position: "Forward", jersey_number: 10 },
    { name: "Antoine Griezmann", position: "Forward", jersey_number: 7 },
    { name: "Aurélien Tchouaméni", position: "Midfielder", jersey_number: 8 },
  ],
  "GER" => [
    { name: "Florian Wirtz", position: "Midfielder", jersey_number: 10 },
    { name: "Jamal Musiala", position: "Midfielder", jersey_number: 14 },
    { name: "Kai Havertz", position: "Forward", jersey_number: 7 },
  ],
  "ESP" => [
    { name: "Lamine Yamal", position: "Forward", jersey_number: 19 },
    { name: "Pedri", position: "Midfielder", jersey_number: 8 },
    { name: "Rodri", position: "Midfielder", jersey_number: 16 },
  ],
  "ENG" => [
    { name: "Jude Bellingham", position: "Midfielder", jersey_number: 10 },
    { name: "Harry Kane", position: "Forward", jersey_number: 9 },
    { name: "Bukayo Saka", position: "Forward", jersey_number: 7 },
    { name: "Phil Foden", position: "Midfielder", jersey_number: 11 },
  ],
  "POR" => [
    { name: "Cristiano Ronaldo", position: "Forward", jersey_number: 7 },
    { name: "Bruno Fernandes", position: "Midfielder", jersey_number: 8 },
    { name: "Bernardo Silva", position: "Midfielder", jersey_number: 10 },
  ],
  "NED" => [
    { name: "Cody Gakpo", position: "Forward", jersey_number: 11 },
    { name: "Virgil van Dijk", position: "Defender", jersey_number: 4 },
    { name: "Frenkie de Jong", position: "Midfielder", jersey_number: 21 },
  ],
  "BEL" => [
    { name: "Kevin De Bruyne", position: "Midfielder", jersey_number: 7 },
    { name: "Romelu Lukaku", position: "Forward", jersey_number: 9 },
    { name: "Jérémy Doku", position: "Forward", jersey_number: 11 },
  ],
  "URU" => [
    { name: "Darwin Núñez", position: "Forward", jersey_number: 11 },
    { name: "Federico Valverde", position: "Midfielder", jersey_number: 15 },
    { name: "Ronald Araújo", position: "Defender", jersey_number: 4 },
  ],
  "MEX" => [
    { name: "Hirving Lozano", position: "Forward", jersey_number: 22 },
    { name: "Raúl Jiménez", position: "Forward", jersey_number: 9 },
    { name: "Edson Álvarez", position: "Midfielder", jersey_number: 4 },
  ],
  "USA" => [
    { name: "Christian Pulisic", position: "Forward", jersey_number: 10 },
    { name: "Weston McKennie", position: "Midfielder", jersey_number: 8 },
    { name: "Tyler Adams", position: "Midfielder", jersey_number: 4 },
    { name: "Gio Reyna", position: "Forward", jersey_number: 7 },
  ],
  "JPN" => [
    { name: "Takefusa Kubo", position: "Forward", jersey_number: 11 },
    { name: "Kaoru Mitoma", position: "Forward", jersey_number: 9 },
    { name: "Wataru Endo", position: "Midfielder", jersey_number: 6 },
  ],
  "KOR" => [
    { name: "Son Heung-min", position: "Forward", jersey_number: 7 },
    { name: "Lee Kang-in", position: "Midfielder", jersey_number: 10 },
    { name: "Kim Min-jae", position: "Defender", jersey_number: 3 },
  ],
  "CRO" => [
    { name: "Luka Modrić", position: "Midfielder", jersey_number: 10 },
    { name: "Mateo Kovačić", position: "Midfielder", jersey_number: 8 },
    { name: "Joško Gvardiol", position: "Defender", jersey_number: 20 },
  ],
  "SEN" => [
    { name: "Sadio Mané", position: "Forward", jersey_number: 10 },
    { name: "Kalidou Koulibaly", position: "Defender", jersey_number: 3 },
    { name: "Ismaïla Sarr", position: "Forward", jersey_number: 18 },
  ],
  "MAR" => [
    { name: "Achraf Hakimi", position: "Defender", jersey_number: 2 },
    { name: "Hakim Ziyech", position: "Forward", jersey_number: 7 },
    { name: "Youssef En-Nesyri", position: "Forward", jersey_number: 9 },
  ],
  "COL" => [
    { name: "Luis Díaz", position: "Forward", jersey_number: 7 },
    { name: "James Rodríguez", position: "Midfielder", jersey_number: 10 },
    { name: "Jhon Durán", position: "Forward", jersey_number: 9 },
  ],
  "CAN" => [
    { name: "Alphonso Davies", position: "Defender", jersey_number: 19 },
    { name: "Jonathan David", position: "Forward", jersey_number: 9 },
    { name: "Cyle Larin", position: "Forward", jersey_number: 17 },
  ],
  "AUS" => [
    { name: "Mathew Ryan", position: "Goalkeeper", jersey_number: 1 },
    { name: "Jackson Irvine", position: "Midfielder", jersey_number: 22 },
    { name: "Mitchell Duke", position: "Forward", jersey_number: 13 },
  ],
  "ECU" => [
    { name: "Moisés Caicedo", position: "Midfielder", jersey_number: 23 },
    { name: "Enner Valencia", position: "Forward", jersey_number: 13 },
    { name: "Piero Hincapié", position: "Defender", jersey_number: 3 },
  ],
  "BIH" => [
    { name: "Edin Džeko", position: "Forward", jersey_number: 11 },
    { name: "Ermedin Demirović", position: "Forward", jersey_number: 9 },
    { name: "Haris Tabaković", position: "Forward", jersey_number: 19 },
  ],
  "SWE" => [
    { name: "Viktor Gyökeres", position: "Forward", jersey_number: 9 },
    { name: "Alexander Isak", position: "Forward", jersey_number: 11 },
    { name: "Dejan Kulusevski", position: "Midfielder", jersey_number: 21 },
  ],
  "TUR" => [
    { name: "Arda Güler", position: "Midfielder", jersey_number: 8 },
    { name: "Hakan Çalhanoğlu", position: "Midfielder", jersey_number: 10 },
    { name: "Kenan Yıldız", position: "Forward", jersey_number: 18 },
  ],
  "CZE" => [
    { name: "Tomáš Souček", position: "Midfielder", jersey_number: 15 },
    { name: "Patrik Schick", position: "Forward", jersey_number: 19 },
    { name: "Adam Hložek", position: "Forward", jersey_number: 21 },
  ],
  "COD" => [
    { name: "Cédric Bakambu", position: "Forward", jersey_number: 9 },
    { name: "Chancel Mbemba", position: "Defender", jersey_number: 22 },
    { name: "Simon Banza", position: "Forward", jersey_number: 7 },
  ],
  "IRQ" => [
    { name: "Aymen Hussein", position: "Forward", jersey_number: 9 },
    { name: "Ali Al-Hamadi", position: "Forward", jersey_number: 11 },
    { name: "Ibrahim Bayesh", position: "Midfielder", jersey_number: 14 },
  ],
}

PLAYERS_DATA.each do |short_name, players|
  team = teams[short_name]
  next unless team

  players.each do |data|
    Player.find_or_create_by!(slug: data[:name].parameterize) do |p|
      p.team_slug = team.slug
      p.name = data[:name]
      p.position = data[:position]
      p.jersey_number = data[:jersey_number]
    end
  end
end

puts "  Created #{Player.count} players"

# ─── DraftKings Odds Data ──────────────────────────────────────
dk_odds_path = File.join(Rails.root, "scripts", "data", "draftkings_team_totals.json")
dk_odds = {}

if File.exist?(dk_odds_path)
  raw = JSON.parse(File.read(dk_odds_path))
  raw.each do |entry|
    next unless entry["short_name"].present? && entry["line"].present?
    # Key by "TEAM-vs-OPPONENT" so odds are game-specific
    opp = entry["opponent_short_name"]
    key = opp ? "#{entry["short_name"]}-vs-#{opp}" : entry["short_name"]
    dk_odds[key] = entry
  end
  puts "  Loaded #{dk_odds.size} DraftKings odds entries" if dk_odds.any?
end

# ─── Matchday Game Pairs ──────────────────────────────────────
MATCHDAY_1_GAMES = [
  # June 11
  { home: "MEX", away: "RSA" },
  { home: "KOR", away: "CZE" },
  # June 12
  { home: "CAN", away: "BIH" },
  { home: "USA", away: "PAR" },
  # June 13
  { home: "AUS", away: "TUR" },
  { home: "QAT", away: "SUI" },
  { home: "BRA", away: "MAR" },
  { home: "HAI", away: "SCO" },
  # June 14
  { home: "GER", away: "CUW" },
  { home: "NED", away: "JPN" },
  { home: "CIV", away: "ECU" },
  { home: "SWE", away: "TUN" },
  # June 15
  { home: "ESP", away: "CPV" },
  { home: "BEL", away: "EGY" },
  { home: "KSA", away: "URU" },
  { home: "IRN", away: "NZL" },
  # June 16
  { home: "FRA", away: "SEN" },
  { home: "IRQ", away: "NOR" },
  { home: "ARG", away: "ALG" },
  { home: "AUT", away: "JOR" },
  # June 17
  { home: "POR", away: "COD" },
  { home: "ENG", away: "CRO" },
  { home: "GHA", away: "PAN" },
  { home: "UZB", away: "COL" },
]

MATCHDAY_2_GAMES = [
  # June 18
  { home: "CZE", away: "RSA" },
  { home: "SUI", away: "BIH" },
  { home: "CAN", away: "QAT" },
  { home: "MEX", away: "KOR" },
  # June 19
  { home: "USA", away: "AUS" },
  { home: "SCO", away: "MAR" },
  { home: "BRA", away: "HAI" },
  { home: "TUR", away: "PAR" },
  # June 20
  { home: "NED", away: "SWE" },
  { home: "GER", away: "CIV" },
  { home: "ECU", away: "CUW" },
  { home: "TUN", away: "JPN" },
  # June 21
  { home: "ESP", away: "KSA" },
  { home: "BEL", away: "IRN" },
  { home: "URU", away: "CPV" },
  { home: "NZL", away: "EGY" },
  # June 22
  { home: "ARG", away: "AUT" },
  { home: "FRA", away: "IRQ" },
  { home: "NOR", away: "SEN" },
  { home: "JOR", away: "ALG" },
  # June 23
  { home: "POR", away: "UZB" },
  { home: "ENG", away: "GHA" },
  { home: "PAN", away: "CRO" },
  { home: "COL", away: "COD" },
]

MATCHDAY_3_GAMES = [
  # June 24
  { home: "SUI", away: "CAN" },
  { home: "BIH", away: "QAT" },
  { home: "SCO", away: "BRA" },
  { home: "MAR", away: "HAI" },
  { home: "CZE", away: "MEX" },
  { home: "RSA", away: "KOR" },
  # June 25
  { home: "CUW", away: "CIV" },
  { home: "ECU", away: "GER" },
  { home: "JPN", away: "SWE" },
  { home: "TUN", away: "NED" },
  { home: "TUR", away: "USA" },
  { home: "PAR", away: "AUS" },
  # June 26
  { home: "NOR", away: "FRA" },
  { home: "SEN", away: "IRQ" },
  { home: "CPV", away: "KSA" },
  { home: "URU", away: "ESP" },
  { home: "EGY", away: "IRN" },
  { home: "NZL", away: "BEL" },
  # June 27
  { home: "PAN", away: "ENG" },
  { home: "CRO", away: "GHA" },
  { home: "COL", away: "POR" },
  { home: "COD", away: "UZB" },
  { home: "ALG", away: "AUT" },
  { home: "JOR", away: "ARG" },
]

# ─── General DK Power Rankings (outright odds to win tournament) ──
# Source: FOX Sports / DraftKings, April 2026
# Lower odds = stronger team = higher rank = lower multiplier
GENERAL_DK_ODDS = {
  "ESP" => 450,   "FRA" => 600,   "ENG" => 600,   "BRA" => 850,
  "ARG" => 850,   "POR" => 1100,  "GER" => 1400,  "NED" => 2000,
  "NOR" => 2800,  "BEL" => 3500,  "COL" => 4000,  "JPN" => 5000,
  "MAR" => 6000,  "URU" => 6500,  "USA" => 6500,  "TUR" => 6500,
  "MEX" => 7000,  "SWE" => 8000,  "ECU" => 8000,  "CRO" => 9000,
  "SUI" => 10000, "SEN" => 10000, "AUT" => 10000, "CZE" => 15000,
  "CAN" => 20000, "PAR" => 20000, "SCO" => 20000, "CIV" => 25000,
  "BIH" => 25000, "EGY" => 30000, "IRN" => 30000, "ALG" => 35000,
  "KOR" => 35000, "GHA" => 35000, "AUS" => 45000, "TUN" => 50000,
  "COD" => 70000, "RSA" => 80000, "KSA" => 100000, "PAN" => 100000,
  "NZL" => 100000, "QAT" => 100000, "CPV" => 100000, "IRQ" => 100000,
  "UZB" => 150000, "JOR" => 150000, "HAI" => 150000, "CUW" => 150000,
}

# ─── Slate + Contest Helper ──────────────────────────────────
def create_slate_with_contest(slate_name:, contest_name:, games:, teams:, dk_odds:, starts_at:, general_rankings: false, tagline: nil, user: nil, contest_type: "standard")
  slate = Slate.find_or_create_by!(name: slate_name) do |s|
    s.starts_at = starts_at
  end

  format = Contest::FORMATS[contest_type] || Contest::FORMATS["standard"]

  contest = Contest.find_or_create_by!(name: contest_name) do |c|
    c.slate = slate
    c.contest_type = contest_type
    c.entry_fee_cents = format[:entry_fee_cents]
    c.max_entries = format[:max_entries]
    c.status = "open"
    c.starts_at = starts_at
    c.tagline = tagline
    c.user = user if user
  end
  contest.update!(slate: slate) if contest.slate_id.nil?
  contest.update!(tagline: tagline) if tagline && contest.tagline.blank?
  contest.update!(user: user) if user && contest.user_id.nil?

  puts "  Created slate: #{slate.name}, contest: #{contest.name}"

  games.each do |data|
    home_team = teams[data[:home]]
    away_team = teams[data[:away]]
    game = Game.find_by(home_team_slug: home_team&.slug, away_team_slug: away_team&.slug)

    next unless home_team && away_team

    SlateMatchup.find_or_create_by!(slate: slate, team_slug: home_team.slug) do |m|
      m.opponent_team_slug = away_team.slug
      m.game_slug = game&.slug
    end

    SlateMatchup.find_or_create_by!(slate: slate, team_slug: away_team.slug) do |m|
      m.opponent_team_slug = home_team.slug
      m.game_slug = game&.slug
    end
  end

  matchups = slate.slate_matchups.includes(:team).to_a

  if general_rankings
    # Rank by general DK outright odds (lower odds = stronger team = higher rank)
    sorted = matchups.sort_by do |m|
      team_data = TEAMS_DATA.find { |t| t[:name].parameterize == m.team_slug }
      short_name = team_data&.dig(:short_name)
      odds = GENERAL_DK_ODDS[short_name] || 999999
      [odds, m.team.name]
    end
  elsif dk_odds.any?
    # Populate game-specific DK odds + compute dk_score
    matchups.each do |m|
      team_data = TEAMS_DATA.find { |t| t[:name].parameterize == m.team_slug }
      opp_data = TEAMS_DATA.find { |t| t[:name].parameterize == m.opponent_team_slug }
      short_name = team_data&.dig(:short_name)
      opp_short = opp_data&.dig(:short_name)
      dk = dk_odds["#{short_name}-vs-#{opp_short}"] || dk_odds[short_name]
      next unless dk

      line = dk["line"]&.to_f

      m.update!(expected_score: line)
    end

    # Rank by expected_score DESC. Teams without DK data sort to end alphabetically.
    sorted = matchups.sort_by do |m|
      if m.expected_score.present?
        [0, -m.expected_score.to_f, m.team.name]
      else
        [1, 0, m.team.name]
      end
    end
  else
    sorted = matchups.sort_by { |m| m.team.name }
  end

  n = sorted.size
  sorted.each_with_index do |matchup, i|
    rank = i + 1
    matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, n))
  end

  matchup_count = slate.slate_matchups.count
  puts "  Created #{matchup_count} slate matchups with rankings"

  contest
end

# ─── Create Slates (no demo contests) ────────────────────────
# Each matchday gets a Slate + its SlateMatchups. Contests are NOT created
# during seed — they're created intentionally per the GTM playbook via
# the admin UI or via dedicated scripts (see scripts/create_friend_test_contest.rb).
#
# Why no demo contests: contest data (entries, payouts, multisig settlement)
# is the production surface we want to test deliberately. Seeding fake
# contests creates noise that obscures real behavior and risks confusing
# friend-test participants about what's real vs scaffolding.
[
  ["World Cup 2026 Group 1", MATCHDAY_1_GAMES, et(2026, 6, 11, 15, 0)],
  ["World Cup 2026 Group 2", MATCHDAY_2_GAMES, et(2026, 6, 18, 12, 0)],
  ["World Cup 2026 Group 3", MATCHDAY_3_GAMES, et(2026, 6, 24, 15, 0)]
].each do |slate_name, games, starts_at|
  slate = Slate.find_or_create_by!(name: slate_name) { |s| s.starts_at = starts_at }
  games.each do |data|
    home_team = teams[data[:home]]
    away_team = teams[data[:away]]
    next unless home_team && away_team
    game = Game.find_by(home_team_slug: home_team.slug, away_team_slug: away_team.slug)
    SlateMatchup.find_or_create_by!(slate: slate, team_slug: home_team.slug) do |m|
      m.opponent_team_slug = away_team.slug
      m.game_slug = game&.slug
    end
    SlateMatchup.find_or_create_by!(slate: slate, team_slug: away_team.slug) do |m|
      m.opponent_team_slug = home_team.slug
      m.game_slug = game&.slug
    end
  end

  # Rank + score matchups by GENERAL_DK_ODDS (lower odds = stronger team = higher
  # rank). Without this, contests created against these slates render with nil
  # turf_score and crash the leaderboard partial. Idempotent — re-running seed
  # updates existing matchups via .update! on the find_or_create_by! result.
  matchups = slate.slate_matchups.includes(:team).to_a
  sorted = matchups.sort_by do |m|
    team_data = TEAMS_DATA.find { |t| t[:name].parameterize == m.team_slug }
    short_name = team_data&.dig(:short_name)
    [GENERAL_DK_ODDS[short_name] || 999_999, m.team.name]
  end
  n = sorted.size
  sorted.each_with_index do |matchup, i|
    rank = i + 1
    matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, n))
  end

  puts "  Created slate: #{slate.name} (#{slate.slate_matchups.count} matchups, ranked)"
end

WorldCup2026KnockoutSeed.call(teams_by_code: teams, ranking_odds: GENERAL_DK_ODDS)
puts "  Created World Cup knockout slates (#{WorldCup2026KnockoutSeed::FIXTURES.size} games)"

# ─── NFL 2026 Regular Season Weeks 1-17 ───────────────────────
load Rails.root.join("db/seeds/nfl_2026.rb")

# ─── NFL 2026 Expected Team Totals ────────────────────────────
load Rails.root.join("db/seeds/nfl_expected_team_totals_2026.rb")

# ─── Default Slate (formula defaults record) ──────────────────
Slate.find_or_create_by!(name: "Default")
puts "  Created Default slate for formula defaults"

# ─── Geo Settings ──────────────────────────────────────────
Studio::GeoSetting.find_or_create_by!(app_name: "Turf Monster") do |gs|
  gs.enabled = false
  gs.banned_subdivisions = Studio.geo_default_banned_subdivisions
end
puts "  Created Studio::GeoSetting (enabled: #{Studio::GeoSetting.current.enabled?})"

# ─── Season (on-chain seed schedule, turf-vault v0.11.0+) ────
# DB pointer is always set (cheap). On-chain Season creation is best-effort —
# if turf-vault isn't deployed yet, the seed logs a warning and continues so
# `bin/rails db:seed` works in any environment (CI, fresh dev, prod).
SEASON_ID = 1
SEASON_NAME = "World Cup 2026"
SEASON_SCHEDULE = Solana::Vault::SEASON_DEFAULT_SCHEDULE # [25, 19, 14, 10, 7]

begin
  vault = Solana::Vault.new
  if vault.get_season(SEASON_ID)
    puts "  Season #{SEASON_ID} already on-chain (skipping mint)"
  else
    result = vault.create_season(season_id: SEASON_ID, name: SEASON_NAME, schedule: SEASON_SCHEDULE)
    puts "  Created on-chain Season #{SEASON_ID} \"#{SEASON_NAME}\" #{SEASON_SCHEDULE.inspect}"
    puts "    TX: #{result[:signature]}"
  end

  SeasonConfig.set_current!(SEASON_ID)
  puts "  Set SeasonConfig.current_season_id = #{SEASON_ID}"
rescue => e
  puts "  ⚠️  Could not bootstrap on-chain Season: #{e.message}"
  fallback_season = begin
    Array(vault&.list_seasons).max_by { |s| s[:season_id].to_i }
  rescue
    nil
  end
  if fallback_season
    SeasonConfig.set_current!(fallback_season[:season_id])
    puts "     Using existing on-chain Season #{fallback_season[:season_id]} as current instead."
  else
    puts "     Deploy turf-vault first: cd ../turf-vault && anchor deploy --provider.cluster devnet"
    puts "     Then re-run `bin/rails db:seed` to finish the on-chain bootstrap."
  end
end

# ─── DK team-total odds cache (soccer formula report samples) ─
# Writes the checked-in 2026 World Cup group-stage DK odds onto the fifa-slate
# matchups so /slates/formula_report renders live samples straight off a seed.
if Soccer::CacheTeamTotalOdds::DEFAULT_PATH.exist?
  odds = Soccer::CacheTeamTotalOdds.call
  puts "  Cached DK team-total odds (#{odds.rows} rows, #{odds.matchups_updated} matchups updated" \
       "#{odds.teams_missing.any? ? ", missing teams: #{odds.teams_missing.join(', ')}" : ''})"
end

# ─── Dev demo contest (rolling 3-week NFL span) ───────────────
# DEVELOPMENT ONLY — the no-demo-contests rule above holds for QA and
# production; a fresh worktree needs a contest to play with or /contests just
# reads "No contests yet."
#
# Placed AFTER the Season bootstrap on purpose. Contest's before_create stamps
# `season_id ||= SeasonConfig.current_season_id`, and 0 is truthy in Ruby — a
# contest created before the bootstrap keeps season_id 0 for good, which would
# bind a later `create_onchain!` to a Season that doesn't exist. It still runs
# after the NFL blocks either way, since the span slate is assembled from their
# weekly slates.
#
# Never fatal: a worktree's `bin/rails db:prepare` must finish even when the
# span can't build.
if Rails.env.development?
  load Rails.root.join("db/seeds/nfl_demo_contest.rb")
  begin
    seed_nfl_demo_contest!
  rescue => e
    puts "  ⚠️  Could not seed the dev demo contest: #{e.message}"
  end
end

# ─── Landing pages (marketing funnels) ───────────────────────
load Rails.root.join("db/seeds/landing_pages.rb")

puts "Done! #{User.count} users, #{Slate.count} slates, #{Contest.count} contests, #{Entry.count} entries"
puts "  #{Team.count} teams, #{Game.count} games, #{Player.count} players, #{SlateMatchup.count} matchups, #{LandingPage.count} landing pages"
