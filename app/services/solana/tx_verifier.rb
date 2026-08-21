module Solana
  # OPSEC-010: semantic verification of a confirmed Solana transaction.
  #
  # Before this existed, controllers accepted `params[:tx_signature]` and only
  # verified the TX landed without an error. An attacker could submit ANY
  # successful tx signature (e.g. a $0.01 SOL transfer they made) to
  # "confirm" an entry/contest/settlement — the DB would flip state based on
  # an unrelated tx. This class fetches the actual transaction and asserts:
  #   1. The TX touches our Anchor program (Solana::Config::PROGRAM_ID).
  #   2. The first matching instruction has the expected Anchor discriminator
  #      (i.e., it really IS create_contest / enter_contest_direct /
  #      settle_contest / mint_entry_token / etc.).
  #   3. (optional) An expected pubkey is present and in a signer slot.
  #   4. (optional) An expected PDA is present and marked writable.
  #
  # Usage:
  #   Solana::TxVerifier.verify!(
  #     signature: params[:tx_signature],
  #     instruction_name: "enter_contest_direct",
  #     signer_pubkey: current_user.web3_solana_address,
  #     writable_pubkey: derived_entry_pda_b58,
  #   )
  #
  # On any mismatch it raises Solana::TxVerifier::VerificationError with a
  # specific error message (the controller wrapper translates that to a
  # StandardError so existing rescue chains still work).
  class TxVerifier
    class VerificationError < StandardError; end

    def self.verify!(signature:, instruction_name:, signer_pubkey: nil, writable_pubkey: nil, client: nil)
      raise VerificationError, "Transaction signature required" if signature.blank?

      client ||= Solana::Config.client
      tx_info = client.get_transaction(signature)
      raise VerificationError, "Transaction not found on-chain" unless tx_info

      if (err = tx_info.dig("meta", "err"))
        custom_code = err.dig("InstructionError", 1, "Custom") rescue nil
        detail = custom_code ? "program error code #{custom_code}" : err.inspect
        raise VerificationError, "Transaction failed on-chain (#{detail})"
      end

      message = tx_info.dig("transaction", "message")

      # Test stubs (config/initializers/test_solana_stubs.rb) return a
      # permissive { transaction: {} } shape for MockTxSignature… inputs.
      # Skip semantic checks there — unit tests in test/services/solana/
      # tx_verifier_test.rb cover the semantic logic via constructed
      # fixtures, so we still get coverage of the verifier itself.
      return true if message.nil? && Rails.env.test?

      raise VerificationError, "Transaction missing message data" if message.nil?

      account_keys = message["accountKeys"] || []
      raise VerificationError, "Transaction has no accountKeys" if account_keys.empty?

      header = message["header"] || {}
      num_signers          = header["numRequiredSignatures"].to_i
      num_readonly_signed  = header["numReadonlySignedAccounts"].to_i
      num_readonly_unsigned = header["numReadonlyUnsignedAccounts"].to_i
      total = account_keys.length

      expected_discriminator = Solana::Transaction.anchor_discriminator(instruction_name)
      program_id = Solana::Config::PROGRAM_ID

      match = find_matching_instruction(message["instructions"], account_keys, program_id, expected_discriminator)
      raise VerificationError, "Transaction does not contain a `#{instruction_name}` instruction on program #{program_id}" unless match

      verify_signer!(account_keys, num_signers, signer_pubkey) if signer_pubkey
      verify_writable!(account_keys, num_signers, num_readonly_signed, num_readonly_unsigned, total, writable_pubkey) if writable_pubkey

      true
    end

    def self.find_matching_instruction(instructions, account_keys, program_id, expected_discriminator)
      total = account_keys.length
      Array(instructions).find do |ix|
        program_idx = ix["programIdIndex"]
        next false unless program_idx && program_idx < total
        next false unless account_keys[program_idx] == program_id

        data_b58 = ix["data"]
        next false if data_b58.blank?

        # The "json" encoding (gem default) returns instruction data as base58.
        data_bytes = Solana::Keypair.decode_base58(data_b58)
        data_bytes[0, 8] == expected_discriminator
      end
    end

    def self.verify_signer!(account_keys, num_signers, signer_pubkey)
      idx = account_keys.index(signer_pubkey)
      raise VerificationError, "Expected signer #{signer_pubkey} not present in tx" unless idx
      raise VerificationError, "Account #{signer_pubkey} present but not in a signer slot" unless idx < num_signers
    end

    def self.verify_writable!(account_keys, num_signers, num_readonly_signed, num_readonly_unsigned, total, writable_pubkey)
      idx = account_keys.index(writable_pubkey)
      raise VerificationError, "Expected writable account #{writable_pubkey} not present in tx" unless idx

      # Standard Solana message layout for writable bits:
      #   First num_signers entries are signers:
      #     - The first (num_signers - num_readonly_signed) are writable
      #     - The remaining num_readonly_signed are readonly
      #   The remaining (total - num_signers) entries are non-signers:
      #     - The first (total - num_signers - num_readonly_unsigned) are writable
      #     - The remaining num_readonly_unsigned are readonly
      writable = if idx < num_signers
        idx < (num_signers - num_readonly_signed)
      else
        (idx - num_signers) < ((total - num_signers) - num_readonly_unsigned)
      end

      raise VerificationError, "Account #{writable_pubkey} not marked writable in tx" unless writable
    end

    private_class_method :find_matching_instruction, :verify_signer!, :verify_writable!
  end
end
