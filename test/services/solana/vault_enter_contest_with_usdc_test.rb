require "test_helper"

# Solana::Vault#enter_contest_with_usdc — the SERVER-SIGNED managed-wallet
# (web2) USDC contest entry that backs the unified token -> USDC funding
# priority (USDT is intentionally never offered to web2). The server holds the
# managed user's keypair, so it can sign the EXISTING on-chain enter_contest
# (USDC) instruction on their behalf — NO turf-vault program change.
#
# These tests assert the wrapper's three load-bearing contracts:
#   1. it pins currency_idx to USDC (0) — a USDT leak is structurally impossible
#   2. signer consistency — wallet, ATA, and the keypair we sign with all come
#      from web2_solana_address (NEVER solana_address, which prefers web3)
#   3. it bootstraps UserAccount + USDC ATA BEFORE the irreversible enter
#
# The real #enter_contest / #ensure_* are recorded (not invoked) so this is a
# pure delegation/guard unit test with no RPC — mirroring the lightweight
# fake-client style of the other vault/solana service tests.
class Solana::VaultEnterContestWithUsdcTest < ActiveSupport::TestCase
  setup do
    @user = users(:jordan)
    # A GRANDFATHERED managed wallet — fresh, consistent web2 address +
    # encrypted key. Minted with web3-only onboarding switched OFF because that
    # flag gates MINTING AT SIGNUP and has defaulted ON since 2026-08-15; a bare
    # generate_managed_wallet! now returns early and every test below fails on a
    # wallet-less user. The subject here is the server-signed entry path that the
    # managed wallets ALREADY out there still use, so the account has to have one.
    with_web3_only_off { @user.generate_managed_wallet! }
    assert @user.reload.web2_solana_address.present?,
           "setup precondition: the managed wallet must exist for any of this to mean anything"
    @contest = Struct.new(:slug, :season_id).new("unified-funding-contest", 1)
  end

  # Deliberately NOT under `private` — Minitest collects tests from public
  # instance methods, and a visibility change here would silently stop every
  # `test` block after it from running.
  def with_web3_only_off
    original = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING") : ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = original
  end

  # A Vault whose enter_contest / ensure_* are replaced with recorders, so the
  # wrapper's delegation can be asserted without touching the network.
  def vault_with_recorder
    vault = Solana::Vault.new(client: Object.new)
    calls = []
    vault.define_singleton_method(:ensure_user_account) do |addr, username: nil|
      calls << { m: :ensure_user_account, addr: addr, username: username }
      { created: false }
    end
    vault.define_singleton_method(:ensure_ata) do |addr, mint:|
      calls << { m: :ensure_ata, addr: addr, mint: mint }
      { ata: "ata-#{addr[0, 4]}", created: false }
    end
    vault.define_singleton_method(:enter_contest) do |addr, slug, num, currency_idx: 0, user_keypair:, season_id: nil|
      calls << {
        m: :enter_contest, addr: addr, slug: slug, num: num,
        currency_idx: currency_idx, keypair_addr: user_keypair&.address, season_id: season_id
      }
      { signature: "unit-sig", entry_pda: "unit-epda" }
    end
    [vault, calls]
  end

  test "delegates to enter_contest with USDC pinned, web2-derived signer, and passes the result through" do
    vault, calls = vault_with_recorder

    result = vault.enter_contest_with_usdc(user: @user, contest: @contest, entry_num: 7)

    # Return shape is the enter_contest passthrough — so the controller's
    # durable-capture write is identical to the token path.
    assert_equal({ signature: "unit-sig", entry_pda: "unit-epda" }, result)

    # Accounts are bootstrapped BEFORE the irreversible enter (ordering matters).
    assert_equal %i[ensure_user_account ensure_ata enter_contest], calls.map { |c| c[:m] }

    enter = calls.find { |c| c[:m] == :enter_contest }
    assert_equal @user.web2_solana_address, enter[:addr], "signer/ATA owner must be the web2 address"
    assert_equal "unified-funding-contest", enter[:slug]
    assert_equal 7, enter[:num]
    assert_equal 0, enter[:currency_idx], "web2 entry must be hard-pinned to USDC (0)"
    assert_equal 1, enter[:season_id]
    # The keypair we sign with OWNS the web2 address (no signer/ATA desync).
    assert_equal @user.web2_solana_address, enter[:keypair_addr]
  end

  test "ensures the UserAccount with the user's username and the USDC ATA" do
    vault, calls = vault_with_recorder

    vault.enter_contest_with_usdc(user: @user, contest: @contest, entry_num: 0)

    ensure_acct = calls.find { |c| c[:m] == :ensure_user_account }
    assert_equal @user.web2_solana_address, ensure_acct[:addr]
    assert_equal @user.username, ensure_acct[:username]

    ensure_ata = calls.find { |c| c[:m] == :ensure_ata }
    assert_equal @user.web2_solana_address, ensure_ata[:addr]
    assert_equal Solana::Config::USDC_MINT, ensure_ata[:mint]
  end

  test "raises when the user has no managed (web2) wallet" do
    vault = Solana::Vault.new(client: Object.new)
    no_web2 = Struct.new(:web2_solana_address).new(nil)

    err = assert_raises(ArgumentError) do
      vault.enter_contest_with_usdc(user: no_web2, contest: @contest, entry_num: 0)
    end
    assert_match(/managed \(web2\) wallet/, err.message)
  end

  test "raises when the managed wallet has no decryptable keypair" do
    vault = Solana::Vault.new(client: Object.new)
    keyless = Struct.new(:web2_solana_address, :solana_keypair)
                    .new(Solana::Keypair.generate.address, nil)

    err = assert_raises(RuntimeError) do
      vault.enter_contest_with_usdc(user: keyless, contest: @contest, entry_num: 0)
    end
    assert_match(/missing keypair/, err.message)
  end

  test "raises the desync guard when the keypair does not own web2_solana_address" do
    vault = Solana::Vault.new(client: Object.new)
    # Real web2 address, but a keypair for a DIFFERENT wallet — the on-chain
    # `user` signer would not match the ATA/user_pda derived from the address.
    @user.define_singleton_method(:solana_keypair) { Solana::Keypair.generate }

    err = assert_raises(RuntimeError) do
      vault.enter_contest_with_usdc(user: @user, contest: @contest, entry_num: 0)
    end
    assert_match(/desync/, err.message)
  end
end
