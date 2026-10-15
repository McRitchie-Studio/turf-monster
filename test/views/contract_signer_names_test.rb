# frozen_string_literal: true

require "test_helper"

# [component] the public /contract page's signer matrix.
#
# HISTORY. contract-pages-name-the-bot fixed the page calling the server bot
# "Alex" (the agent orchestrator, who holds no key here). It then pinned the
# cards to three names, "Xan (bot) · Mr. McRitchie · Mason", and to "1-of-3" /
# "2-of-3". The 2026-10-14 mainnet rotation retired Xan's 8K81… and Mason's
# CytJ…, and turf-vault v0.26 made every threshold per-action data, so all of
# that copy was wrong at once (mainnet-rotation-follow-ups-sweep).
#
# WHAT IS PINNED NOW. The matrix is derived (ContractHelper): one card per
# signature count from Solana::Governance, the signer count from
# Solana::Config::MULTISIG_SIGNERS, and a holders sentence from the signer
# roster. These tests read the rendered page and check it against those
# sources, plus the facts read on chain on 2026-10-14 (sweep_operator_revenue
# needs 3; pause needs 2; five signers), so neither a stale literal nor a
# broken derivation passes.
#
# RENDERED, AND SCOPED. Every case drives the real controller and reads text
# out of a data-test subtree, never the ERB source and never the whole body
# (the layout's footer carries a support address). Each extractor asserts its
# node rendered, so no negative assertion can pass vacuously.
class ContractSignerNamesTest < ActionDispatch::IntegrationTest
  RETIRED_NAMES = /\b(Xan|Mason)\b/
  MR_MCRITCHIE_PHANTOM = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"

  def render_contract
    get contract_path
    assert_response :success
  end

  def nodes(data_test)
    css_select(%([data-test="#{data_test}"]))
  end

  def text_of(data_test)
    found = nodes(data_test)
    assert_equal 1, found.size, "expected exactly one [data-test=#{data_test}] on /contract, found #{found.size}"
    found.first.text.squish
  end

  def tier_actions(threshold)
    card = nodes("signer-matrix-tier-#{threshold}")
    assert_equal 1, card.size, "expected one #{threshold}-signature card on /contract"
    card.first.css('[data-test="signer-matrix-action"]').map { |li| li.text.strip }
  end

  test "each vault card lists exactly the matrix actions that need its number of signatures" do
    render_contract

    expected = ContractHelper::VAULT_MATRIX_ACTIONS.group_by { |a| Solana::Governance.required_signatures(a) }
    assert_equal [1, 2, 3], expected.keys.sort, "fixture: v0.26 defaults span one, two and three signatures"
    expected.each do |threshold, actions|
      assert_equal actions.sort, tier_actions(threshold).sort
      assert_includes text_of("signer-matrix-tier-#{threshold}"),
                      "#{threshold} of #{Solana::Config::MULTISIG_SIGNERS.size} vault signers"
    end
  end

  test "the cards agree with the thresholds read on chain on 2026-10-14" do
    render_contract

    assert_includes tier_actions(3), "sweep_operator_revenue"
    assert_includes tier_actions(3), "settle_contest"
    assert_includes tier_actions(3), "update_signers"
    assert_includes tier_actions(2), "pause"
    assert_includes tier_actions(1), "create_contest"
    assert_includes text_of("signer-matrix-tier-3"), "3 of 5 vault signers"
  end

  test "the holders sentence counts the configured signers by roster holder" do
    render_contract

    sentence = text_of("signer-matrix-members")
    assert_includes sentence, "There are 5 vault signers: 3 held by Mr. McRitchie and 2 by the app's agents."
    assert_includes sentence, "needs 3 of them"
  end

  test "the signer matrix names no retired key holder and no one-of-three or two-of-three" do
    render_contract

    page = text_of("contract-page")
    assert_includes page, "Who can call what", "the signer matrix did not render inside the scoped page"
    assert_no_match RETIRED_NAMES, page
    assert_no_match(/\b[12]-of-3\b/, page)
  end

  test "create_contest's auth pill is derived from the governance threshold" do
    render_contract

    assert_includes text_of("contract-instruction-create_contest"), "1-of-5 + creator"
  end

  test "the Phantom cosigner and INIT_AUTHORITY are still Mr. McRitchie's key" do
    assert_equal MR_MCRITCHIE_PHANTOM, Solana::Config::MULTISIG_COSIGNER
    assert_equal MR_MCRITCHIE_PHANTOM, Solana::Config::INIT_AUTHORITY,
                 "the INIT_AUTHORITY card calls this key Mr. McRitchie's Phantom"
  end

  # Kept from contract-pages-name-the-bot: the seeds still park the team@
  # identity on the retired server key 8K81… and the operator on his Phantom.
  # A seed fact, not a /contract one; it moves when the seeds do.
  test "the parked seed identities hold the retired server key and the operator's Phantom" do
    team = User::PARKED_IDENTITIES.find { |identity| identity[:wallet] == "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" }
    assert team, "no parked identity holds the retired server key"
    assert_equal "team@mcritchie.studio", team[:email]

    human = User::PARKED_IDENTITIES.find { |identity| identity[:wallet] == MR_MCRITCHIE_PHANTOM }
    assert human, "no parked identity holds Mr. McRitchie's Phantom key"
    assert_equal "alex@mcritchie.studio", human[:email]
  end

  test "create_user_account names the server bot that pays onboarding rent" do
    render_contract

    detail = text_of("contract-instruction-create_user_account")
    assert_includes detail, "Turf Monster's server bot does this for every new signup"
    assert_no_match(/\bAlex\b/, detail)
  end

  test "the deploy float names the deploying wallet, not the server bot" do
    render_contract

    holder = text_of("contract-float-holder")
    assert_includes holder, "Needed in the deploying wallet before write-buffer."
    assert_no_match(/\b(Alex|Xan|bot)\b/, holder)
  end

  test "no contract content a guest reads calls anyone Alex" do
    render_contract

    assert_no_match(/\bAlex\b/, text_of("contract-page"))
  end

  test "the admin playbook groups vault actions by signature count, and calls no one Alex or a retired name" do
    log_in_as(users(:alex))
    render_contract

    page = text_of("contract-page")
    assert_includes page, "Admin view", "the admin sections did not render, so this case would prove nothing"
    %w[1-of-5 2-of-5 3-of-5].each { |label| assert_includes page, "#{label} vault signers" }
    assert_no_match(/\bAlex\b/, page)
    assert_no_match RETIRED_NAMES, page
  end
end
