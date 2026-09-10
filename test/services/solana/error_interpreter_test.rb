require "test_helper"

class Solana::ErrorInterpreterTest < ActiveSupport::TestCase
  def interp(msg, contest: nil, mode: nil)
    Solana::ErrorInterpreter.interpret(msg, contest: contest, mode: mode)
  end

  test "user rejection returns toast, no blocker" do
    r = interp("User rejected the request")
    assert_equal "Transaction canceled.", r[:message]
    assert_nil r[:blocker]
    assert r[:toast]
  end

  test "no entry tokens maps to web2 no_funding blocker" do
    r = interp("No entry tokens. Buy at /tokens/buy")
    assert_equal "no_funding", r[:blocker][:reason]
    assert_equal "web2", r[:blocker][:mode]
  end

  test "0x1772 maps to web3 insufficient_balance with neededCents from contest" do
    contest = Struct.new(:entry_fee_cents).new(1900)
    r = interp("Transaction simulation failed: custom program error: 0x1772", contest: contest)
    assert_equal "insufficient_balance", r[:blocker][:reason]
    assert_equal "web3",                  r[:blocker][:mode]
    assert_equal 1900,                    r[:blocker][:data][:neededCents]
  end

  test "0x1772 in a web2 session maps to no_funding/web2 (the showFundsNeeded funds wall), not the web3 deposit modal" do
    contest = Struct.new(:entry_fee_cents).new(1900)
    r = interp("custom program error: 0x1772", contest: contest, mode: :web2)
    assert_equal "no_funding", r[:blocker][:reason]
    assert_equal "web2",       r[:blocker][:mode]
    assert_equal 1900,         r[:blocker][:data][:neededCents]
    assert_match(/USDC/i, r[:message])
  end

  test "InsufficientBalance Anchor name also maps to insufficient_balance" do
    r = interp("Error: InsufficientBalance")
    assert_equal "insufficient_balance", r[:blocker][:reason]
  end

  # Funding-preflight safety net (2026-06-13): the #resolve_web2_entry_funding!
  # pre-check raise ("Not enough USDC …") maps to the no_funding/web2 blocker so
  # the board can route the player through selectionBoard#showFundsNeeded — Get
  # USDC (modals/_buy_usdc), or Buy an Entry Token (modals/_buy_entry_token) for
  # the USDC kill-switch audience — instead of attempting a doomed on-chain entry.
  # Not Top Up Wallet: nothing reaches that modal at head, and the two conditions
  # that would give it an entrance are spelled out in the service itself
  # (app/services/solana/error_interpreter.rb, the no-entry-tokens branch).
  test "pre-check 'not enough usdc' in a web2 session maps to no_funding/web2 with neededCents" do
    contest = Struct.new(:entry_fee_cents).new(1900)
    r = interp("Not enough USDC to enter this contest — top up your wallet and try again.",
               contest: contest, mode: :web2)
    assert_equal "no_funding", r[:blocker][:reason]
    assert_equal "web2",       r[:blocker][:mode]
    assert_equal 1900,         r[:blocker][:data][:neededCents]
    assert_match(/USDC/i, r[:message])
  end

  # Backstop: the raw SPL token-program insufficient-funds error (custom program
  # error: 0x1) reaching a web2 session also maps to no_funding/web2 — never leak
  # the cryptic 0x1 sim error to a managed user.
  test "raw SPL 'custom program error: 0x1' in a web2 session maps to no_funding/web2" do
    r = interp("Transaction simulation failed: Error processing Instruction 2: custom program error: 0x1",
               mode: :web2)
    assert_equal "no_funding", r[:blocker][:reason]
    assert_equal "web2",       r[:blocker][:mode]
  end

  # The 0x1 backstop is web2-scoped — a bare 0x1 with no web2 context (web3 /
  # unknown) must NOT be mapped to a web2 blocker (it falls through unmapped).
  test "raw 0x1 outside a web2 session does NOT map to the no_funding/web2 backstop" do
    r = interp("custom program error: 0x1")
    assert_nil r[:blocker], "a bare 0x1 with no web2 context must not produce a web2 blocker"
  end

  test "0x1773 maps to contest_locked" do
    r = interp("custom program error: 0x1773")
    assert_equal "contest_locked", r[:blocker][:reason]
  end

  test "0x1774 maps to contest_full" do
    r = interp("custom program error: 0x1774")
    assert_equal "contest_full", r[:blocker][:reason]
  end

  test "0xbbb AccountDidNotDeserialize: log flag, no blocker" do
    r = interp("custom program error: 0xbbb")
    assert_nil r[:blocker]
    assert r[:log]
  end

  test "0xbbb AccountDidNotDeserialize on season tells admin to create a valid-season contest" do
    r = interp("AnchorError caused by account: season. Error Code: AccountDidNotDeserialize. Error Number: 3003.")
    assert_nil r[:blocker]
    assert r[:log]
    assert_match(/on-chain season is unavailable/i, r[:message])
  end

  test "network errors return toast, no blocker" do
    r = interp("blockhash not found")
    assert_nil r[:blocker]
    assert r[:toast]
  end

  test "0x1789 InvalidCurrencyIndex maps to currency_unavailable blocker" do
    r = interp("custom program error: 0x1789")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_nil r[:blocker][:mode]
  end

  test "CurrencyNotActive Anchor name maps to currency_unavailable blocker" do
    r = interp("Error: CurrencyNotActive")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_match(/no longer accepted/i, r[:message])
  end

  test "0x178b EntryFeeNotSet maps to currency_unavailable blocker" do
    r = interp("custom program error: 0x178b")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_match(/doesn't accept/i, r[:message])
  end

  test "operator-only codes set log:true with no blocker" do
    [
      ["0x1787", /already registered/i],     # 6023 CurrencyAlreadyRegistered
      ["0x1788", /registry is full/i],       # 6024 CurrencyRegistryFull
      ["0x178c", /not locked/i],             # 6028 ContestNotLocked
      ["0x178d", /cannot be cancelled/i],    # 6029 ContestNotCancellable
      ["0x178e", /still has tokens/i],       # 6030 PrizePoolNotEmpty
      ["0x178f", /revenue account is empty/i], # 6031 EmptyRevenueAccount
      ["0x1790", /pinned treasury authority/i], # 6032 TreasuryAuthorityMismatch
      ["0x1791", /at least one entry fee/i]    # 6033 FeeAndPrizeBothZero
    ].each do |code, msg_pattern|
      r = interp("custom program error: #{code}")
      assert_nil r[:blocker], "#{code} should not have a blocker"
      assert r[:log], "#{code} should set log:true"
      assert_match msg_pattern, r[:message], "#{code} message: #{r[:message]}"
    end
  end

  test "username codes 6020-6022 set log:true with a friendly /account message" do
    [
      ["0x1784", /reserved word/i],             # 6020 UsernameReserved
      ["0x1785", /unsupported characters/i],    # 6021 UsernameInvalidChars
      ["0x1786", /too short/i]                  # 6022 UsernameTooShort
    ].each do |code, msg_pattern|
      r = interp("custom program error: #{code}")
      assert_nil r[:blocker], "#{code} should not have a blocker"
      assert r[:log], "#{code} should set log:true (Rails mirror drift signal)"
      assert_match msg_pattern, r[:message], "#{code} message: #{r[:message]}"
      assert_match %r{/account}, r[:message], "#{code} should point the user at /account"
    end
  end

  test "username codes match decimal and Anchor-name forms too" do
    assert_match(/reserved word/i,          interp("AnchorError ... Error Code: UsernameReserved. Error Number: 6020.")[:message])
    assert_match(/unsupported characters/i, interp("Error: UsernameInvalidChars")[:message])
    assert_match(/too short/i,              interp("custom program error 6022")[:message])
  end

  test "unknown errors pass through the message with no blocker" do
    r = interp("Something unrecognized")
    assert_equal "Something unrecognized", r[:message]
    assert_nil r[:blocker]
  end

  test "exception instances are accepted" do
    r = interp(StandardError.new("No entry tokens. Buy at /tokens/buy"))
    assert_equal "no_funding", r[:blocker][:reason]
  end

  # THE RAISE THAT BECAME USER COPY (operator report, QA, 2026-09-07). A
  # self-custody account signed in with Google reached ContestsController's web2
  # funding path, which raises "Managed wallet missing keypair (cannot sign
  # entry)" because there is no custodial keypair. Nothing mapped it, so the
  # unmapped-passthrough branch handed the raise string straight to the modal
  # and the player read an exception message on a red card.
  #
  # #enter now refuses this before it ever tries to sign, so these are backstop
  # assertions — and that is the point of having them: the interpreter's promise
  # is that no raise text reaches a modal, and a promise with no test is a
  # comment.
  test "the missing-keypair raise never reaches the user as itself" do
    r = interp("Managed wallet missing keypair (cannot sign entry)")

    assert_no_match(/keypair/i, r[:message], "the raise wording is not user copy")
    assert_no_match(/managed wallet missing/i, r[:message])
    assert_match(/wallet/i, r[:message], "it still has to tell the user what to do")
  end

  test "the missing-keypair raise routes to the web3 step-up card" do
    r = interp("Managed wallet missing keypair (cannot sign entry)")

    assert_equal "web3_step_up_required", r[:blocker][:reason],
                 "same blocker ContestsController#enter returns, so both routes land on one card"
    assert_equal "web3", r[:blocker][:mode]
    assert r[:log], "reaching this branch at all means a guard was bypassed — say so in the log"
  end

  test "the missing-keypair mapping is not mode-scoped" do
    # The account's problem is that it holds no managed wallet, which is true
    # whichever session is asking. A mode-scoped match would drop the mapping
    # for any caller that threads a different mode and put the raise text back
    # on screen.
    %i[web2 web3 guest].each do |mode|
      r = interp("Managed wallet missing keypair (cannot sign entry)", mode: mode)
      assert_equal "web3_step_up_required", r[:blocker][:reason], "mode #{mode} lost the mapping"
    end
  end
end
