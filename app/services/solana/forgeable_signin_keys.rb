module Solana
  # The Ed25519 public keys no wallet can hold, refused wherever this app trusts
  # a Solana signature for an address.
  #
  # WHY IT EXISTS. solana-studio 0.11.0's Solana::AuthVerifier.verify! accepts
  # small-order public keys. Exactly fourteen 32-byte strings decode to a
  # small-order point, and no keypair produces any of them, so an address from
  # this list is never a real wallet. Refusing them costs no user anything:
  # measured before this shipped, no account on mainnet or QA held one.
  #
  # STOPGAP — DELETE ONCE turf bumps to a solana-studio release carrying
  # Solana::Ed25519Strict (task reject-small-order-signin-keys,
  # https://mcritchie.studio/tasks/reject-small-order-signin-keys). verify! then
  # refuses these keys itself, and this module, its call sites and its tests
  # become redundant.
  #
  # WHERE IT IS CALLED, each immediately after the signature check and before
  # anything reads or writes a user by the address:
  #   * SolanaSessionsController#verify   (wallet sign-in / sign-up)
  #   * AccountsController#link_solana     (wallet link and account merge)
  #   * WalletExportsController#complete   (self-custody proof)
  # test/integration/forgeable_signin_keys_refusal_test.rb fails if a file in
  # app/ checks a signature without calling refuse!.
  #
  # THE REFUSAL IS A BAD SIGNATURE. refuse! raises the same error, with the same
  # message, that verify! raises for a signature that does not verify, so the
  # response does not say why. The attempt is recorded in error_logs instead —
  # a signature that verifies for one of these keys is never an honest request.
  module ForgeableSigninKeys
    # Base58 address => the 32 bytes it names. Eight canonical encodings of the
    # small-order points, then six other encodings the decoder maps to them.
    # Provenance: solana-studio test/ed25519_forgery_support.rb (PR 52); the set
    # is re-derived from the curve in test/services/solana/forgeable_signin_keys_test.rb.
    ENCODINGS = {
      "4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofM"  => "0100000000000000000000000000000000000000000000000000000000000000",
      "Gx9dDNxzpALCowVuZb7pBceBLJugLA8sPa6TJDXrpfeW" => "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "11111111111111111111111111111111"             => "0000000000000000000000000000000000000000000000000000000000000000",
      "11111111111111111111111111111113D"            => "0000000000000000000000000000000000000000000000000000000000000080",
      "3ctC68zTqpRDQShoondiQKDHwZDAUjRyxiPNdg8cD6Pe" => "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
      "3ctC68zTqpRDQShoondiQKDHwZDAUjRyxiPNdg8cD6Rr" => "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
      "EQAqmjhcsBQhpBv5GJkYgEB7emGHZNoo1j1yAjiFLNvD" => "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
      "EQAqmjhcsBQhpBv5GJkYgEB7emGHZNoo1j1yAjiFLNxR" => "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
      "4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziohZ"  => "0100000000000000000000000000000000000000000000000000000000000080",
      "H5xSWNRAbqKddKjrabehyU8drL3Dk4LgZJiEJc9rGGyC" => "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "H5xSWNRAbqKddKjrabehyU8drL3Dk4LgZJiEJc9rGH1Q" => "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "Gx9dDNxzpALCowVuZb7pBceBLJugLA8sPa6TJDXrpfgi" => "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "H242rsh5hzpvDdct56PG5YPQbKUT37EmySQLoQqrYUJr" => "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "H242rsh5hzpvDdct56PG5YPQbKUT37EmySQLoQqrYUM4" => "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }.freeze

    KEY_BYTES = ENCODINGS.values.to_set { |hex| [hex].pack("H*").b }.freeze

    # What verify! says about a signature that does not verify. Asserted against
    # a live bad-signature response, so a change in the gem's wording fails a test.
    REFUSAL_MESSAGE = "Signature verification failed: signature verification failed!".freeze

    # Raised only to give the error_logs row a class and a backtrace.
    class Refused < StandardError; end

    # A base58 address longer than this cannot decode to 32 bytes.
    MAX_ADDRESS_LENGTH = 64

    module_function

    # Matched on the decoded bytes as well as the listed spelling: the decoder
    # maps more than one string to some of these keys.
    def forgeable?(pubkey_b58)
      address = pubkey_b58.to_s
      return false if address.empty? || address.length > MAX_ADDRESS_LENGTH
      return true if ENCODINGS.key?(address)

      KEY_BYTES.include?(::Solana::Keypair.decode_base58(address).b)
    rescue ArgumentError
      false
    end

    # Returns the address when it is not forgeable; otherwise records the
    # attempt and raises Solana::AuthVerifier::VerificationError.
    def refuse!(pubkey_b58, context:)
      return pubkey_b58 unless forgeable?(pubkey_b58)

      record(pubkey_b58, context)
      raise ::Solana::AuthVerifier::VerificationError, REFUSAL_MESSAGE
    end

    def record(pubkey_b58, context)
      raise Refused, "refused a small-order public key at #{context}: #{pubkey_b58}"
    rescue Refused => e
      Rails.logger.warn("[solana][forgeable-key] #{e.message}")
      begin
        ErrorLog.capture!(e)
      rescue StandardError => log_error
        Rails.logger.error("[solana][forgeable-key] error log dropped: #{log_error.class}: #{log_error.message}")
      end
    end
    private_class_method :record
  end
end
