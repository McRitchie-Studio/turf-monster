module Solana
  # A rotated-out key that was the house account's wallet. No parked identity
  # carries it, and no user row may keep it: wallet sign-in finds its user by
  # `web3_solana_address`, so a row holding this address signs in for whoever
  # holds the key.
  module RotatedOutWallet
    ADDRESS = "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo".freeze

    module_function

    def holders
      User.where(web3_solana_address: ADDRESS)
    end

    # Clears the address and the web3 sign-in memory from every holder and
    # rotates its session token, so a session the key opened ends on its next
    # request. The account, its role and its email stay. Returns a label per
    # cleared row; a second call finds none and writes nothing.
    def clear_from_users!
      User.transaction do
        holders.to_a.map do |user|
          # update_columns: a wallet-only row has no other sign-in method, and
          # its own validation must not refuse the revocation.
          user.update_columns(web3_solana_address: nil, web3_authenticated_at: nil,
                              web3_wallet_provider: nil, updated_at: Time.current)
          user.regenerate_session_token!
          user.username.presence || "user ##{user.id}"
        end
      end
    end
  end
end
