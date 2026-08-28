# Position vocabulary for NFL data, lifted from mcritchie-studio.
#
# Every external source spells positions its own way — ESPN says "LDE", PFF
# says "ED", nflverse says "DE", and all three mean the same edge rusher. One
# map per source keeps each conversion explicit and auditable instead of piling
# every alias into a single lookup where a collision is invisible.
module PositionConcern
  extend ActiveSupport::Concern

  OFFENSE_POSITIONS = %w[QB RB WR TE LT LG C RG RT OT OG FB].freeze

  DEFENSE_POSITIONS = %w[EDGE DE DT NT DL LB ILB OLB MLB CB S FS SS].freeze

  SPECIAL_TEAMS_POSITIONS = %w[K P LS KR PR].freeze

  # Display order for a roster: offense first, then defense, then special
  # teams, each in the order a depth chart is conventionally read.
  ORDERED_POSITIONS = (OFFENSE_POSITIONS + DEFENSE_POSITIONS + SPECIAL_TEAMS_POSITIONS).freeze

  GENERAL_MAP = {
    "HB" => "RB", "TB" => "RB",
    "Edge" => "EDGE", "ED" => "EDGE",
    "DI" => "DT", "IDL" => "DT", "3T" => "DT",
    "0T" => "NT", "1T" => "NT",
    "G" => "OG", "T" => "OT", "OL" => "OT",
    "DB" => "S",
    "WLB" => "OLB", "SLB" => "OLB",
    "WILL" => "ILB", "MIKE" => "ILB", "SAM" => "OLB",
    "NCB" => "CB", "SCB" => "CB", "OCB" => "CB", "SLOT" => "CB"
  }.freeze

  # ESPN's per-team depth charts use formation-specific labels. Collapse the
  # L/R/W/M/S formation prefixes to the generic positions. Consumed by the
  # depth-chart scraper in a later phase; kept here so SOURCE_MAPS is complete
  # and `normalize_position(source: :espn)` never silently falls through.
  ESPN_MAP = {
    "LDE" => "EDGE", "RDE" => "EDGE", "DE" => "EDGE",
    "OLB" => "LB", "ILB" => "LB", "MLB" => "LB",
    "WLB" => "LB", "SLB" => "LB", "LILB" => "LB", "RILB" => "LB",
    "MIKE" => "LB", "WILL" => "LB", "SAM" => "LB",
    "LCB" => "CB", "RCB" => "CB", "NB" => "CB", "NCB" => "CB", "SCB" => "CB",
    "PK"  => "K"
  }.freeze

  # PFF CSV vocabulary — HB for halfback, ED for edge, T/G for tackle/guard.
  PFF_MAP = {
    "HB" => "RB",
    "T"  => "OT", "G" => "OG",
    "ED" => "EDGE",
    "DI" => "DT"
  }.freeze

  # nflverse players.csv — closer to standard, but uses T/G and splits
  # linebackers into ILB/OLB/MLB.
  NFLVERSE_MAP = {
    "T"   => "OT", "G" => "OG",
    "DE"  => "EDGE",
    "ILB" => "LB", "OLB" => "LB", "MLB" => "LB",
    "FS"  => "S",  "SS" => "S"
  }.freeze

  # Spotrac contract data — mirrors nflverse vocabulary in practice.
  SPOTRAC_MAP = {
    "T"   => "OT", "G" => "OG",
    "DE"  => "EDGE",
    "ILB" => "LB", "OLB" => "LB", "MLB" => "LB",
    "FS"  => "S",  "SS" => "S"
  }.freeze

  SOURCE_MAPS = {
    espn:     ESPN_MAP,
    pff:      PFF_MAP,
    nflverse: NFLVERSE_MAP,
    spotrac:  SPOTRAC_MAP
  }.freeze

  def self.side_for(position)
    normalized = normalize_position(position)
    if OFFENSE_POSITIONS.include?(normalized)
      "offense"
    elsif DEFENSE_POSITIONS.include?(normalized)
      "defense"
    elsif SPECIAL_TEAMS_POSITIONS.include?(normalized)
      "special_teams"
    else
      "offense"
    end
  end

  def self.normalize_position(position, source: nil)
    return position if position.nil?

    raw = position.strip
    upper = raw.upcase
    if source && (map = SOURCE_MAPS[source])
      mapped = map[raw] || map[upper]
      return mapped if mapped
    end
    GENERAL_MAP[raw] || GENERAL_MAP[upper] || upper
  end

  # CASE expression ordering athletes by ORDERED_POSITIONS, with anything
  # unrecognized sorted last rather than dropped. Built from a frozen constant
  # of bare position codes, so there is no interpolation of user input here.
  def self.position_order_sql
    whens = ORDERED_POSITIONS.each_with_index.map { |pos, i| "WHEN '#{pos}' THEN #{i}" }
    "CASE athletes.position #{whens.join(" ")} ELSE #{ORDERED_POSITIONS.size} END"
  end

  class_methods do
    def side_for(position)
      PositionConcern.side_for(position)
    end

    def normalize_position(position, source: nil)
      PositionConcern.normalize_position(position, source: source)
    end
  end

  def side_for(position)
    self.class.side_for(position)
  end

  def normalize_position(position, source: nil)
    self.class.normalize_position(position, source: source)
  end
end
