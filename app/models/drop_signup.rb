# One address that asked to hear when a slate drops (/turf-monster-v2's
# "notify me" form). Anyone can file one, signed in or not.
#
# ONE ROW PER ADDRESS PER DROP. Email is normalized (stripped, lowercased)
# before validation, and the unique index on [slate_key, email] is the real
# guard. `.register` is the only write path: a second submit of the same
# address answers with the row that already exists, so the form says "You're on
# the list" either way and never reveals whether an address had signed up.
#
# Validity is User.valid_email? — the same predicate the magic-link request
# uses — so this list never holds an address the app would refuse to mail.
class DropSignup < ApplicationRecord
  belongs_to :user, optional: true

  # Column widths for the free-text request metadata. A user agent can be any
  # length the client likes; the row only needs enough to tell bots apart.
  USER_AGENT_LIMIT = 500
  SOURCE_LIMIT = 100

  before_validation :normalize_fields

  validates :email, presence: true, length: { maximum: 254 }
  validates :slate_key, presence: true
  validates :email, uniqueness: { scope: :slate_key }
  validate :email_is_deliverable

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_slate, ->(key) { where(slate_key: key) }

  # Find-or-create, idempotent under a race. Returns the row (persisted when
  # the address is valid, with errors when it is not). A concurrent twin that
  # wins the unique index is answered with ITS row, never a 500.
  def self.register(email:, slate_key:, **attrs)
    normalized = normalize_email(email)
    existing = find_by(slate_key: slate_key, email: normalized)
    return existing if existing

    signup = new(email: normalized, slate_key: slate_key, **attrs)
    signup.save
    signup
  rescue ActiveRecord::RecordNotUnique
    find_by!(slate_key: slate_key, email: normalized)
  end

  def self.normalize_email(value)
    value.to_s.strip.downcase.presence
  end

  private

  def normalize_fields
    self.email = self.class.normalize_email(email)
    self.source = source.to_s.strip.first(SOURCE_LIMIT).presence
    self.user_agent = user_agent.to_s.first(USER_AGENT_LIMIT).presence
  end

  def email_is_deliverable
    return if email.blank? # presence already said so
    return if User.valid_email?(email)

    errors.add(:email, "is not a valid email address")
  end
end
