module Solana
  # The transaction that CREATED a program account: a success on the address
  # that carries the creating instruction, signed by the expected key, with the
  # address writable. `init` runs once, so at most one transaction passes.
  #
  # A success on the address proves nothing by itself: anyone can send lamports
  # to it, before the account exists or after.
  #
  # nil means "not known": none of the address's recent signatures can be shown
  # to be the one, or the RPC has no record of the one that is (getTransaction
  # null). It is never "not created".
  class CreatingSignature
    HISTORY_LIMIT = 20

    def self.find(address, instructions:, signer:, client:, commitment: "finalized")
      history = client.send(:call, "getSignaturesForAddress", # private in the gem
                            [address, { "limit" => HISTORY_LIMIT, "commitment" => commitment }])
      Array(history).reverse_each do |row| # the RPC answers newest first
        next if row.nil? || row["err"] || row["signature"].blank?
        return row["signature"] if creates?(row["signature"], address, instructions, signer, client)
      end
      nil
    end

    def self.creates?(signature, address, instructions, signer, client)
      Array(instructions).any? do |name|
        TxVerifier.verify!(signature: signature, instruction_name: name, signer_pubkey: signer,
                           writable_pubkey: address, client: client)
      rescue TxVerifier::VerificationError # NotFound too: a transaction that cannot be read is not chosen
        false
      rescue Client::RpcError => e
        # -32015: a versioned transaction, which this client's getTransaction
        # refuses. Not chosen, like any other it cannot read; raising would let
        # one sent to the address before the entry hide the entry for good.
        e.code == -32_015 ? false : raise
      end
    end
  end
end
