# frozen_string_literal: true

require "test_helper"

# [component] contract-pages-name-the-bot — the public /contract page must name
# each signer after the key it actually describes.
#
# THE BUG. The page called the SERVER BOT "Alex" in three places a guest reads:
# both vault-signer cards in the "Who can call what" matrix, and the
# create_user_account detail. It also told readers the deploy float was "Needed
# in the bot (Alex)". House naming: Alex is the agent orchestrator, Mr. McRitchie
# is the owner, and the server/admin signing key has been named Xan since
# 2026-09-15. None of these sentences described the orchestrator.
#
# WHO EACH SENTENCE DESCRIBES, VERIFIED BEFORE THE COPY CHANGED.
#   - The two signer cards list VaultState.signers, the in-program set
#     (Solana::Config::MULTISIG_SIGNERS): 8K81... Xan, 7ZDJ... Mr. McRitchie's
#     Phantom, CytJ... Mason. So "Xan (bot)".
#   - create_user_account's payer is Solana::Keypair.admin (SOLANA_ADMIN_KEY),
#     enqueued by User's after_commit CreateOnchainUserAccountJob: the server
#     bot. So "server bot (Xan)".
#   - The deploy float is NOT the bot's. Buffer rent is paid by the keypair that
#     runs write-buffer, and upgrades execute through the Squads multisig, where
#     Xan holds no mainnet seat. So the float card names the ROLE, "the deploying
#     wallet", rather than swapping one wrong name for another.
#
# WHY THE NAME MAP IS CHECKED AGAINST CONFIG. A copy test that only compares
# strings stays green after a signer rotation leaves the cards naming retired
# keys. SIGNER_NAMES pins each printed name to a key and requires the set to be
# exactly the configured one, so an update_signers rotation turns this red at
# the moment the copy goes stale.
#
# RENDERED, AND SCOPED. Every case drives the real controller and reads text out
# of a data-test subtree, never the ERB source and never the whole body (the
# layout's footer carries a support address). Each extractor asserts its node
# rendered, so no negative assertion can pass vacuously.
class ContractSignerNamesTest < ActionDispatch::IntegrationTest
  # The name each signer card prints, keyed to the VaultState signer it means.
  SIGNER_NAMES = {
    "Xan"           => "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd",
    "Mr. McRitchie" => "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr",
    "Mason"         => "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"
  }.freeze

  ROUTINE_CARD  = "Xan (bot) · Mr. McRitchie · Mason"
  MULTISIG_CARD = "2 of {Xan (bot) · Mr. McRitchie · Mason}"

  def render_contract
    get contract_path
    assert_response :success
  end

  def text_of(data_test)
    nodes = css_select(%([data-test="#{data_test}"]))
    assert_equal 1, nodes.size, "expected exactly one [data-test=#{data_test}] on /contract, found #{nodes.size}"
    nodes.first.text.squish
  end

  test "the name map is exactly the configured VaultState signer set" do
    assert_equal SIGNER_NAMES.values.sort, Solana::Config::MULTISIG_SIGNERS.sort,
      "VaultState signers changed: re-verify who each /contract signer card names, then update SIGNER_NAMES and the copy"
    assert_equal SIGNER_NAMES.fetch("Mr. McRitchie"), Solana::Config::MULTISIG_COSIGNER,
      "the Phantom cosigner is no longer Mr. McRitchie's key"
    assert_equal SIGNER_NAMES.fetch("Mr. McRitchie"), Solana::Config::INIT_AUTHORITY,
      "the INIT_AUTHORITY card calls this key Mr. McRitchie's Phantom"
  end

  test "Xan is the seeded server-side signer, not a person" do
    team = User::PARKED_IDENTITIES.find { |identity| identity[:wallet] == SIGNER_NAMES.fetch("Xan") }
    assert team, "no parked identity holds Xan's key"
    assert_equal "team@mcritchie.studio", team[:email]

    human = User::PARKED_IDENTITIES.find { |identity| identity[:wallet] == SIGNER_NAMES.fetch("Mr. McRitchie") }
    assert human, "no parked identity holds Mr. McRitchie's Phantom key"
    assert_equal "alex@mcritchie.studio", human[:email]
  end

  test "both vault-signer cards name Xan as the bot" do
    render_contract

    assert_equal ROUTINE_CARD, text_of("signer-matrix-routine")
    assert_equal MULTISIG_CARD, text_of("signer-matrix-multisig")
  end

  test "create_user_account names Xan as the server bot that pays onboarding rent" do
    render_contract

    detail = text_of("contract-instruction-create_user_account")
    assert_includes detail, "Turf Monster's server bot (Xan) does this for every new signup"
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

    page = text_of("contract-page")
    assert_includes page, "Who can call what", "the signer matrix did not render inside the scoped page"
    assert_no_match(/\bAlex\b/, page)
  end

  test "no contract content an admin reads calls anyone Alex" do
    log_in_as(users(:alex))
    render_contract

    page = text_of("contract-page")
    assert_includes page, "Admin view", "the admin sections did not render, so this case would prove nothing"
    assert_no_match(/\bAlex\b/, page)
  end
end
