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
end
