require "test_helper"

# Consolidated wallet sign-in (solana:signIn) hands the server a message the
# WALLET composed, not one this app built. A Wallet Standard wallet is free to
# add URI / Version / Chain ID / Issued At lines our hand-rolled message never
# carried, and the client now posts the wallet's exact bytes.
#
# This pins the claim that let signIn ship WITHOUT a server change:
# Solana::AuthVerifier's two structural assertions — the host as the opening
# token (OPSEC-018) and a `Nonce: <value>` field — hold against the fuller
# format. If solana-studio ever tightens that parsing, this goes red here, at
# the verifier, instead of surfacing as a mystery 401 in the browser.
class Solana::AuthVerifierSiwsFormatTest < ActiveSupport::TestCase
  HOST = "turfmonster.media".freeze

  setup do
    @key     = Ed25519::SigningKey.generate
    @address = Solana::Keypair.encode_base58(@key.verify_key.to_bytes)
    @nonce   = SecureRandom.hex(16)
  end

  # The full field set a Wallet Standard wallet emits, as opposed to the four
  # lines solanaConnectAndVerify builds on the fallback path.
  def wallet_composed_message(host: HOST, nonce: @nonce, statement: "Sign in to Turf Monster")
    <<~MSG.strip
      #{host} wants you to sign in with your Solana account:
      #{@address}

      #{statement}

      URI: https://#{host}
      Version: 1
      Chain ID: solana:mainnet
      Nonce: #{nonce}
      Issued At: #{Time.current.utc.iso8601}
    MSG
  end

  def verify(message, stored_nonce: @nonce, host: HOST)
    Solana::AuthVerifier.verify!(
      message:       message,
      signature_b58: Solana::Keypair.encode_base58(@key.sign(message)),
      pubkey_b58:    @address,
      expected_host: host,
      stored_nonce:  stored_nonce,
      nonce_at:      Time.current.to_i
    )
  end

  test "accepts a wallet-composed SIWS message carrying the optional fields" do
    assert_equal @address, verify(wallet_composed_message),
                 "verifier must accept the fuller format solana:signIn produces"
  end

  test "host binding still holds against the wallet-composed format" do
    # A message the user signed for a DIFFERENT dapp, carrying our nonce.
    foreign = wallet_composed_message(host: "evil.example")

    assert_raises(Solana::AuthVerifier::VerificationError) do
      verify(foreign, host: HOST)
    end
  end

  test "nonce binding still holds against the wallet-composed format" do
    assert_raises(Solana::AuthVerifier::VerificationError) do
      verify(wallet_composed_message(nonce: SecureRandom.hex(16)))
    end
  end

  test "single-line link-mode statement keeps the User-ID binding readable" do
    # SIWS `statement` is one line per the spec grammar, so link mode inlines the
    # binding rather than writing it as its own paragraph the way the fallback
    # message does. Solana::SessionAuth checks `message.include?`, which both
    # shapes satisfy — this pins the inline shape specifically.
    message = wallet_composed_message(statement: "Sign in to Turf Monster (User-ID: 4242)")

    assert_equal @address, verify(message)
    assert_includes message, "User-ID: 4242"
    assert_equal 1, message.lines.count { |l| l.include?("Sign in to Turf Monster") },
                 "statement must stay on a single line"
  end

  test "a tampered message fails before any binding check" do
    message = wallet_composed_message
    signature = Solana::Keypair.encode_base58(@key.sign(message))

    assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message:       message.sub("Version: 1", "Version: 2"), # signed bytes changed
        signature_b58: signature,
        pubkey_b58:    @address,
        expected_host: HOST,
        stored_nonce:  @nonce,
        nonce_at:      Time.current.to_i
      )
    end
  end
end
