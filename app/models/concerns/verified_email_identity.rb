# The email rules a User row holds to.
#
# - Stored addresses are stripped and downcased, and unique without regard to
#   case, so two rows cannot differ by case alone.
# - A verified stamp belongs to one address: writing a new address without its
#   own stamp clears it.
# - A parked identity (User::PARKED_IDENTITIES) is granted on proof: a wallet
#   match, or a verified email equal to the parked address. User.parked_identity_for
#   is a roster lookup and proves nothing about its caller.
# - A parked address is written only with its proof: a stamp set in the same
#   save, the parked wallet, or the seed. Nobody holds one unproven.
# - A mailbox proof (#accept_mailbox_proof!) lands on a row that already holds a
#   parked address unproven only when the mailbox becomes the one way into it.
module VerifiedEmailIdentity
  extend ActiveSupport::Concern

  included do
    # Only when the address changes: a row that already collides by case still
    # saves its other fields.
    validates :email, uniqueness: { case_sensitive: false }, allow_nil: true, if: :will_save_change_to_email?
    validate :parked_email_carries_its_proof, if: :will_save_change_to_email?
    before_save :clear_stale_email_verification

    # Set by db/seeds/users.rb alone: there the roster is the authority. No
    # controller permits it.
    attr_accessor :seeding_parked_identity
  end

  def email=(value)
    super(value.is_a?(String) ? value.strip.downcase : value)
  end

  # True when `other` is this account's address, ignoring case and padding.
  def email_matches?(other)
    email.present? && email.strip.casecmp?(other.to_s.strip)
  end

  # A mailbox proof on a row that exists: a magic-link or verification-link
  # click. Whoever reads the mailbox need not be whoever attached this row's
  # session, wallet, Google link or API key, and on a parked address the stamp
  # elevates the row for all of them. So an unproven parked holder is stamped
  # only when it has no other credential, and its live sessions end first; with
  # one, the proof is refused and the row is the operator's to resolve
  # (users:parked_role_audit lists it).
  #
  # False when refused: the caller signs nobody in and stamps nothing.
  def accept_mailbox_proof!
    return true if email_verified_at.present?

    if unproven_parked_holder?
      return false if credential_beside_email?

      regenerate_session_token!
    end
    # update_column: a row a newer validation refuses must still verify.
    update_column(:email_verified_at, Time.current)
    true
  end

  # Holds a parked address with neither proof: no stamp, no parked wallet.
  def unproven_parked_holder?
    email_verified_at.blank? && User.parked_identity_for(email: email).present? && !holds_parked_wallet?
  end

  # A way into this row that the mailbox does not control.
  def credential_beside_email?
    web3_solana_address.present? || provider.present? || uid.present? || api_keys.exists?
  end

  private

  def holds_parked_wallet?
    User.parked_identity_for(wallet: web3_solana_address.presence || web2_solana_address).present?
  end

  # The message a held address gets, so the reply does not single the roster out.
  def parked_email_carries_its_proof
    return unless User.parked_identity_for(email: email)
    return if seeding_parked_identity || holds_parked_wallet?
    return if email_verified_at.present? && !stale_email_verification?

    errors.add(:email, :taken) unless errors.of_kind?(:email, :taken)
  end

  # The roster row this account has proven it owns. An unverified or
  # case-variant email proves nothing, so it grants nothing.
  def proven_parked_identity
    by_wallet = User.parked_identity_for(wallet: web3_solana_address.presence || web2_solana_address)
    return by_wallet if by_wallet
    return nil if email.blank? || email_verified_at.blank?

    User::PARKED_IDENTITIES.find { |identity| identity[:email] == email }
  end

  def clear_stale_email_verification
    self.email_verified_at = nil if stale_email_verification?
  end

  # The stamp was earned for the address this save replaces.
  def stale_email_verification?
    will_save_change_to_email? && !will_save_change_to_email_verified_at? &&
      !email_in_database.to_s.strip.casecmp?(email.to_s)
  end
end
