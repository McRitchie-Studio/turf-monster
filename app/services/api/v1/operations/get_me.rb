# GET /api/v1/me, and the MCP tool `get_me`: who this credential acts for, and
# what they can play with. Read-only, so it answers for a frozen account (and
# says so).
module Api
  module V1
    module Operations
      class GetMe < Base
        def call
          ok(
            user: { display_name: user.display_name, username: user.username },
            wallet: { kind: wallet_kind, address: user.solana_address },
            free_entry_tokens: free_entry_tokens,
            account: { frozen: user.frozen? },
            api_key: {
              prefix: api_key.prefix,
              name: api_key.name,
              expires_at: api_key.expires_at.iso8601,
              eligibility: api_key.eligibility
            }
          )
        end

        private

        # What an agent needs to know is WHO SIGNS, which is not quite
        # User#wallet_kind: a managed wallet the player has since exported is
        # theirs to sign with, not ours (User#self_custodied?).
        #   "managed"        — the server signs entries for this player
        #   "self_custodied" — the player's own wallet must sign
        #   "none"           — no wallet yet
        def wallet_kind
          case user.wallet_kind
          when :managed then user.self_custodied? ? "self_custodied" : "managed"
          when :phantom then "self_custodied"
          else "none"
          end
        end

        # null means "we could not read the chain just now", never "zero".
        def free_entry_tokens
          user.entry_token_balance!
        rescue StandardError => e
          Rails.logger.warn("[api] entry token read failed user=#{user.id}: #{e.class}: #{e.message.to_s[0, 140]}")
          nil
        end
      end
    end
  end
end
