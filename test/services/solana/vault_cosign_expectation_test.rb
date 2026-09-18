require "test_helper"

# THE APP-SPECIFIC HALF OF THE COSIGN BOUNDARY.
#
# `Solana::Cosign` owns the GENERIC rules and tests them in the gem: the fee
# payer in account 0, the exact signer set, the exact instruction comparison, the
# ComputeBudget cap, the Lighthouse allowlist, and the whole error hierarchy —
# 92 tests across test/cosign_{expectation,completer,builder,lighthouse}_test.rb.
# Re-testing a System transfer or an over-cap fee here would just re-run the
# gem's suite against the gem.
#
# WHAT THIS FILE OWES INSTEAD is everything the gem cannot know: that
# Solana::Vault hands it the RIGHT expectation. The deleted guards
# (assert_entry_cosign_safe! and its two siblings) enforced three app-specific
# bindings by hand, and those bindings must still hold — they are now properties
# of WHICH instruction the vault states, not of the comparison itself:
#
#   1. an entry wire is bound to THIS entry, not another of the same player's;
#   2. a token consume cannot be swapped for a paid entry, or the reverse;
#   3. a cash-out is bound to the destination and amount the SERVER resolved.
#
# Each test below drifts exactly one of those and asserts the refusal, which is
# what proves the binding survived the move into the gem.
class Solana::VaultCosignExpectationTest < ActiveSupport::TestCase
  WALLET = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  SLUG   = "cosign-expectation-test".freeze

  def vault
    @vault ||= Solana::Vault.new(client: CosignFakeClient.build)
  end

  # A second vault with its own fake client, for building the "other" wire a
  # drifted request would carry.
  def other_vault
    Solana::Vault.new(client: CosignFakeClient.build)
  end

  def admin_address
    Solana::Keypair.admin.address
  end

  # Judge `signed_wire` against `expectation`, returning the WireRejected reason
  # or nil when it is admitted. No key, no RPC — Expectation#verify! is pure.
  def verdict(expectation, signed_wire)
    message = Solana::WireMessage.parse(Base64.strict_decode64(signed_wire))
    expectation.verify!(message)
    nil
  rescue Solana::Cosign::WireRejected => e
    e.reason
  end

  # --- what the builders now produce ----------------------------------------

  test "the Phantom entry builder returns a wire AND the deadline that kills it" do
    built = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    assert built[:serialized_tx].present?
    assert built[:entry_pda].present?
    assert_kind_of Integer, built[:last_valid_block_height],
                   "the prepare request must be able to persist the block height past which " \
                   "this wire can never land — without it a dead wire is only discovered by broadcasting it"
  end

  test "the entry expectation names the admin as fee payer and the player as the only cosigner" do
    built = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    expectation = vault.cosign_expectation(built[:serialized_tx], wallet_address: WALLET)

    assert_equal admin_address, Solana::Cosign.base58(expectation.fee_payer)
    assert_equal [WALLET], expectation.cosigners.map { |k| Solana::Cosign.base58(k) }
    assert_equal 1, expectation.instructions.length,
                 "one app instruction — ComputeBudget is priced by the caps, never listed"
  end

  test "the entry expectation admits the wire the builder itself produced" do
    built = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    expectation = vault.cosign_expectation(built[:serialized_tx], wallet_address: WALLET)

    assert_nil verdict(expectation, built[:serialized_tx]),
               "a builder whose own output its expectation refuses would break every entry"
  end

  # --- binding 1: THIS entry ------------------------------------------------

  test "a wire prepared for a DIFFERENT entry number is refused" do
    prepared = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    other    = other_vault.build_enter_contest(WALLET, SLUG, 7, currency_idx: 0, season_id: 1)

    expectation = vault.cosign_expectation(prepared[:serialized_tx], wallet_address: WALLET)

    refute_equal prepared[:entry_pda], other[:entry_pda], "the two entries must derive different PDAs"
    assert_equal "instruction_data_mismatch", verdict(expectation, other[:serialized_tx]),
                 "entry 7's wire must not be cosignable against entry 0's expectation"
  end

  test "a wire prepared for a DIFFERENT contest is refused" do
    prepared = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    other    = other_vault.build_enter_contest(WALLET, "#{SLUG}-elsewhere", 0, currency_idx: 0, season_id: 1)

    expectation = vault.cosign_expectation(prepared[:serialized_tx], wallet_address: WALLET)
    assert_equal "instruction_accounts_mismatch", verdict(expectation, other[:serialized_tx]),
                 "another contest's entry names different PDAs and must be refused"
  end

  test "a wire prepared for a DIFFERENT currency is refused" do
    prepared = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    other    = other_vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 1, season_id: 1)

    expectation = vault.cosign_expectation(prepared[:serialized_tx], wallet_address: WALLET)
    assert_includes %w[instruction_data_mismatch instruction_accounts_mismatch],
                    verdict(expectation, other[:serialized_tx]),
                    "a USDT entry must not be cosignable against a USDC expectation"
  end

  test "the token-entry expectation admits the wire its own builder produced" do
    token_pda = Solana::Keypair.generate.address
    built = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token_pda, season_id: 1)
    expectation = vault.cosign_expectation(built[:serialized_tx], wallet_address: WALLET)

    assert_nil verdict(expectation, built[:serialized_tx])
    assert_kind_of Integer, built[:last_valid_block_height]
  end

  test "NO Phantom-first wire can be anchored on the durable nonce" do
    # The 2026-06-11 mainnet incident: a durable-nonce transaction is only
    # recognised when advanceNonceAccount is instruction 0, and Phantom injects
    # Lighthouse instructions ahead of it, so every nonce-anchored entry died as
    # BlockhashNotFound. The old builder took a `durable_nonce:` keyword that
    # every caller passed nil; the rule was a convention. It is now STRUCTURAL —
    # Cosign::Builder has no nonce concept and #build_partial_unsigned has no
    # such parameter, so the mistake cannot be made by passing an argument.
    refute_includes Solana::Vault.instance_method(:build_partial_unsigned).parameters.map(&:last),
                    :durable_nonce,
                    "the Phantom-first builder must not accept a durable nonce at all"

    # And the wire it produces carries no System instruction of any kind.
    built = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    message = Solana::WireMessage.parse(Base64.strict_decode64(built[:serialized_tx]))
    system_ixs = message.instructions.select { |ix| ix[:program_id] == Solana::Transaction::SYSTEM_PROGRAM_ID.b }
    assert_empty system_ixs, "an entry wire carries no System instruction, nonce advance included"
  end

  # --- binding 2: token consume vs paid entry --------------------------------

  test "a TOKEN consume cannot be cosigned against a PAID entry's expectation" do
    token_pda = Solana::Keypair.generate.address
    paid  = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    token = other_vault.build_enter_contest_with_token(WALLET, SLUG, 0, token_pda, season_id: 1)

    expectation = vault.cosign_expectation(paid[:serialized_tx], wallet_address: WALLET)
    assert_equal "instruction_data_mismatch", verdict(expectation, token[:serialized_tx]),
                 "the discriminators differ, so a free entry cannot be presented for a priced one"
  end

  test "a PAID entry cannot be cosigned against a TOKEN consume's expectation" do
    token_pda = Solana::Keypair.generate.address
    token = vault.build_enter_contest_with_token(WALLET, SLUG, 0, token_pda, season_id: 1)
    paid  = other_vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)

    expectation = vault.cosign_expectation(token[:serialized_tx], wallet_address: WALLET)
    assert_equal "instruction_data_mismatch", verdict(expectation, paid[:serialized_tx])
  end

  test "a consume of a DIFFERENT entry token is refused" do
    mine     = Solana::Keypair.generate.address
    somebody = Solana::Keypair.generate.address
    prepared = vault.build_enter_contest_with_token(WALLET, SLUG, 0, mine, season_id: 1)
    other    = other_vault.build_enter_contest_with_token(WALLET, SLUG, 0, somebody, season_id: 1)

    expectation = vault.cosign_expectation(prepared[:serialized_tx], wallet_address: WALLET)
    assert_equal "instruction_accounts_mismatch", verdict(expectation, other[:serialized_tx]),
                 "the server chose WHICH token is spent; a client cannot swap in another"
  end

  # --- binding 3: the session's wallet ---------------------------------------

  test "an expectation is refused when the stored wire names a different wallet" do
    built = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    stranger = Solana::Keypair.generate.address

    error = assert_raises(Solana::Vault::UnsafeCosignError) do
      vault.cosign_expectation(built[:serialized_tx], wallet_address: stranger)
    end
    assert_match(/prepared_wire_cosigner_mismatch/, error.message)
  end

  test "an absent prepared wire is refused rather than treated as permissive" do
    [nil, ""].each do |empty|
      error = assert_raises(Solana::Vault::UnsafeCosignError) do
        vault.cosign_expectation(empty, wallet_address: WALLET)
      end
      assert_match(/no prepared wire/, error.message)
    end
  end

  # --- the rebuilt expectations (create + cash-out) --------------------------

  def create_params
    { entry_fee_by_currency: [19_000_000], max_entries: 29,
      payout_amounts: [300_000_000, 50_000_000], prize_pool: 350_000_000,
      season_id: 1, lock_timestamp: 0 }
  end

  test "the create_contest expectation admits the wire its own builder produced" do
    built = vault.build_create_contest(WALLET, SLUG, admin_signs: false, **create_params)
    expectation = vault.create_contest_expectation(
      wallet_address: WALLET, contest_slug: SLUG, onchain_params: create_params
    )

    assert_nil verdict(expectation, built[:serialized_tx])
    assert_kind_of Integer, built[:last_valid_block_height]
  end

  test "a create_contest wire whose PRIZE POOL drifted is refused" do
    built = vault.build_create_contest(WALLET, SLUG, admin_signs: false,
                                       **create_params.merge(prize_pool: 999_000_000))
    expectation = vault.create_contest_expectation(
      wallet_address: WALLET, contest_slug: SLUG, onchain_params: create_params
    )

    assert_equal "instruction_data_mismatch", verdict(expectation, built[:serialized_tx]),
                 "the server states the prize pool; a wire that funds a different one is refused"
  end

  test "a create_contest wire whose LOCK TIMESTAMP drifted is refused" do
    built = vault.build_create_contest(WALLET, SLUG, admin_signs: false,
                                       **create_params.merge(lock_timestamp: 1_800_000_000))
    expectation = vault.create_contest_expectation(
      wallet_address: WALLET, contest_slug: SLUG, onchain_params: create_params
    )

    assert_equal "instruction_data_mismatch", verdict(expectation, built[:serialized_tx]),
                 "a slate whose first kickoff moved must be REBUILT, not cosigned at the old lock time"
  end

  test "the cash-out expectation admits its own wire and refuses a drifted amount" do
    destination = Solana::Keypair.generate.address
    amount = 25_000_000

    built = vault.build_user_usdc_transfer_unsigned(
      wallet_address: WALLET, destination_token_account: destination, amount_lamports: amount
    )
    expectation = vault.usdc_transfer_expectation(
      wallet_address: WALLET, destination_token_account: destination, amount_lamports: amount
    )
    assert_nil verdict(expectation, built[:serialized_tx])

    drifted = other_vault.build_user_usdc_transfer_unsigned(
      wallet_address: WALLET, destination_token_account: destination, amount_lamports: amount * 2
    )
    assert_equal "instruction_data_mismatch", verdict(expectation, drifted[:serialized_tx]),
                 "the SERVER resolved the amount; a wire moving twice as much is refused"
  end

  test "a cash-out to a DIFFERENT destination is refused" do
    amount = 25_000_000
    mine   = Solana::Keypair.generate.address
    theirs = Solana::Keypair.generate.address

    expectation = vault.usdc_transfer_expectation(
      wallet_address: WALLET, destination_token_account: mine, amount_lamports: amount
    )
    drifted = other_vault.build_user_usdc_transfer_unsigned(
      wallet_address: WALLET, destination_token_account: theirs, amount_lamports: amount
    )

    assert_equal "instruction_accounts_mismatch", verdict(expectation, drifted[:serialized_tx]),
                 "the destination is resolved on-chain by the server and is not the client's to choose"
  end

  # --- the control -----------------------------------------------------------

  test "CONTROL — the drift tests bite because the two wires really differ" do
    # Every refusal above compares a prepared wire with a drifted one. If the two
    # builders happened to emit identical bytes, each of those tests would be
    # asserting a refusal that any guard would produce for the wrong reason — or
    # worse, would silently stop testing anything the day a builder changed.
    prepared = vault.build_enter_contest(WALLET, SLUG, 0, currency_idx: 0, season_id: 1)
    drifted  = other_vault.build_enter_contest(WALLET, SLUG, 7, currency_idx: 0, season_id: 1)

    refute_equal prepared[:serialized_tx], drifted[:serialized_tx]

    # And the prepared wire IS admitted by its own expectation, so the refusals
    # above are caused by the drift and not by something broken in the setup.
    expectation = vault.cosign_expectation(prepared[:serialized_tx], wallet_address: WALLET)
    assert_nil verdict(expectation, prepared[:serialized_tx])
  end
end
