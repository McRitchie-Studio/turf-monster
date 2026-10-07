# An A/B test of one page's copy: the page (`page_path`), its named variants
# (PageVariant: copy overrides and a weight), and whether it is running.
#
#   /admin/experiments   create, edit, pause, and read the report
#
# WHY A TABLE AND NOT A YAML REGISTRY. Variants are copy, and the operator adds
# and retires them without a deploy. LandingPage was the nearest existing
# concept, and was weighed: it IS a page (its own /lp/:slug view), while a
# variant is a set of overrides on a page that already exists, so it does not
# fit there; CampaignLink is a door to a page, not the page, and only binds to
# an experiment (CampaignLink#experiment_slug) so its /l/ hop can name the
# variant in the URL.
#
# ASSIGNMENT (#assign, called by PageExperimentTracking on the page and on a
# bound short link's /l/ hop), first match wins:
#   1. an explicit ?v=<key> naming one of its variants   (QA, previews, shares)
#   2. a bot or link unfurler -> the control, never stored and never counted
#   3. the visitor's sticky cookie, exp_<slug>
#   4. a weighted random draw, which the caller stores in the cookie
#
# The slug is the experiment's identity in the cookie, the events and the
# signup columns, so it cannot change after create (attr_readonly): renaming it
# would orphan every count and re-split every visitor.
class PageExperiment < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  SLUG_LIMIT = 64
  COOKIE_PREFIX = "exp_".freeze
  COOKIE_TTL = 90.days
  CONTROL_KEY = "control".freeze
  # The URL parameter that names a variant: ?v=<key>.
  VARIANT_PARAM = "v".freeze

  # How one request came by its variant (Assignment#source).
  # `source` is :param, :cookie, :bot or :sampled; `bot` is whether the
  # client is one (a bot's explicit ?v= still renders, for an unfurl).
  Assignment = Struct.new(:experiment, :variant, :source, :bot, keyword_init: true) do
    # Whether the caller should write the sticky cookie: a draw or an explicit
    # ?v= (which re-pins the visitor, so a shared link keeps showing what it
    # named). Never for a bot.
    def store? = !bot && %i[sampled param].include?(source)
    def counted? = !bot
    def key = variant.key
  end

  has_many :variants, -> { order(:position, :id) }, class_name: "PageVariant",
                                                    foreign_key: :experiment_slug, primary_key: :slug,
                                                    inverse_of: :experiment, dependent: :destroy
  accepts_nested_attributes_for :variants, allow_destroy: true,
                                           reject_if: ->(attrs) { attrs["key"].blank? && attrs["id"].blank? }

  attr_readonly :slug

  before_validation :normalize_fields

  validates :slug, presence: true, length: { maximum: SLUG_LIMIT },
                   format: { with: SLUG_FORMAT, message: "may use only lowercase letters, digits and inner hyphens" },
                   uniqueness: true
  validates :name, presence: true
  validate :page_path_is_a_local_page
  validate :one_running_experiment_per_page, if: :active?
  validate :variants_are_splittable

  scope :active, -> { where(active: true) }

  # The running experiment on a page, variants loaded, or nil. Never raises:
  # a page must render with its default copy if this lookup fails.
  def self.for_page(path)
    active.includes(:variants).find_by(page_path: path.to_s)
  rescue StandardError => e
    ReferralVisit.report_failure(e, "experiment lookup failed path=#{path.inspect}")
    nil
  end

  def cookie_name
    "#{COOKIE_PREFIX}#{slug}"
  end

  # In order, read from memory (so an unsaved form's rows count too).
  def live_variants
    variants.reject(&:marked_for_destruction?).sort_by { |variant| [variant.position.to_i, variant.id || 0] }
  end

  def variant_for(key)
    return nil if key.blank?

    live_variants.find { |variant| variant.key == key.to_s.strip.downcase }
  end

  # The variant `control` when there is one, else the first in order.
  def control_variant
    variant_for(CONTROL_KEY) || live_variants.first
  end

  # A weighted draw. `rng` is injectable so the tests are deterministic.
  # Variants with weight 0 are never drawn (a paused arm still renders for a
  # visitor already holding it, or for an explicit ?v=).
  def sample(rng: Random)
    pool = live_variants.select { |variant| variant.weight.to_i.positive? }
    return control_variant if pool.empty?

    pick = rng.rand(pool.sum(&:weight))
    pool.each do |variant|
      return variant if pick < variant.weight
      pick -= variant.weight
    end
    pool.last
  end

  def assign(param: nil, cookie: nil, bot: false, rng: Random)
    variant, source =
      if (chosen = variant_for(param)) then [chosen, :param]
      elsif bot then [control_variant, :bot]
      elsif (held = variant_for(cookie)) then [held, :cookie]
      else [sample(rng: rng), :sampled]
      end
    Assignment.new(experiment: self, variant: variant, source: source, bot: bot ? true : false)
  end

  def to_param
    slug
  end

  private

  def normalize_fields
    self.slug = slug.to_s.strip.downcase.presence if new_record?
    self.page_path = page_path.to_s.strip.presence
    self.name = name.to_s.strip.presence
  end

  def page_path_is_a_local_page
    path = page_path.to_s
    if path.blank?
      errors.add(:page_path, "can't be blank")
    elsif !path.match?(%r{\A/(?![/\\])[[:graph:]]*\z}) || path.include?("?") || path.include?("#")
      errors.add(:page_path, "must be a path on this site, starting with a single / and with no query")
    end
  end

  def one_running_experiment_per_page
    others = PageExperiment.active.where(page_path: page_path)
    others = others.where.not(id: id) if persisted?
    errors.add(:active, "can't be on: #{others.first.slug} is already running on #{page_path}") if others.exists?
  end

  def variants_are_splittable
    live = live_variants
    errors.add(:variants, "need at least two to compare") if live.size < 2
    errors.add(:variants, "need at least one with a weight above 0") if live.none? { |v| v.weight.to_i.positive? }
    keys = live.map { |v| v.key.to_s.strip.downcase }
    errors.add(:variants, "must each have a different key") if keys.uniq.size != keys.size
  end
end
