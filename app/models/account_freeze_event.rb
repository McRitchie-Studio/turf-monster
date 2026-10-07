# The audit trail of the account freeze (OPSEC-048): one immutable row per
# freeze and per unfreeze, whoever did it. Written only by User#freeze! and
# User#unfreeze!, so no path can change the hold without leaving a row.
#
#   user    the account frozen or unfrozen
#   admin   the operator who acted; nil when the app froze it on its own
#           (a Stripe or PayPal dispute or refund webhook)
#   action  freeze / unfreeze
#   source  admin / payment_risk / console
#   reason  why, in the actor's words (required)
#
# Append-only, like ImpersonationLog: created_at, no updated_at, never edited.
class AccountFreezeEvent < ApplicationRecord
  self.record_timestamps = false

  # Plain strings, not an enum: an enum named `freeze` would define a class
  # scope over Object#freeze.
  ACTIONS = %w[freeze unfreeze].freeze
  SOURCES = %w[admin payment_risk console].freeze

  belongs_to :user
  belongs_to :admin, class_name: "User", optional: true

  validates :reason, presence: true, length: { maximum: 255 }
  validates :action, inclusion: { in: ACTIONS }
  validates :source, inclusion: { in: SOURCES }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  before_create { self.created_at ||= Time.current }

  def readonly?
    persisted?
  end
end
