require "test_helper"

# Chat quest (v0.23) — the 25-seed bonus fires on a user's FIRST contest-chat
# message only.
#
# HARDENING ("things you can't do"): the controller returns a seeds payload at
# most once, and a wallet-less first message DEFERS the stamp (so the bonus is
# not silently forfeited before there's a wallet to pay). The on-chain
# SeedGrant[chat] PDA is the hard once-ever guard. See MessagesController and its
# private #grant_first_chat_seeds.
class MessagesChatSeedsTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
  end

  # A confirmed (active/complete) entry makes the user a chat participant
  # (Contest#chat_participant?). The managed wallet is minted explicitly so
  # user.solana_address is present for the grant — signup stopped providing one
  # when web3-only onboarding became the default (2026-08-15), and the wallet-less
  # path is a DIFFERENT case this suite tests separately (the deferred stamp).
  def entrant_with_wallet
    user = User.create!(email: "chatter@mcritchie.studio")
    grant_managed_wallet!(user)
    @contest.entries.create!(user: user, status: :active)
    user
  end

  test "the FIRST chat message returns the 25-seed payload and stamps first_chat_message_at" do
    user = entrant_with_wallet
    log_in_as user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post contest_messages_url(@contest), params: { message: { body: "gm" } }, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert body["ok"]
    assert_equal 25, body["seeds_earned"], "the first message pays the chat quest bonus"
    assert user.reload.first_chat_message_at.present?, "the once-ever marker is stamped"
    assert_equal 1, fake.grant_calls.length
    assert_equal :chat, fake.grant_calls.first[:kind]
  end

  test "a SECOND chat message pays no seeds (once-ever)" do
    user = entrant_with_wallet
    log_in_as user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post contest_messages_url(@contest), params: { message: { body: "first" } }, as: :json
      assert_equal 25, response.parsed_body["seeds_earned"]

      post contest_messages_url(@contest), params: { message: { body: "second" } }, as: :json
      assert_response :success
      assert_nil response.parsed_body["seeds_earned"], "the chat bonus only fires once"
    end
    assert_equal 1, fake.grant_calls.length, "exactly one grant across two messages"
  end

  test "a wallet-less entrant's first message defers the stamp (bonus not forfeited)" do
    # jordan is an entrant in contest :one (fixture entry) with NO wallet. The
    # grant is wallet-gated, and the stamp is DEFERRED until there's a wallet to
    # pay — so first_chat_message_at stays nil and the bonus is still claimable
    # once a wallet is linked. (Contrast newsletter, which stamps regardless.)
    jordan = users(:jordan)
    refute jordan.solana_connected?
    log_in_as jordan

    post contest_messages_url(@contest), params: { message: { body: "hi from web2" } }, as: :json
    assert_response :success
    assert_nil response.parsed_body["seeds_earned"]
    assert_nil jordan.reload.first_chat_message_at, "stamp deferred until a wallet exists"
  end

  test "a non-entrant gets no seed payload (the chat-participant gate fires first)" do
    # The seed grant can only be reached AFTER the chat-participant check passes,
    # so an outsider can never trip the bonus path. sam has a wallet but no entry.
    outsider = users(:sam)
    log_in_as_onchain(outsider)

    post contest_messages_url(@contest), params: { message: { body: "sneaking in" } }, as: :json
    assert_response :forbidden
    assert_nil outsider.reload.first_chat_message_at, "no stamp for a rejected post"
  end
end
