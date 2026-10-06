# One arm of a PageExperiment: the copy it overrides on the page and its share
# of new visitors. A blank field means "the page's own copy", so the control
# usually overrides nothing.
#
#   headline         one line per line of the field (the page draws each as a
#                    block, as the control's three sentences are)
#   subhead_desktop  the hero paragraph from md up
#   subhead_mobile   the shorter hero paragraph below md
#   meta_title / meta_description   the <title> and the description meta
#
# The key is what the URL (?v=), the cookie and every count carry, so it is a
# short lowercase slug and, once anything has counted it, renaming it splits
# the counts: the admin form says so.
class PageVariant < ApplicationRecord
  KEY_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  KEY_LIMIT = 40
  WEIGHT_RANGE = (0..1000)
  HEADLINE_LINES_MAX = 4

  belongs_to :experiment, class_name: "PageExperiment", foreign_key: :experiment_slug,
                          primary_key: :slug, inverse_of: :variants

  before_validation :normalize_fields

  validates :key, presence: true, length: { maximum: KEY_LIMIT },
                  format: { with: KEY_FORMAT, message: "may use only lowercase letters, digits and inner hyphens" }
  validates :weight, numericality: { only_integer: true, in: WEIGHT_RANGE }
  validate :headline_fits

  def control?
    key == PageExperiment::CONTROL_KEY
  end

  def headline_lines
    headline.to_s.lines.map(&:strip).compact_blank
  end

  def display_name
    label.presence || key
  end

  private

  def normalize_fields
    self.key = key.to_s.strip.downcase.presence
    %i[label headline subhead_desktop subhead_mobile meta_title meta_description].each do |field|
      self[field] = self[field].to_s.strip.presence
    end
  end

  def headline_fits
    return if headline_lines.size <= HEADLINE_LINES_MAX

    errors.add(:headline, "can be at most #{HEADLINE_LINES_MAX} lines")
  end
end
