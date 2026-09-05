require "test_helper"

class HelpControllerTest < ActionDispatch::IntegrationTest
  # The glossary had NO coverage at all, and it carries one of the app's few
  # plain-English claims about who gets money back when a contest is cancelled.
  # That claim class has been wrong three times in one day (contest.rb#cancelled?,
  # the cancelled-badge precedence comment, and this file's sibling in
  # contest_live_state_test.rb), so the corrected wording gets pinned here.
  #
  # What is asserted is the PAYEE, not the sentence: cancel_contest's only token
  # transfer sends the prize-pool PDA balance to the creator's ATA
  # (turf_vault cancel_contest.rs), and entry fees never enter that pool
  # (enter_contest pays the operator-revenue ATA). Reword the copy freely — just
  # do not let it go back to promising an unnamed party a refund.
  test "glossary renders and names the creator as the cancel payee" do
    get help_glossary_path

    assert_response :success
    assert_select "dt", text: "Escrow"
    assert_match(/returned to the contest creator/i, response.body)
    assert_no_match(/payouts to winners or refunded if the contest is cancelled/i, response.body)
  end

  # /help/phantom told users their entry fee was "held in a smart contract
  # escrow (not our bank account)". The parenthetical was the false half: the
  # fee IS operator money. enter_contest.rs:170 is the only transfer an entry
  # makes, and it sends the user's ATA balance to the operator-revenue ATA
  # (seeds [b"op_rev", mint], authority vault_state). The one instruction that
  # can move that account is sweep_operator_revenue.rs:102 → the treasury. No
  # instruction anywhere pays an entrant back.
  #
  # What is asserted is the DESTINATION, not the sentence: the page must name
  # operator revenue, and must not re-describe the fee as escrowed or as money
  # we do not hold. Reword freely inside those bounds.
  test "phantom help names operator revenue as the entry-fee destination" do
    get help_phantom_path

    assert_response :success
    assert_match(/operator revenue/i, response.body)
    assert_no_match(/entry fee is held in a .{0,40}escrow/i, response.body)
    assert_no_match(/not our bank account/i, response.body)
  end

  # The prize pool is the OTHER half of the correction, and the half that keeps
  # the page reassuring rather than alarming. settle_contest.rs:201 pays winners
  # from the prize_pool PDA, which create_contest.rs:163 funded from the
  # creator's ATA — a different account from the one entry fees land in.
  test "phantom help keeps the prize pool separate from the entry fee" do
    get help_phantom_path

    assert_response :success
    assert_match(/prize pool/i, response.body)
  end
end
