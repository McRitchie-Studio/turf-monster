require "test_helper"

# Newsletter quest — the contest-card "Join Newsletter, get 25 seeds" mission.
#
# HARDENING ("things you can't do"): the 25-seed bonus may be earned at most
# once. The controller returns a seeds payload ONLY on the FIRST-EVER join; a
# later unsubscribe -> rejoin must never re-pay (the on-chain
# SeedGrant[newsletter] PDA is the hard once-ever guard — this keeps the Rails
# payload from over-claiming seeds on a rejoin). See NewsletterController and
# its private #grant_newsletter_seeds.
class NewsletterControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    # Managed-wallet user, minted explicitly so grant_newsletter_seeds clears its
    # solana_connected? guard. Signup used to provide the wallet; web3-only
    # onboarding (default ON since 2026-08-15) stopped minting one.
    @wallet_user = User.create!(email: "nl-wallet@mcritchie.studio")
    grant_managed_wallet!(@wallet_user)
    assert @wallet_user.solana_connected?, "the seed grant is wallet-gated"
  end

  test "a guest cannot subscribe" do
    post newsletter_subscribe_path, as: :json
    assert_response :unauthorized
  end

  test "the FIRST join returns the 25-seed payload and records the subscription" do
    log_in_as @wallet_user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post newsletter_subscribe_path, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert body["success"]
    assert body["subscribed"]
    assert_equal 25, body["seeds_earned"], "first-ever join pays the quest bonus"
    assert @wallet_user.reload.joined_email_list_at.present?, "the subscription is recorded"
    refute @wallet_user.first_newsletter_join?, "the first-join window is now closed"
    assert_equal 1, fake.grant_calls.length, "exactly one on-chain grant"
    assert_equal :newsletter, fake.grant_calls.first[:kind]
  end

  test "a re-subscribe after unsubscribing pays NO seeds (once-ever)" do
    log_in_as @wallet_user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post newsletter_subscribe_path, as: :json            # first join -> pays
      assert_equal 25, response.parsed_body["seeds_earned"]

      post newsletter_unsubscribe_path, as: :json          # leave
      assert_response :success
      refute response.parsed_body["subscribed"]

      post newsletter_subscribe_path, as: :json            # rejoin -> NO pay
      assert_response :success
      body = response.parsed_body
      assert body["subscribed"], "a rejoin still re-subscribes the user"
      assert_nil body["seeds_earned"], "a rejoin must never re-pay the quest bonus"
    end
    assert_equal 1, fake.grant_calls.length, "the grant fired exactly once across join/leave/rejoin"
  end

  test "subscribing without a wallet succeeds but pays no seeds (the grant is wallet-gated)" do
    no_wallet = users(:jordan) # email present, no web2/web3 wallet (fixtures skip callbacks)
    refute no_wallet.solana_connected?
    log_in_as no_wallet

    post newsletter_subscribe_path, as: :json
    assert_response :success
    body = response.parsed_body
    assert body["subscribed"]
    assert_nil body["seeds_earned"], "no wallet -> grant_newsletter_seeds short-circuits to nil"
    # The subscription IS recorded, so the first-join window CLOSES even though
    # no seeds were paid — a wallet-less first join forfeits the bonus (it is
    # gated by joined_email_list_at, which is stamped regardless of wallet).
    refute no_wallet.reload.first_newsletter_join?
  end

  test "a web3 user with no account email must supply a valid one to subscribe" do
    user = User.create!(web3_solana_address: Solana::Keypair.generate.address)
    user.update_columns(email: nil)
    log_in_as_onchain(user)

    post newsletter_subscribe_path, as: :json # no email param
    assert_response :unprocessable_entity
    assert_not response.parsed_body["success"]
    assert_nil user.reload.joined_email_list_at, "no subscription without a valid email"
  end

  test "a web3 user can capture an email on subscribe and earn the seeds" do
    user = User.create!(web3_solana_address: Solana::Keypair.generate.address)
    user.update_columns(email: nil)
    log_in_as_onchain(user)

    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post newsletter_subscribe_path, params: { email: "captured@example.com" }, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert body["subscribed"]
    assert_equal "captured@example.com", user.reload.email, "the blank account email is filled"
    assert_equal 25, body["seeds_earned"]
  end

  test "an invalid captured email is rejected without recording a subscription" do
    user = User.create!(web3_solana_address: Solana::Keypair.generate.address)
    user.update_columns(email: nil)
    log_in_as_onchain(user)

    post newsletter_subscribe_path, params: { email: "not-an-email" }, as: :json
    assert_response :unprocessable_entity
    assert_nil user.reload.joined_email_list_at
  end

  test "the FIRST join sends the welcome email; a rejoin does not re-send it" do
    log_in_as @wallet_user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      assert_difference "EmailDelivery.count", 1 do
        post newsletter_subscribe_path, as: :json
      end
      assert_equal "NewsletterMailer#welcome", EmailDelivery.order(:created_at).last.email_key

      post newsletter_unsubscribe_path, as: :json
      assert_no_difference "EmailDelivery.count" do
        post newsletter_subscribe_path, as: :json # rejoin → no welcome
      end
    end
  end
end
