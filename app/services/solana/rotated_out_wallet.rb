module Solana
  # Rotated-out keys whose addresses no user row may keep. Wallet sign-in finds
  # its user by `web3_solana_address`, so a row holding one of these addresses
  # signs in for whoever holds the key, and these keys are, or may be, held by
  # people they were never meant for. No parked identity carries one either.
  module RotatedOutWallet
    # The house account's former wallet (solana.turf.admin), rotated out of both
    # Squads on 2026-10-09.
    ADDRESS = "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo".freeze

    # Mack's former devnet key. Its SECRET sat in this public repository
    # (e2e/devnet-smoke.spec.js, 2026-04-12 to 2026-10-24), so anyone can sign
    # with it; it was evicted from the devnet vault and retired on 2026-10-24
    # (task rotate-leaked-devnet-mack-key). Mack's parked identity now carries
    # his new key, so the QA rehearsal's seed step re-points his row.
    LEAKED_MACK = "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds".freeze

    ADDRESSES = [ADDRESS, LEAKED_MACK].freeze

    module_function

    def holders
      User.where(web3_solana_address: ADDRESSES)
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
