# One free entry, addressed to an email that may not have an account yet.
#
# THE GAP THIS MODEL EXISTS TO CROSS. A "free entry" in Turf Monster is an
# on-chain EntryTokenAccount PDA, and minting one needs a wallet ADDRESS. An
# invitation has only an email. So the gift cannot be a mint — it is a promise
# with three stamped moments:
#
#   sent     — the row exists and the invite email is out (created_at)
#   claimed  — the recipient clicked, so an account and a wallet now exist
#              (claimed_at + claimed_by)
#   minted   — the token is on chain (minted_at + mint_signature)
#
# Each moment has its own column because a gift that stops between two of them
# is the interesting one: #stalled? is what the admin ledger renders loudly
# instead of letting an unpayable promise sit quietly as "sent".
#
# NOTHING HERE DECIDES WHETHER A MINT IS SAFE TO REPEAT. That is #mint_source_ref
# and the program's `init` on its PDA — the same argument Tokens::LevelUpGrant
# makes: a deterministic ref makes a retry collide on chain rather than pay
# twice, so no bookkeeping in this table can drift into a double-grant.
class EntryGift < ApplicationRecord
  belongs_to :sender,     class_name: "User"
  belongs_to :contest,    optional: true
  belongs_to :claimed_by, class_name: "User", optional: true

  # The magic link that carries this gift. Studio::Link's polymorphic `linkable`
  # is what lets MagicLinksController find the gift from the token alone at
  # consume time, with no second identifier riding in the URL.
  has_one :link, class_name: "Studio::Link", as: :linkable, dependent: :nullify

  validates :recipient_email, presence: true
  validates :mint_ref, presence: true, uniqueness: true
  validate  :recipient_email_is_deliverable

  before_validation :normalize_recipient_email
  before_validation :assign_mint_ref, on: :create

  scope :recent,    -> { order(created_at: :desc) }
  scope :unclaimed, -> { where(claimed_at: nil) }
  scope :unminted,  -> { where(minted_at: nil) }

  # How long a gift link stays good. Far longer than a sign-in magic link's 15
  # minutes because the two are not the same object: a sign-in link is a
  # credential the requester is waiting on, while this one is a GIFT sitting in
  # a friend's inbox behind whatever else is in there. A week is the difference
  # between "I'll do it tonight" and a dead link.
  LINK_TTL = 30.days

  # :sent → :claimed → :minted, plus :failed for a claim whose mint could not be
  # completed. Derived from the stamps rather than stored, so there is no status
  # column that can disagree with the timestamps under it.
  def status
    return :minted  if minted_at.present?
    return :failed  if claimed_at.present? && mint_error.present?
    return :claimed if claimed_at.present?

    :sent
  end

  def claimed?
    claimed_at.present?
  end

  def minted?
    minted_at.present?
  end

  # A gift that was claimed but still has no token, and is not merely waiting a
  # few seconds for its job. The admin ledger surfaces exactly these: the
  # recipient has an account and believes they were given something.
  def stalled?
    claimed? && !minted? && claimed_at < 10.minutes.ago
  end

  # The on-chain source_ref this gift's token is keyed by — the IDEMPOTENCY of
  # the whole feature. Deterministic per gift, so a Sidekiq retry after a mint
  # that landed but whose response was lost re-derives the SAME PDA and loses to
  # the program's `init` instead of granting a second token.
  #
  # Namespaced by deployment for the reason Tokens::LevelUpGrant is: QA and
  # production talk to different program deployments, and a ref that did not say
  # which would make a restored dump look like it had already been paid.
  # Comfortably inside the on-chain [u8;64] limit at ~35 bytes.
  def mint_source_ref
    "gift:#{self.class.deployment_namespace}:#{mint_ref}"
  end

  def self.deployment_namespace
    AppFlags.qa_environment? ? "qa" : Rails.env.to_s
  end

  # May the admin ledger show a gift's live claim link?
  #
  # A NAMED PREDICATE RATHER THAN AN INLINE `Rails.env.production?` IN THE VIEW,
  # and the reason is the test, not the taste. Pinning the hidden case by
  # stubbing `Rails.env.production?` stubs it GLOBALLY for the whole request —
  # and Solana::Config raises "SOLANA_NETWORK required in production
  # (OPSEC-012)" at autoload time under that stub. So the test passed or errored
  # depending on whether an earlier test had already loaded that constant:
  # measured green on seeds 222/333/444 and RED on 111. An intermittent CI red
  # dressed as a feature bug. This method is the one thing the test needs to
  # move, so it is the only thing it moves.
  #
  # `Rails.env.production?` and NOT AppFlags.production?, deliberately: a QA app
  # boots in the production env, and this is a live single-use credential for
  # somebody else's account. The stricter reading keeps it to the environments
  # where every account is disposable.
  def self.claim_links_visible?
    !Rails.env.production?
  end

  # Where the invite lands. A gift is nearly always "come play THIS contest",
  # and the contest page is where the onboarding chain (first name → birthday)
  # runs, so an unset contest falls back to the featured one rather than to the
  # root board.
  def landing_contest
    contest || Contest.featured
  end

  private

  def normalize_recipient_email
    self.recipient_email = recipient_email.to_s.strip.downcase.presence
  end

  # Deliberately the SAME predicate the magic-link request path uses
  # (User.valid_email?). A gift whose address this app would refuse to mail a
  # sign-in link to is a gift that can never be claimed, and finding that out at
  # send time is the whole point of validating here.
  def recipient_email_is_deliverable
    return if recipient_email.blank? # presence validation already said so
    return if User.valid_email?(recipient_email)

    errors.add(:recipient_email, "is not a valid email address")
  end

  # 16 hex characters — the unique half of #mint_source_ref. Random rather than
  # the row id because ids repeat across a reseeded database and a restored
  # dump; see the migration's comment.
  def assign_mint_ref
    self.mint_ref ||= SecureRandom.hex(8)
  end
end
