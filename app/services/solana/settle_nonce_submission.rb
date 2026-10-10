module Solana
  # The server half of a nonce-anchored settle (bin/settle-nonce): rebuild a
  # queued row on the current nonce, and submit the bytes the CLI cosigners
  # signed. Contests::SettlementSweepJob records a landed settle, as it does
  # for a Phantom broadcast.
  class SettleNonceSubmission
    class Refused < StandardError; end

    def initialize(pending_transaction, vault: Vault.new)
      @tx = pending_transaction
      @vault = vault
    end

    def wire
      @tx.serialized_tx
    end

    # Rebuild on the nonce's current value, with `extra_cosigners` slots for a
    # three-signature settle. Only a pending nonce row, and only while the
    # cluster's settle nonce is on.
    def rebuild!(extra_cosigners: [], settings: SettleNonce.current)
      assert_pending_nonce_row!
      raise Refused, "the settle nonce is off for #{Config::NETWORK}; nothing to rebuild on" unless settings

      extras = CosignPlan.new(tx_type: @tx.tx_type).validate_extras!(extra_cosigners, primary: settings.cosigner)
      meta = @tx.parsed_metadata
      result = SettleNonce.build_settle(vault: @vault, slug: @tx.target.slug,
                                        settlements: meta.fetch("settlements").map(&:symbolize_keys),
                                        default_cosigner: settings.cosigner, extra_cosigners: extras,
                                        settings: settings)
      metadata = meta.merge("durable_nonce" => result.fetch(:durable_nonce)).to_json
      rebuilt = PendingTransaction.where(id: @tx.id, status: "pending")
                                  .update_all(serialized_tx: result.fetch(:serialized_tx), metadata: metadata,
                                              updated_at: Time.current) == 1
      raise Refused, "#{@tx.slug} is no longer pending; reconcile it instead" unless rebuilt

      @tx.reload
    end

    # Broadcast the cosigned wire. It must carry exactly the stored message with
    # every slot validly signed. Returns the signature.
    def submit!(signed_wire_base64)
      assert_pending_nonce_row!
      signed = WireMessage.parse_base64(signed_wire_base64)
      stored = WireMessage.parse_base64(wire)
      raise Refused, "the signed wire carries a different message from #{@tx.slug}" unless signed.message_bytes == stored.message_bytes

      unsigned = (0...signed.num_required_signatures).reject { |i| signed.signature_valid?(i) }
      if unsigned.any?
        keys = unsigned.map { |i| Keypair.encode_base58(signed.account_keys[i]) }
        raise Refused, "slots not validly signed: #{keys.join(', ')}"
      end

      assert_nonce_unspent!(stored)
      signature = signed.signature
      raise Refused, "#{@tx.slug} is already being broadcast (#{@tx.reload.status})" unless @tx.claim_for_broadcast!(signature)

      begin
        @vault.simulate_and_broadcast(signed_wire_base64)
      rescue Cosign::PreflightRejected => e
        @tx.rewind_broadcast!(signature)
        @tx.note_settle_refused!(e.message, vault: @vault)
        raise
      end

      signature
    end

    private

    # A wire whose nonce has advanced can never land; refuse it before the claim.
    def assert_nonce_unspent!(stored)
      account = Keypair.encode_base58(stored.instructions.first[:accounts].first)
      data = @vault.client.get_account_info(account)&.dig("value", "data", 0)
      raise Refused, "nonce account #{account} could not be read; nothing was sent" unless data

      current = NonceAccount.parse(Base64.decode64(data)).nonce
      return if current == stored.recent_blockhash_base58

      raise Refused, "nonce #{account} has advanced to #{current}, so this wire can never land; " \
                     "rebuild it with bin/settle-nonce rebuild and sign again"
    end

    def assert_pending_nonce_row!
      raise Refused, "#{@tx.slug} is not a settle_contest row" unless @tx.tx_type == "settle_contest"
      raise Refused, "#{@tx.slug} is a blockhash settle; cosign it in Phantom" unless @tx.nonce_anchored?
      raise Refused, "#{@tx.slug} is #{@tx.status}, not pending" unless @tx.pending?
    end
  end
end
