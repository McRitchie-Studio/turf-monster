require "test_helper"

class Solana::TxVerifierTest < ActiveSupport::TestCase
  # Real PROGRAM_ID + Anchor discriminator so the verifier exercises its full
  # decode path. These fixtures construct realistic getTransaction responses
  # by hand so we can poke each rejection path without depending on the test
  # stub's permissive shape.

  PROGRAM_ID    = Solana::Config::PROGRAM_ID
  WALLET_SIGNER = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze  # human (Mr. McRitchie) Phantom signer
  CONTEST_PDA   = "C88QKhevowD7c3xQDZ3grfdHbpk4FeyYDtdkjz4nz924".freeze  # Season 1 PDA — arbitrary 32-byte base58
  # Arbitrary realistic base58 pubkey standing in for the server/admin signer
  # (the Xan identity, renamed from "Alex Bot" 2026-09-15). It is only an entry
  # in a synthetic getTransaction response and is never compared to the live
  # signer set, so the legacy value is harmless — but the comment this replaces
  # asserted "MULTISIG_SIGNERS still carries F6f8…", which docs/SOLANA.md
  # contradicts: re-verified on-chain 2026-09-05 as 8K81w4e6… on both clusters.
  ADMIN_PUBKEY  = "F6f8h5yynbnkgWvU5abQx3RJxJpe8EoQmeFBuNKdKzhZ".freeze  # stand-in only

  # Build a getTransaction JSON response with:
  #   - admin as signer 0 (writable), wallet as signer 1 (writable)
  #   - PROGRAM_ID at index 2 (readonly non-signer)
  #   - CONTEST_PDA at index 3 (writable non-signer)
  # → numRequiredSignatures: 2, numReadonlySigned: 0, numReadonlyUnsigned: 1
  def build_tx_info(instruction_name: "enter_contest_direct", program_at: PROGRAM_ID, discriminator: nil, err: nil)
    disc_bytes = (discriminator || Solana::Transaction.anchor_discriminator(instruction_name))
    {
      "meta" => { "err" => err },
      "transaction" => {
        "message" => {
          "header" => {
            "numRequiredSignatures" => 2,
            "numReadonlySignedAccounts" => 0,
            "numReadonlyUnsignedAccounts" => 1,
          },
          "accountKeys" => [ADMIN_PUBKEY, WALLET_SIGNER, CONTEST_PDA, program_at],
          "instructions" => [{
            "programIdIndex" => 3,
            "accounts" => [0, 1, 2],
            "data" => Solana::Keypair.encode_base58(disc_bytes),
          }]
        }
      }
    }
  end

  def mock_client(tx_info)
    Object.new.tap do |o|
      o.define_singleton_method(:get_transaction) { |_sig| tx_info }
    end
  end

  test "happy path: matching program + discriminator + signer + writable" do
    client = mock_client(build_tx_info(instruction_name: "enter_contest_direct"))
    assert Solana::TxVerifier.verify!(
      signature: "sig-OK",
      instruction_name: "enter_contest_direct",
      signer_pubkey: WALLET_SIGNER,
      writable_pubkey: CONTEST_PDA,
      client: client
    )
  end

  test "missing signature raises VerificationError" do
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(signature: "", instruction_name: "enter_contest_direct")
    end
    assert_match(/signature required/i, err.message)
  end

  test "tx not found raises VerificationError" do
    client = mock_client(nil)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(signature: "x", instruction_name: "enter_contest_direct", client: client)
    end
    assert_match(/not found on-chain/i, err.message)
  end

  test "tx failed on-chain (Custom code) raises with the code in message" do
    tx_info = build_tx_info(err: { "InstructionError" => [0, { "Custom" => 6008 }] })
    client = mock_client(tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(signature: "x", instruction_name: "enter_contest_direct", client: client)
    end
    assert_match(/failed on-chain/i, err.message)
    assert_match(/6008/, err.message)
  end

  test "permissive passthrough in test env when message data is missing (stub-compat)" do
    client = mock_client({ "meta" => { "err" => nil }, "transaction" => {} })
    assert Solana::TxVerifier.verify!(signature: "x", instruction_name: "enter_contest_direct", client: client)
  end

  test "wrong program id rejected" do
    tx_info = build_tx_info(program_at: "WrongProgramID11111111111111111111111111111")
    client = mock_client(tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(signature: "x", instruction_name: "enter_contest_direct", client: client)
    end
    assert_match(/does not contain a `enter_contest_direct`/, err.message)
  end

  test "wrong discriminator rejected" do
    # Stuff a settle_contest discriminator into an enter_contest_direct expectation.
    bad_disc = Solana::Transaction.anchor_discriminator("settle_contest")
    client = mock_client(build_tx_info(discriminator: bad_disc))
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(signature: "x", instruction_name: "enter_contest_direct", client: client)
    end
    assert_match(/does not contain a `enter_contest_direct`/, err.message)
  end

  test "expected signer not present in tx rejected" do
    client = mock_client(build_tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(
        signature: "x",
        instruction_name: "enter_contest_direct",
        signer_pubkey: "Bogus11111111111111111111111111111111111111",
        client: client
      )
    end
    assert_match(/Expected signer.*not present/i, err.message)
  end

  test "expected signer present but not in signer slot rejected" do
    # CONTEST_PDA is account index 2 — not a signer slot (numRequiredSignatures = 2)
    client = mock_client(build_tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(
        signature: "x",
        instruction_name: "enter_contest_direct",
        signer_pubkey: CONTEST_PDA,
        client: client
      )
    end
    assert_match(/not in a signer slot/i, err.message)
  end

  test "expected writable not present rejected" do
    client = mock_client(build_tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(
        signature: "x",
        instruction_name: "enter_contest_direct",
        writable_pubkey: "Bogus11111111111111111111111111111111111111",
        client: client
      )
    end
    assert_match(/Expected writable.*not present/i, err.message)
  end

  test "expected writable present but readonly rejected" do
    # PROGRAM_ID is index 3 — in the readonly-unsigned bucket (numReadonlyUnsigned = 1)
    client = mock_client(build_tx_info)
    err = assert_raises(Solana::TxVerifier::VerificationError) do
      Solana::TxVerifier.verify!(
        signature: "x",
        instruction_name: "enter_contest_direct",
        writable_pubkey: PROGRAM_ID,
        client: client
      )
    end
    assert_match(/not marked writable/i, err.message)
  end
end
