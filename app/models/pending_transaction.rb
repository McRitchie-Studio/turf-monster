class PendingTransaction < ApplicationRecord
  include Sluggable

  belongs_to :target, polymorphic: true, optional: true

  validates :tx_type, presence: true
  validates :serialized_tx, presence: true
  validates :status, inclusion: { in: %w[pending submitted confirmed expired failed] }

  # Single-use broadcast signatures (Lazarus audit #8 residual). A finalized
  # tx_signature may back at most ONE PendingTransaction — mirrors the
  # entries.onchain_tx_signature guard. allow_nil keeps unbroadcast rows
  # (signature is set only once submitted) unconstrained; the partial unique DB
  # index (20260601000001) is the race-safe backstop, this gives a clean error.
  validates :tx_signature, uniqueness: true, allow_nil: true

  # BL4 (Stage 3 audit) bug fix: name_slug includes `id`, which is nil during
  # Sluggable's before_save. Without intervention, every row got slug "ptx-"
  # → unique index meant only ONE PendingTransaction could exist at a time
  # (treasury blocker). Use tmp-unique slug during INSERT, then overwrite
  # with canonical "ptx-<id>" after_create.
  after_create :update_slug_with_id

  scope :pending, -> { where(status: "pending") }
  scope :confirmed, -> { where(status: "confirmed") }

  # What the operator is actually being asked to sign — `pending` minus the rows
  # marked stale. This is the ONLY count the Signatures badge should ever show:
  # `pending` alone was 11 on production the day the badge was built, and 10 of
  # those were dead `enter_contest` rows from June and July. A badge that cries
  # wolf on its first day never gets looked at again.
  scope :awaiting_signature, -> { pending.where(stale: false) }

  def name_slug
    id ? "ptx-#{id}" : "ptx-tmp-#{SecureRandom.hex(8)}"
  end

  def parsed_metadata
    metadata.present? ? JSON.parse(metadata) : {}
  end

  def pending?
    status == "pending"
  end

  def confirmed?
    status == "confirmed"
  end

  private

  def update_slug_with_id
    update_column(:slug, "ptx-#{id}")
  end
end
