# frozen_string_literal: true

require "test_helper"

# The rehearsal driver signs in as a wallet without a browser. Everything
# downstream — prepare_entry, confirm_onchain_entry — is gated on that session
# succeeding, so these tests assert against the REAL verifier the server runs
# (Solana::AuthVerifier.verify! from solana-studio) rather than against a
# restatement of its rules. If the gem tightens the contract, this goes red.
class QaRehearsalSignInMessageTest < ActiveSupport::TestCase
  HOST = "turf-monster-qa.herokuapp.com"

  setup do
    @keypair = Solana::Keypair.generate
    @pubkey  = @keypair.to_base58
    @nonce   = SecureRandom.hex(16)
  end

  def sign(message)
    Solana::Keypair.encode_base58(@keypair.sign(message))
  end

  test "a built message, signed, satisfies the production verifier" do
    message = TurfMonster::QaRehearsal::SignInMessage.build(
      host: HOST, pubkey: @pubkey, nonce: @nonce
    )

    verified = Solana::AuthVerifier.verify!(
      message:       message,
      signature_b58: sign(message),
      pubkey_b58:    @pubkey,
      expected_host: HOST,
      stored_nonce:  @nonce,
      nonce_at:      Time.now.to_i
    )

    assert_equal @pubkey, verified
  end

  # The host prefix is the OPSEC-018 binding. If this assertion can pass with a
  # message built for another domain, the binding is not doing its job — so the
  # test is written to fail loudly rather than to describe the happy path twice.
  test "a message built for another host is refused" do
    message = TurfMonster::QaRehearsal::SignInMessage.build(
      host: "evil.example.com", pubkey: @pubkey, nonce: @nonce
    )

    error = assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message:       message,
        signature_b58: sign(message),
        pubkey_b58:    @pubkey,
        expected_host: HOST,
        stored_nonce:  @nonce,
        nonce_at:      Time.now.to_i
      )
    end

    assert_match(/not bound to host/, error.message)
  end

  test "a stale nonce is refused even with a valid signature" do
    message = TurfMonster::QaRehearsal::SignInMessage.build(
      host: HOST, pubkey: @pubkey, nonce: @nonce
    )

    error = assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message:       message,
        signature_b58: sign(message),
        pubkey_b58:    @pubkey,
        expected_host: HOST,
        stored_nonce:  @nonce,
        nonce_at:      Time.now.to_i - (Solana::AuthVerifier::NONCE_MAX_AGE + 60)
      )
    end

    assert_match(/expired/i, error.message)
  end

  # OPSEC-005: the User-ID binding is only required on authenticated calls, and
  # sign-in has no current_user. Both shapes are asserted because emitting the
  # line at LOGIN would be harmless-looking and wrong — the server greps for it
  # only when it passed expected_user_id, so a stray line would go unnoticed
  # here and then diverge from what the browser actually sends.
  test "omits the User-ID line at login and embeds it when asked" do
    login = TurfMonster::QaRehearsal::SignInMessage.build(
      host: HOST, pubkey: @pubkey, nonce: @nonce
    )
    refute_includes login, "User-ID:"

    bound = TurfMonster::QaRehearsal::SignInMessage.build(
      host: HOST, pubkey: @pubkey, nonce: @nonce, user_id: 42
    )
    assert_includes bound, "User-ID: 42"
  end

  # The verifier greps `Nonce: (\w+)`. A nonce rendered anywhere that regex
  # cannot reach it reads as "Invalid nonce" — a confusing error for a message
  # that plainly contains the value.
  test "the nonce is reachable by the verifier's own pattern" do
    message = TurfMonster::QaRehearsal::SignInMessage.build(
      host: HOST, pubkey: @pubkey, nonce: @nonce
    )

    assert_equal @nonce, message.match(/Nonce: (\w+)/)&.captures&.first
  end

  test "refuses to build without the parts the contract requires" do
    [
      { host: "", pubkey: @pubkey, nonce: @nonce },
      { host: HOST, pubkey: "", nonce: @nonce },
      { host: HOST, pubkey: @pubkey, nonce: "" }
    ].each do |args|
      assert_raises(ArgumentError) { TurfMonster::QaRehearsal::SignInMessage.build(**args) }
    end
  end
end
