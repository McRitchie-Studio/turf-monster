# frozen_string_literal: true

require "yaml"

module TurfMonster
  module QaRehearsal
    # Refuses any key the rehearsal loads, player or co-signer, that holds
    # MAINNET authority: a mainnet VaultState signer (seated or incoming) or a
    # mainnet Squads member. A key a mainnet rotation retired stays fenced
    # (`retired`) until someone decides on purpose that the rehearsal may load it.
    #
    # The rehearsal co-signs devnet transactions unattended with agent keys it
    # loads from 1Password. Before devnet-v026-upgrade the devnet and mainnet
    # signer sets were the same three keys, so "a key the rehearsal may sign
    # with" and "a key that moves mainnet money" were one population. The devnet
    # rotation split them; this fence keeps them split. Driver#keys wraps the
    # key store in FencedKeys, so a fenced key is refused as it loads, before it
    # signs anything, even on devnet: a devnet chore must never exercise, cache
    # or leak a key whose other job is mainnet.
    #
    # The list is FILED (config/mainnet_vault_signers.yml plus production's
    # system wallet from config/solana_signers.yml), never read from mainnet:
    # nothing in the rehearsal reaches mainnet, and this class is no exception.
    class MainnetSignerFence
      class Refused < StandardError; end

      FENCE_PATH = File.expand_path("../../../config/mainnet_vault_signers.yml", __dir__)
      ISOLATION_PATH = File.expand_path("../../../config/solana_signers.yml", __dir__)

      def self.default
        new(keys: load_keys)
      end

      # Every fenced key. An unreadable or empty list RAISES: a fence that read
      # nothing would pass every key, which is the one answer it must never give.
      def self.load_keys(fence_path: FENCE_PATH, isolation_path: ISOLATION_PATH)
        filed = YAML.safe_load_file(fence_path)
        keys = Array(filed["seated"]) + Array(filed["incoming"]) + Array(filed["squad"]) + Array(filed["retired"])
        production = YAML.safe_load_file(isolation_path).dig("environments", "production", "system_wallet")
        keys << production if production
        keys = keys.map(&:to_s).map(&:strip).reject(&:empty?).uniq
        raise Refused, "the mainnet signer list #{fence_path} is empty, so no co-signer can be cleared" if keys.empty?

        keys
      rescue Errno::ENOENT, Psych::Exception, NoMethodError => e
        raise Refused, "the mainnet signer list could not be read (#{e.class}), so no co-signer can be cleared"
      end

      attr_reader :keys

      def initialize(keys:)
        @keys = keys.map(&:to_s).freeze
      end

      def fenced?(pubkey)
        keys.include?(pubkey.to_s)
      end

      # Raises naming every fenced key among `pubkeys`, labelled by `who`
      # ({ pubkey => cast slug }) when the caller knows it.
      # The key store, fenced: a loaded key with mainnet authority is refused
      # before the caller ever holds it.
      class FencedKeys
        def initialize(store, fence)
          @store = store
          @fence = fence
        end

        def keypair(who)
          kp = @store.keypair(who)
          @fence.refuse!([kp.to_base58], who: { kp.to_base58 => who.to_s })
          kp
        end

        def address(who)
          keypair(who).to_base58
        end
      end

      def refuse!(pubkeys, who: {})
        hits = Array(pubkeys).map(&:to_s).select { |pk| fenced?(pk) }
        return if hits.empty?

        named = hits.map { |pk| who[pk] ? "#{who[pk]} (#{pk})" : pk }.join(", ")
        raise Refused, "#{named} also holds MAINNET authority (a VaultState signer or Squads member); the " \
                       "rehearsal never co-signs with a mainnet key, even on devnet. Nothing was signed or sent. Seat a devnet-only " \
                       "agent key instead (config/mainnet_vault_signers.yml lists the fence)."
      end
    end
  end
end
