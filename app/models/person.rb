# A human being in the NFL data set — the identity that outlives any one role.
# The playing profile hangs off this as an Athlete; later phases attach coaches
# and contracts to the same record.
#
# Lifted from mcritchie-studio. Kept deliberately close to the original so the
# depth-chart, contract, and grade importers port across without rework.
class Person < ApplicationRecord
  include Sluggable

  has_one :athlete_profile, class_name: "Athlete", foreign_key: :person_slug, primary_key: :slug

  validates :first_name, :last_name, presence: true

  scope :athletes, -> { where(athlete: true) }

  # Multi-strategy name lookup. External sources disagree about suffixes and
  # punctuation ("T.J. Watt", "TJ Watt", "Will Anderson" vs "Will Anderson Jr."),
  # so a bare slug match splits one player into several records. Each strategy
  # is tried in order of confidence.
  def self.find_by_name(first_name, last_name)
    full = "#{first_name} #{last_name}".strip
    slug = full.parameterize

    # 1. Exact slug match
    found = find_by(slug: slug)
    return found if found

    # 2. Normalized slug — strip periods, apostrophes, quotes before parameterize
    normalized = full.gsub(/[.'"“”]/, "").parameterize
    if normalized != slug
      found = find_by(slug: normalized)
      return found if found
    end

    # 3. Alias match — a previous ingest recorded this spelling as a variant
    where("aliases @> ?", [full].to_json).first
  end

  # Find by smart name matching, or create. Records the incoming spelling as an
  # alias when it differs from what we stored, so the next source that uses the
  # other spelling finds this record via strategy 3 instead of creating a twin.
  def self.find_or_create_by_name!(first_name, last_name, **attrs)
    person = find_by_name(first_name, last_name)
    return create!(first_name: first_name, last_name: last_name, **attrs) unless person

    incoming = "#{first_name} #{last_name}".strip
    if incoming != person.full_name && person.aliases.exclude?(incoming)
      person.aliases << incoming
      person.save!
    end

    # Apply role flags if passed and not already set — a person can be both.
    flags = attrs.slice(:athlete, :coach).select { |k, v| v && !person.send(:"#{k}?") }
    person.update!(flags) if flags.any?
    person
  end

  # Two active players can share a name (seven pairs do in the 2026 league), so
  # a name-derived slug is not unique on its own. A genuine namesake carries a
  # `disambiguator` — a stable fragment of their league ID — and everyone else
  # keeps the clean "first-last" slug.
  def name_slug
    base = "#{first_name} #{last_name}".parameterize
    disambiguator.present? ? "#{base}-#{disambiguator}" : base
  end

  def full_name
    "#{first_name} #{last_name}"
  end
end
