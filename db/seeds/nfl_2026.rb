# frozen_string_literal: true

data_path = Rails.root.join("db/seeds/data/nfl_2026_weeks_1_17.json")
data = JSON.parse(File.read(data_path))

puts "  Loading NFL #{data.fetch("season")} schedule from #{data.fetch("generated_at")}"

nfl_home_arenas = {
  "state-farm-stadium" => { name: "State Farm Stadium", address: "1 Cardinals Drive", location: "Glendale, AZ", city: "Glendale", state: "AZ", country: "USA", timezone: "America/Phoenix" },
  "mercedes-benz-stadium" => { name: "Mercedes-Benz Stadium", address: "1 AMB Drive NW", location: "Atlanta, GA", city: "Atlanta", state: "GA", country: "USA", timezone: "America/New_York" },
  "m-t-bank-stadium" => { name: "M&T Bank Stadium", address: "1101 Russell Street", location: "Baltimore, MD", city: "Baltimore", state: "MD", country: "USA", timezone: "America/New_York" },
  "highmark-stadium" => { name: "Highmark Stadium", address: "1 Bills Drive", location: "Orchard Park, NY", city: "Orchard Park", state: "NY", country: "USA", timezone: "America/New_York" },
  "bank-of-america-stadium" => { name: "Bank of America Stadium", address: "800 S Mint Street", location: "Charlotte, NC", city: "Charlotte", state: "NC", country: "USA", timezone: "America/New_York" },
  "soldier-field" => { name: "Soldier Field", address: "1410 Special Olympics Drive", location: "Chicago, IL", city: "Chicago", state: "IL", country: "USA", timezone: "America/Chicago" },
  "paycor-stadium" => { name: "Paycor Stadium", address: "1 Paycor Stadium", location: "Cincinnati, OH", city: "Cincinnati", state: "OH", country: "USA", timezone: "America/New_York" },
  "huntington-bank-field" => { name: "Huntington Bank Field", address: "100 Alfred Lerner Way", location: "Cleveland, OH", city: "Cleveland", state: "OH", country: "USA", timezone: "America/New_York" },
  "at-t-stadium" => { name: "AT&T Stadium", address: "1 AT&T Way", location: "Arlington, TX", city: "Arlington", state: "TX", country: "USA", timezone: "America/Chicago" },
  "empower-field-at-mile-high" => { name: "Empower Field at Mile High", address: "1701 Bryant Street", location: "Denver, CO", city: "Denver", state: "CO", country: "USA", timezone: "America/Denver" },
  "ford-field" => { name: "Ford Field", address: "2000 Brush Street", location: "Detroit, MI", city: "Detroit", state: "MI", country: "USA", timezone: "America/New_York" },
  "lambeau-field" => { name: "Lambeau Field", address: "1265 Lombardi Avenue", location: "Green Bay, WI", city: "Green Bay", state: "WI", country: "USA", timezone: "America/Chicago" },
  "nrg-stadium" => { name: "NRG Stadium", address: "One NRG Park", location: "Houston, TX", city: "Houston", state: "TX", country: "USA", timezone: "America/Chicago" },
  "lucas-oil-stadium" => { name: "Lucas Oil Stadium", address: "500 S Capitol Avenue", location: "Indianapolis, IN", city: "Indianapolis", state: "IN", country: "USA", timezone: "America/Indiana/Indianapolis" },
  "everbank-stadium" => { name: "EverBank Stadium", address: "1 EverBank Stadium Drive", location: "Jacksonville, FL", city: "Jacksonville", state: "FL", country: "USA", timezone: "America/New_York" },
  "geha-field-at-arrowhead-stadium" => { name: "GEHA Field at Arrowhead Stadium", address: "1 Arrowhead Drive", location: "Kansas City, MO", city: "Kansas City", state: "MO", country: "USA", timezone: "America/Chicago" },
  "sofi-stadium" => { name: "SoFi Stadium", address: "1001 Stadium Drive", location: "Inglewood, CA", city: "Inglewood", state: "CA", country: "USA", timezone: "America/Los_Angeles" },
  "allegiant-stadium" => { name: "Allegiant Stadium", address: "3333 Al Davis Way", location: "Las Vegas, NV", city: "Las Vegas", state: "NV", country: "USA", timezone: "America/Los_Angeles" },
  "hard-rock-stadium" => { name: "Hard Rock Stadium", address: "347 Don Shula Drive", location: "Miami Gardens, FL", city: "Miami Gardens", state: "FL", country: "USA", timezone: "America/New_York" },
  "u-s-bank-stadium" => { name: "U.S. Bank Stadium", address: "401 Chicago Avenue", location: "Minneapolis, MN", city: "Minneapolis", state: "MN", country: "USA", timezone: "America/Chicago" },
  "gillette-stadium" => { name: "Gillette Stadium", address: "1 Patriot Place", location: "Foxborough, MA", city: "Foxborough", state: "MA", country: "USA", timezone: "America/New_York" },
  "caesars-superdome" => { name: "Caesars Superdome", address: "1500 Sugar Bowl Drive", location: "New Orleans, LA", city: "New Orleans", state: "LA", country: "USA", timezone: "America/Chicago" },
  "metlife-stadium" => { name: "MetLife Stadium", address: "1 MetLife Stadium Drive", location: "East Rutherford, NJ", city: "East Rutherford", state: "NJ", country: "USA", timezone: "America/New_York" },
  "lincoln-financial-field" => { name: "Lincoln Financial Field", address: "1 Lincoln Financial Field Way", location: "Philadelphia, PA", city: "Philadelphia", state: "PA", country: "USA", timezone: "America/New_York" },
  "acrisure-stadium" => { name: "Acrisure Stadium", address: "100 Art Rooney Avenue", location: "Pittsburgh, PA", city: "Pittsburgh", state: "PA", country: "USA", timezone: "America/New_York" },
  "lumen-field" => { name: "Lumen Field", address: "800 Occidental Avenue South", location: "Seattle, WA", city: "Seattle", state: "WA", country: "USA", timezone: "America/Los_Angeles" },
  "levi-s-stadium" => { name: "Levi's Stadium", address: "4900 Marie P DeBartolo Way", location: "Santa Clara, CA", city: "Santa Clara", state: "CA", country: "USA", timezone: "America/Los_Angeles" },
  "raymond-james-stadium" => { name: "Raymond James Stadium", address: "4201 N Dale Mabry Highway", location: "Tampa, FL", city: "Tampa", state: "FL", country: "USA", timezone: "America/New_York" },
  "nissan-stadium" => { name: "Nissan Stadium", address: "1 Titans Way", location: "Nashville, TN", city: "Nashville", state: "TN", country: "USA", timezone: "America/Chicago" },
  "northwest-stadium" => { name: "Northwest Stadium", address: "1600 FedEx Way", location: "Landover, MD", city: "Landover", state: "MD", country: "USA", timezone: "America/New_York" }
}

nfl_schedule_only_arenas = {
  "estadio-banorte" => { name: "Estadio Banorte", address: "Calzada de Tlalpan 3465, Santa Ursula Coapa, Coyoacan", location: "Mexico City, Mexico", city: "Mexico City", state: "CDMX", country: "Mexico", timezone: "America/Mexico_City" },
  "fc-bayern-munich-stadium" => { name: "FC Bayern Munich Stadium", address: "Werner-Heisenberg-Allee 25", location: "Munich, Germany", city: "Munich", state: "Bavaria", country: "Germany", timezone: "Europe/Berlin" },
  "maracana-stadium" => { name: "Maracana Stadium", address: "Avenida Presidente Castelo Branco, Portao 3, Maracana", location: "Rio De Janeiro, Brazil", city: "Rio De Janeiro", state: "RJ", country: "Brazil", timezone: "America/Sao_Paulo" },
  "melbourne-cricket-ground" => { name: "Melbourne Cricket Ground", address: "120 Barassi Way", location: "Melbourne, VIC", city: "Melbourne", state: "VIC", country: "Australia", timezone: "Australia/Melbourne" },
  "santiago-bernabeu" => { name: "Santiago Bernabeu", address: "Avenida de Concha Espina 1", location: "Madrid, Spain", city: "Madrid", state: "Community of Madrid", country: "Spain", timezone: "Europe/Madrid" },
  "stade-de-france" => { name: "Stade de France", address: "ZAC du Cornillon Nord", location: "Saint-Denis, France", city: "Saint-Denis", state: "Ile-de-France", country: "France", timezone: "Europe/Paris" },
  "tottenham-hotspur-stadium" => { name: "Tottenham Hotspur Stadium", address: "782 High Road", location: "London, England", city: "London", state: "England", country: "United Kingdom", timezone: "Europe/London" },
  "wembley-stadium" => { name: "Wembley Stadium", address: "South Way", location: "London, England", city: "London", state: "England", country: "United Kingdom", timezone: "Europe/London" }
}

nfl_team_metadata = {
  "ARI" => { slug: "arizona-cardinals", name: "Arizona Cardinals", short_name: "ARI", location: "Arizona", emoji: "🐦", color_primary: "#97233F", color_secondary: "#000000", color_text_light: false, conference: "NFC", division: "West", rivals: %w[san-francisco-49ers los-angeles-rams seattle-seahawks], team_website: "https://www.azcardinals.com", coaches_url: "https://www.azcardinals.com/team/coaches/", hashtag: "#BirdGang", x_handle: "AZCardinals", home_arena_slug: "state-farm-stadium" },
  "ATL" => { slug: "atlanta-falcons", name: "Atlanta Falcons", short_name: "ATL", location: "Atlanta", emoji: "🦅", color_primary: "#A71930", color_secondary: "#000000", color_text_light: false, conference: "NFC", division: "South", rivals: %w[new-orleans-saints carolina-panthers tampa-bay-buccaneers], team_website: "https://www.atlantafalcons.com", coaches_url: "https://www.atlantafalcons.com/team/coaches/", hashtag: "#RiseUp", x_handle: "AtlantaFalcons", home_arena_slug: "mercedes-benz-stadium" },
  "BAL" => { slug: "baltimore-ravens", name: "Baltimore Ravens", short_name: "BAL", location: "Baltimore", emoji: "🐦‍⬛", color_primary: "#241773", color_secondary: "#000000", color_text_light: false, conference: "AFC", division: "North", rivals: %w[pittsburgh-steelers cincinnati-bengals cleveland-browns], team_website: "https://www.baltimoreravens.com", coaches_url: "https://www.baltimoreravens.com/team/coaches/", hashtag: "#RavensFlock", hashtag2: "#TRUZZ", home_arena_slug: "m-t-bank-stadium" },
  "BUF" => { slug: "buffalo-bills", name: "Buffalo Bills", short_name: "BUF", location: "Buffalo", emoji: "🦬", color_primary: "#00338D", color_secondary: "#C60C30", color_text_light: false, conference: "AFC", division: "East", rivals: %w[miami-dolphins new-england-patriots new-york-jets kansas-city-chiefs], team_website: "https://www.buffalobills.com", coaches_url: "https://www.buffalobills.com/team/coaches/", hashtag: "#BillsMafia", hashtag2: "#GoBills", x_handle: "BuffaloBills", home_arena_slug: "highmark-stadium" },
  "CAR" => { slug: "carolina-panthers", name: "Carolina Panthers", short_name: "CAR", location: "Carolina", emoji: "🐆", color_primary: "#0085CA", color_secondary: "#101820", color_text_light: false, conference: "NFC", division: "South", rivals: %w[atlanta-falcons new-orleans-saints tampa-bay-buccaneers], team_website: "https://www.panthers.com", coaches_url: "https://www.panthers.com/team/coaches/", hashtag: "#KeepPounding", x_handle: "Panthers", home_arena_slug: "bank-of-america-stadium" },
  "CHI" => { slug: "chicago-bears", name: "Chicago Bears", short_name: "CHI", location: "Chicago", emoji: "🐻", color_primary: "#0B162A", color_secondary: "#C83803", color_text_light: false, conference: "NFC", division: "North", rivals: %w[green-bay-packers minnesota-vikings detroit-lions], team_website: "https://www.chicagobears.com", coaches_url: "https://www.chicagobears.com/team/coaches/", hashtag: "#DaBears", hashtag2: "#bears", x_handle: "ChicagoBears", home_arena_slug: "soldier-field" },
  "CIN" => { slug: "cincinnati-bengals", name: "Cincinnati Bengals", short_name: "CIN", location: "Cincinnati", emoji: "🐯", color_primary: "#FB4F14", color_secondary: "#000000", color_text_light: false, conference: "AFC", division: "North", rivals: %w[baltimore-ravens pittsburgh-steelers cleveland-browns], team_website: "https://www.bengals.com", coaches_url: "https://www.bengals.com/team/coaches/", hashtag: "#WhoDey", x_handle: "Bengals", home_arena_slug: "paycor-stadium" },
  "CLE" => { slug: "cleveland-browns", name: "Cleveland Browns", short_name: "CLE", location: "Cleveland", emoji: "🟤", color_primary: "#311D00", color_secondary: "#FF3C00", color_text_light: false, conference: "AFC", division: "North", rivals: %w[pittsburgh-steelers baltimore-ravens cincinnati-bengals], team_website: "https://www.clevelandbrowns.com", coaches_url: "https://www.clevelandbrowns.com/team/coaches/", hashtag: "#DawgPound", x_handle: "Browns", home_arena_slug: "huntington-bank-field" },
  "DAL" => { slug: "dallas-cowboys", name: "Dallas Cowboys", short_name: "DAL", location: "Dallas", emoji: "⭐", color_primary: "#003594", color_secondary: "#869397", color_text_light: false, conference: "NFC", division: "East", rivals: %w[philadelphia-eagles washington-commanders new-york-giants san-francisco-49ers], team_website: "https://www.dallascowboys.com", coaches_url: "https://www.dallascowboys.com/team/coaches/", hashtag: "#DallasCowboys", hashtag2: "#cowboys", home_arena_slug: "at-t-stadium" },
  "DEN" => { slug: "denver-broncos", name: "Denver Broncos", short_name: "DEN", location: "Denver", emoji: "🐎", color_primary: "#FB4F14", color_secondary: "#002244", color_text_light: false, conference: "AFC", division: "West", rivals: %w[kansas-city-chiefs las-vegas-raiders los-angeles-chargers], team_website: "https://www.denverbroncos.com", coaches_url: "https://www.denverbroncos.com/team/coaches/", hashtag: "#BroncosCountry", x_handle: "Broncos", home_arena_slug: "empower-field-at-mile-high" },
  "DET" => { slug: "detroit-lions", name: "Detroit Lions", short_name: "DET", location: "Detroit", emoji: "🦁", color_primary: "#0076B6", color_secondary: "#B0B7BC", color_text_light: false, conference: "NFC", division: "North", rivals: %w[green-bay-packers chicago-bears minnesota-vikings], team_website: "https://www.detroitlions.com", coaches_url: "https://www.detroitlions.com/team/coaches/", hashtag: "#OnePride", home_arena_slug: "ford-field" },
  "GB" => { slug: "green-bay-packers", name: "Green Bay Packers", short_name: "GB", location: "Green Bay", emoji: "🧀", color_primary: "#203731", color_secondary: "#FFB612", color_text_light: false, conference: "NFC", division: "North", rivals: %w[chicago-bears minnesota-vikings detroit-lions dallas-cowboys], team_website: "https://www.packers.com", coaches_url: "https://www.packers.com/team/coaches/", hashtag: "#GoPackGo", hashtag2: "#Packers", x_handle: "Packers", home_arena_slug: "lambeau-field" },
  "HOU" => { slug: "houston-texans", name: "Houston Texans", short_name: "HOU", location: "Houston", emoji: "🤠", color_primary: "#03202F", color_secondary: "#A71930", color_text_light: false, conference: "AFC", division: "South", rivals: %w[indianapolis-colts jacksonville-jaguars tennessee-titans dallas-cowboys], team_website: "https://www.houstontexans.com", coaches_url: "https://www.houstontexans.com/team/coaches/", hashtag: "#HTownMade", x_handle: "HoustonTexans", home_arena_slug: "nrg-stadium" },
  "IND" => { slug: "indianapolis-colts", name: "Indianapolis Colts", short_name: "IND", location: "Indianapolis", emoji: "🐴", color_primary: "#002C5F", color_secondary: "#A2AAAD", color_text_light: false, conference: "AFC", division: "South", rivals: %w[houston-texans jacksonville-jaguars tennessee-titans new-england-patriots], team_website: "https://www.colts.com", coaches_url: "https://www.colts.com/team/coaches/", hashtag: "#ForTheShoe", x_handle: "Colts", home_arena_slug: "lucas-oil-stadium" },
  "JAX" => { slug: "jacksonville-jaguars", name: "Jacksonville Jaguars", short_name: "JAX", location: "Jacksonville", emoji: "🐆", color_primary: "#006778", color_secondary: "#D7A22A", color_text_light: false, conference: "AFC", division: "South", rivals: %w[houston-texans indianapolis-colts tennessee-titans], team_website: "https://www.jaguars.com", coaches_url: "https://www.jaguars.com/team/coaches/", hashtag: "#DUUUVAL", x_handle: "Jaguars", home_arena_slug: "everbank-stadium" },
  "KC" => { slug: "kansas-city-chiefs", name: "Kansas City Chiefs", short_name: "KC", location: "Kansas City", emoji: "🏹", color_primary: "#E31837", color_secondary: "#FFB81C", color_text_light: false, conference: "AFC", division: "West", rivals: %w[las-vegas-raiders denver-broncos los-angeles-chargers philadelphia-eagles], team_website: "https://www.chiefs.com", coaches_url: "https://www.chiefs.com/team/coaches/", hashtag: "#ChiefsKingdom", hashtag2: "#chiefs", home_arena_slug: "geha-field-at-arrowhead-stadium" },
  "LAC" => { slug: "los-angeles-chargers", name: "Los Angeles Chargers", short_name: "LAC", location: "Los Angeles", emoji: "⚡", color_primary: "#0080C6", color_secondary: "#FFC20E", color_text_light: false, conference: "AFC", division: "West", rivals: %w[kansas-city-chiefs las-vegas-raiders denver-broncos], team_website: "https://www.chargers.com", coaches_url: "https://www.chargers.com/team/coaches/", hashtag: "#BoltUp", hashtag2: "#Chargers", x_handle: "chargers", home_arena_slug: "sofi-stadium" },
  "LAR" => { slug: "los-angeles-rams", name: "Los Angeles Rams", short_name: "LAR", location: "Los Angeles", emoji: "🐏", color_primary: "#003594", color_secondary: "#FFA300", color_text_light: false, conference: "NFC", division: "West", rivals: %w[san-francisco-49ers seattle-seahawks arizona-cardinals], team_website: "https://www.therams.com", coaches_url: "https://www.therams.com/team/coaches/", hashtag: "#RamsHouse", hashtag2: "#Rams", home_arena_slug: "sofi-stadium" },
  "LV" => { slug: "las-vegas-raiders", name: "Las Vegas Raiders", short_name: "LV", location: "Las Vegas", emoji: "☠️", color_primary: "#000000", color_secondary: "#A5ACAF", color_text_light: false, conference: "AFC", division: "West", rivals: %w[kansas-city-chiefs denver-broncos los-angeles-chargers], team_website: "https://www.raiders.com", coaches_url: "https://www.raiders.com/team/coaches/", hashtag: "#RaiderNation", home_arena_slug: "allegiant-stadium" },
  "MIA" => { slug: "miami-dolphins", name: "Miami Dolphins", short_name: "MIA", location: "Miami", emoji: "🐬", color_primary: "#008E97", color_secondary: "#FC4C02", color_text_light: false, conference: "AFC", division: "East", rivals: %w[buffalo-bills new-england-patriots new-york-jets], team_website: "https://www.miamidolphins.com", coaches_url: "https://www.miamidolphins.com/team/coaches/", hashtag: "#PhinsUp", home_arena_slug: "hard-rock-stadium" },
  "MIN" => { slug: "minnesota-vikings", name: "Minnesota Vikings", short_name: "MIN", location: "Minnesota", emoji: "⚔️", color_primary: "#4F2683", color_secondary: "#FFC62F", color_text_light: false, conference: "NFC", division: "North", rivals: %w[green-bay-packers chicago-bears detroit-lions], team_website: "https://www.vikings.com", coaches_url: "https://www.vikings.com/team/coaches/", hashtag: "#Skol", home_arena_slug: "u-s-bank-stadium" },
  "NE" => { slug: "new-england-patriots", name: "New England Patriots", short_name: "NE", location: "New England", emoji: "🏴", color_primary: "#002244", color_secondary: "#C60C30", color_text_light: false, conference: "AFC", division: "East", rivals: %w[buffalo-bills miami-dolphins new-york-jets], team_website: "https://www.patriots.com", coaches_url: "https://www.patriots.com/team/coaches/", hashtag: "#NEPats", x_handle: "Patriots", home_arena_slug: "gillette-stadium" },
  "NO" => { slug: "new-orleans-saints", name: "New Orleans Saints", short_name: "NO", location: "New Orleans", emoji: "⚜️", color_primary: "#D3BC8D", color_secondary: "#101820", color_text_light: true, conference: "NFC", division: "South", rivals: %w[atlanta-falcons carolina-panthers tampa-bay-buccaneers], team_website: "https://www.neworleanssaints.com", coaches_url: "https://www.neworleanssaints.com/team/coaches/", hashtag: "#Saints", x_handle: "Saints", home_arena_slug: "caesars-superdome" },
  "NYG" => { slug: "new-york-giants", name: "New York Giants", short_name: "NYG", location: "New York", emoji: "🗽", color_primary: "#0B2265", color_secondary: "#A71930", color_text_light: false, conference: "NFC", division: "East", rivals: %w[dallas-cowboys philadelphia-eagles washington-commanders], team_website: "https://www.giants.com", coaches_url: "https://www.giants.com/team/coaches/", hashtag: "#NYGiants", home_arena_slug: "metlife-stadium" },
  "NYJ" => { slug: "new-york-jets", name: "New York Jets", short_name: "NYJ", location: "New York", emoji: "✈️", color_primary: "#125740", color_secondary: "#FFFFFF", color_text_light: false, conference: "AFC", division: "East", rivals: %w[new-england-patriots buffalo-bills miami-dolphins new-york-giants], team_website: "https://www.newyorkjets.com", coaches_url: "https://www.newyorkjets.com/team/coaches/", hashtag: "#JetUp", x_handle: "nyjets", home_arena_slug: "metlife-stadium" },
  "PHI" => { slug: "philadelphia-eagles", name: "Philadelphia Eagles", short_name: "PHI", location: "Philadelphia", emoji: "🦅", color_primary: "#004C54", color_secondary: "#A5ACAF", color_text_light: false, conference: "NFC", division: "East", rivals: %w[dallas-cowboys new-york-giants washington-commanders kansas-city-chiefs], team_website: "https://www.philadelphiaeagles.com", coaches_url: "https://www.philadelphiaeagles.com/team/coaches/", hashtag: "#FlyEaglesFly", home_arena_slug: "lincoln-financial-field" },
  "PIT" => { slug: "pittsburgh-steelers", name: "Pittsburgh Steelers", short_name: "PIT", location: "Pittsburgh", emoji: "⚙️", color_primary: "#FFB612", color_secondary: "#101820", color_text_light: true, conference: "AFC", division: "North", rivals: %w[baltimore-ravens cleveland-browns cincinnati-bengals dallas-cowboys], team_website: "https://www.steelers.com", coaches_url: "https://www.steelers.com/team/coaches/", hashtag: "#steelers", home_arena_slug: "acrisure-stadium" },
  "SEA" => { slug: "seattle-seahawks", name: "Seattle Seahawks", short_name: "SEA", location: "Seattle", emoji: "🦅", color_primary: "#002244", color_secondary: "#69BE28", color_text_light: false, conference: "NFC", division: "West", rivals: %w[san-francisco-49ers los-angeles-rams arizona-cardinals], team_website: "https://www.seahawks.com", coaches_url: "https://www.seahawks.com/team/coaches/", hashtag: "#seahawks", x_handle: "Seahawks", home_arena_slug: "lumen-field" },
  "SF" => { slug: "san-francisco-49ers", name: "San Francisco 49ers", short_name: "SF", location: "San Francisco", emoji: "⛏️", color_primary: "#AA0000", color_secondary: "#B3995D", color_text_light: false, conference: "NFC", division: "West", rivals: %w[seattle-seahawks los-angeles-rams dallas-cowboys arizona-cardinals], team_website: "https://www.49ers.com", coaches_url: "https://www.49ers.com/team/coaches/", hashtag: "#FTTB", x_handle: "49ers", home_arena_slug: "levi-s-stadium" },
  "TB" => { slug: "tampa-bay-buccaneers", name: "Tampa Bay Buccaneers", short_name: "TB", location: "Tampa Bay", emoji: "🏴‍☠️", color_primary: "#D50A0A", color_secondary: "#FF7900", color_text_light: false, conference: "NFC", division: "South", rivals: %w[new-orleans-saints atlanta-falcons carolina-panthers], team_website: "https://www.buccaneers.com", coaches_url: "https://www.buccaneers.com/team/coaches/", hashtag: "#WeAreTheKrewe", x_handle: "Buccaneers", home_arena_slug: "raymond-james-stadium" },
  "TEN" => { slug: "tennessee-titans", name: "Tennessee Titans", short_name: "TEN", location: "Tennessee", emoji: "⚔️", color_primary: "#0C2340", color_secondary: "#4B92DB", color_text_light: false, conference: "AFC", division: "South", rivals: %w[houston-texans indianapolis-colts jacksonville-jaguars], team_website: "https://www.tennesseetitans.com", coaches_url: "https://www.tennesseetitans.com/team/coaches/", hashtag: "#TitanUp", home_arena_slug: "nissan-stadium" },
  "WAS" => { slug: "washington-commanders", name: "Washington Commanders", short_name: "WAS", location: "Washington", emoji: "🎖️", color_primary: "#5A1414", color_secondary: "#FFB612", color_text_light: false, conference: "NFC", division: "East", rivals: %w[dallas-cowboys philadelphia-eagles new-york-giants], team_website: "https://www.commanders.com", coaches_url: "https://www.commanders.com/team/coaches/", hashtag: "#RaiseHail", home_arena_slug: "northwest-stadium" }
}
nfl_team_metadata["WSH"] = nfl_team_metadata.fetch("WAS")

# Four-color brand palette lives in Nfl::TeamPalette::PALETTE — the single place
# to edit team colors, shared with the `nfl:recolor` post-deploy task. Merge it
# onto the metadata so freshly-seeded teams get their colors here; existing rows
# are recolored idempotently on reseed (and in prod via `bin/rails nfl:recolor`,
# which touches ONLY color columns — never games, slates, or frozen turf_scores).
Nfl::TeamPalette::PALETTE.each_key do |abbr|
  next unless nfl_team_metadata.key?(abbr)

  nfl_team_metadata[abbr].merge!(Nfl::TeamPalette.attributes_for(abbr))
end

nfl_home_arenas.merge(nfl_schedule_only_arenas).each do |slug, attributes|
  arena = Arena.find_or_initialize_by(slug: slug)
  arena.assign_attributes(attributes)
  arena.save!
end

nfl_teams = {}
data.fetch("teams").each do |row|
  abbreviation = row.fetch("abbreviation")
  metadata = nfl_team_metadata.fetch(abbreviation)
  team = Team.find_or_initialize_by(slug: metadata.fetch(:slug))
  team.assign_attributes(
    name: metadata.fetch(:name),
    short_name: metadata.fetch(:short_name),
    mascot: row.fetch("name"),
    location: metadata.fetch(:location),
    emoji: metadata.fetch(:emoji),
    color_dark: metadata.fetch(:color_dark),
    color_light: metadata.fetch(:color_light),
    color_dark_alt: metadata[:color_dark_alt],
    color_light_alt: metadata[:color_light_alt],
    color_alt: metadata[:color_alt],
    color_grey: metadata[:color_grey],
    color_disposition: metadata.fetch(:color_disposition),
    sport: "football",
    league: "nfl",
    conference: metadata.fetch(:conference),
    division: metadata.fetch(:division),
    rivals: metadata.fetch(:rivals),
    team_website: metadata.fetch(:team_website),
    coaches_url: metadata.fetch(:coaches_url),
    hashtag: metadata[:hashtag],
    hashtag2: metadata[:hashtag2],
    x_handle: metadata[:x_handle],
    home_arena_slug: metadata.fetch(:home_arena_slug)
  )
  team.save!
  nfl_teams[abbreviation] = team
end

games_by_week = Hash.new { |hash, week| hash[week] = [] }

data.fetch("games").each do |row|
  home_team = nfl_teams.fetch(row.fetch("home"))
  away_team = nfl_teams.fetch(row.fetch("away"))
  kickoff_at = Time.zone.parse(row.fetch("starts_at"))
  venue = [row.fetch("venue"), row.fetch("location")].reject(&:blank?).join(", ")
  game_slug = "#{home_team.slug}-vs-#{away_team.slug}"

  game = Game.find_or_initialize_by(slug: game_slug)
  game.assign_attributes(
    home_team_slug: home_team.slug,
    away_team_slug: away_team.slug,
    kickoff_at: kickoff_at,
    venue: venue
  )
  game.status = "scheduled" if game.status.blank?
  game.save!

  games_by_week[row.fetch("week")] << { game: game, home_team: home_team, away_team: away_team }
end

games_by_week.sort.each do |week, entries|
  first_game_at = entries.map { |entry| entry.fetch(:game).kickoff_at }.compact.min
  slate = Slate.find_or_initialize_by(name: "NFL 2026 Week #{week}")
  slate.starts_at = first_game_at
  slate.save!

  entries.each do |entry|
    game = entry.fetch(:game)
    home_team = entry.fetch(:home_team)
    away_team = entry.fetch(:away_team)

    [[home_team, away_team], [away_team, home_team]].each do |team, opponent|
      matchup = SlateMatchup.find_or_initialize_by(slate: slate, team_slug: team.slug)
      matchup.assign_attributes(
        opponent_team_slug: opponent.slug,
        game_slug: game.slug
      )
      matchup.save!
    end
  end

  sorted_matchups = slate.slate_matchups.includes(:team, :game).sort_by do |matchup|
    [matchup.game&.kickoff_at || first_game_at, matchup.team.name]
  end

  sorted_matchups.each_with_index do |matchup, index|
    rank = index + 1
    matchup.update!(rank: rank, turf_score: SlateMatchup.turf_score_for(rank, sorted_matchups.size, sport: "nfl"))
  end

  puts "  Created slate: #{slate.name} (#{entries.size} games, #{slate.slate_matchups.count} matchups, starts #{first_game_at.utc.iso8601})"
end

puts "  Created NFL #{data.fetch("season")} teams/games/slates (#{nfl_teams.size} teams, #{data.fetch("games").size} games, #{games_by_week.size} slates)"
