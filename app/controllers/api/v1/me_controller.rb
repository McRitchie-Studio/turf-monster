# GET /api/v1/me — who this key acts for, and what they can play with.
#
# The first call an agent makes: it confirms the key works and tells the agent
# whether the player has a free entry to spend and whether the server can sign
# for them. Read-only, so it stays open to a frozen account (and says so).
module Api
  module V1
    class MeController < BaseController
      def show
        user = current_user

        render json: {
          user: {
            display_name: user.display_name,
            username: user.username
          },
          wallet: {
            kind: wallet_kind(user),
            address: user.solana_address
          },
          free_entry_tokens: free_entry_tokens(user),
          account: { frozen: user.frozen? },
          api_key: {
            prefix: current_api_key.prefix,
            name: current_api_key.name,
            expires_at: current_api_key.expires_at.iso8601,
            eligibility: current_api_key.eligibility
          }
        }
      end

      private

      # What an agent needs to know is WHO SIGNS, which is not quite
      # User#wallet_kind: a managed wallet the player has since exported is
      # theirs to sign with, not ours (User#self_custodied?).
      #   "managed"        — the server signs entries for this player
      #   "self_custodied" — the player's own wallet must sign
      #   "none"           — no wallet yet
      def wallet_kind(user)
        case user.wallet_kind
        when :managed then user.self_custodied? ? "self_custodied" : "managed"
        when :phantom then "self_custodied"
        else "none"
        end
      end

      # null means "we could not read the chain just now", never "zero".
      def free_entry_tokens(user)
        user.entry_token_balance!
      rescue StandardError => e
        Rails.logger.warn("[api] entry token read failed user=#{user.id}: #{e.class}: #{e.message.to_s[0, 140]}")
        nil
      end
    end
  end
end
