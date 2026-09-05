require "test_helper"

# /contract is the public, unauthenticated transparency page. Its plain-English
# intro (contract/_section_intro.html.erb) is the one paragraph a non-technical
# reader is expected to finish, and it made three claims the program contradicts:
#
#   1. entry fees move "to a contest account"       — op_rev is per-MINT and
#                                                     vault-wide, not per contest
#   2. "pays winners directly from that account"    — settle pays from prize_pool
#   3. "we can't touch the money in between"        — sweep_operator_revenue can
#
# Ground truth, from every token::transfer site in turf_vault:
#
#   create_contest.rs:163          creator ATA  -> prize_pool
#   enter_contest.rs:170           user ATA     -> op_rev ATA [b"op_rev", mint]
#   cancel_contest.rs:98           prize_pool   -> creator ATA
#   settle_contest.rs:201          prize_pool   -> winner ATA
#   close_contest.rs:91            pool dust    -> op_rev ATA
#   sweep_operator_revenue.rs:102  op_rev       -> treasury ATA (2-of-3 multisig)
#
# enter_contest_with_token.rs moves no tokens at all.
#
# These tests assert the DESTINATIONS and the two accounts staying distinct, not
# the wording. The copy is Mr. McRitchie's to reword; the account topology is not.
class ContractControllerTest < ActionDispatch::IntegrationTest
  test "contract page renders without auth" do
    get contract_path

    assert_response :success
    assert_select "h2", text: "What this contract does"
  end

  test "intro does not claim the operator cannot touch entry fees" do
    get contract_path

    assert_response :success
    # sweep_operator_revenue.rs:102 moves op_rev to the treasury, so no page may
    # promise the money is untouchable between entry and settlement.
    # Separators are written loose on purpose: an apostrophe reaches the body as
    # &#39; through <%= %> and as &rsquo; when typed as an entity. A guard pinned
    # to one spelling is a guard that never bites.
    assert_no_match(/we can.{0,8}t touch the money/i, response.body)
    assert_no_match(/moves from your wallet to a contest account/i, response.body)
  end

  test "intro names the treasury as the only exit from operator revenue" do
    get contract_path

    assert_response :success
    assert_match(/treasury/i, response.body)
  end

  test "intro does not pay winners from the account the entry fee landed in" do
    get contract_path

    assert_response :success
    # settle_contest.rs:201 pays from prize_pool, which create_contest.rs:163
    # funded from the CREATOR's ATA — never from the op_rev account the entry
    # fee was transferred into. A bare assert_match(/prize pool/) is INERT here:
    # the phrase already appears elsewhere on the page and survives the defect.
    assert_no_match(/pays winners directly from that account/i, response.body)
    assert_match(/prize pool/i, response.body)
  end

  test "enter_contest card does not call op-rev a per-contest account" do
    get contract_path

    assert_response :success
    # The ATA is derived from [b"op_rev", mint] alone: one per currency for the
    # whole vault, shared by every contest.
    assert_no_match(/contest.{0,8}s per-currency operator-revenue/i, response.body)
    assert_match(/operator-revenue ATA/i, response.body)
  end
end
