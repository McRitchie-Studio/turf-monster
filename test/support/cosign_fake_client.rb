# The RPC surface `Solana::Cosign` needs, for tests that build a real cosigned
# wire without a network.
#
# WHY THIS EXISTS. Every Phantom-first builder in Solana::Vault now goes through
# `Cosign::Builder`, which calls `client.latest_blockhash(commitment:)` — NOT the
# bare `client.get_latest_blockhash` this app's own builders call. The two are
# different methods with different return types: `get_latest_blockhash` answers a
# base58 String at `finalized`, `latest_blockhash` answers a `LatestBlockhash`
# struct carrying `last_valid_block_height` at `confirmed`. A fake client that
# stubs only the first raises NoMethodError the moment a builder is exercised,
# which is how a dozen suites broke at once when the builders moved.
#
# Stubbing both here, in one place, keeps them AGREEING: the struct's blockhash
# is the same value the String form returns for the same client, so a test that
# reads either sees one transaction.
module CosignFakeClient
  # A deterministic-per-instance blockhash, so two reads inside one test agree
  # and two different fake clients do not collide.
  def self.build(last_valid_block_height: 1_000_000, **extra_methods)
    client = Object.new
    blockhash = Solana::Keypair.generate.to_base58

    client.define_singleton_method(:get_latest_blockhash) { |**_o| blockhash }
    client.define_singleton_method(:latest_blockhash) do |commitment: "confirmed"|
      Solana::Client::LatestBlockhash.new(
        blockhash: blockhash,
        last_valid_block_height: last_valid_block_height,
        slot: nil,
        commitment: commitment
      )
    end

    extra_methods.each { |name, impl| client.define_singleton_method(name, &impl) }
    client
  end

  # Teach an EXISTING fake client the struct form, keeping whatever blockhash its
  # own `get_latest_blockhash` already answers. For a fake that carries other
  # seeded behaviour worth preserving.
  def self.teach(client, last_valid_block_height: 1_000_000)
    client.define_singleton_method(:latest_blockhash) do |commitment: "confirmed"|
      Solana::Client::LatestBlockhash.new(
        blockhash: get_latest_blockhash,
        last_valid_block_height: last_valid_block_height,
        slot: nil,
        commitment: commitment
      )
    end
    client
  end
end
