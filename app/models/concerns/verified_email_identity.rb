# The email rules a User row holds to.
#
# - Stored addresses are stripped and downcased, and unique without regard to
#   case, so two rows cannot differ by case alone.
# - A verified stamp belongs to one address: writing a new address without its
#   own stamp clears it.
# - A parked identity (User::PARKED_IDENTITIES) is granted on proof: a wallet
#   match, or a verified email equal to the parked address. User.parked_identity_for
#   is a roster lookup and proves nothing about its caller.
module VerifiedEmailIdentity
  extend ActiveSupport::Concern

  included do
    # Only when the address changes: a row that already collides by case still
    # saves its other fields.
    validates :email, uniqueness: { case_sensitive: false }, allow_nil: true, if: :will_save_change_to_email?
    before_save :clear_stale_email_verification
  end

  def email=(value)
    super(value.is_a?(String) ? value.strip.downcase : value)
  end

  # True when `other` is this account's address, ignoring case and padding.
  def email_matches?(other)
    email.present? && email.strip.casecmp?(other.to_s.strip)
  end

  private

  # The roster row this account has proven it owns. An unverified or
  # case-variant email proves nothing, so it grants nothing.
  def proven_parked_identity
    by_wallet = User.parked_identity_for(wallet: web3_solana_address.presence || web2_solana_address)
    return by_wallet if by_wallet
    return nil if email.blank? || email_verified_at.blank?

    User::PARKED_IDENTITIES.find { |identity| identity[:email] == email }
  end

  def clear_stale_email_verification
    return unless will_save_change_to_email? && !will_save_change_to_email_verified_at?
    return if email_in_database.to_s.strip.casecmp?(email.to_s)

    self.email_verified_at = nil
  end
end
