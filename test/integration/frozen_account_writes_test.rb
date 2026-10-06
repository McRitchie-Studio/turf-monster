require "test_helper"

# [integration] OPSEC-048 through the real routes and controllers: a frozen
# account's every kind of write — web and agent API — answers the freeze and
# writes nothing, and its reads (contests, its own entries, the wallet and
# account pages, sign-in and sign-out) still work.
#
# THE CONTROL is the same request for the same account unfrozen: it may still
# fail for its own reasons (no wallet, no vault in the test env), but never
# with the freeze's answer. Without that run, a 403 here could be any 403.
class FrozenAccountWritesTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  setup do
    @user    = users(:jordan) # non-admin, an active entry (:two) in contest :one
    @contest = contests(:one)
    @entry   = entries(:two)
    @entry.update_column(:slug, "jordan-frozen-entry") # fixtures skip Sluggable
    @message = Message.create!(contest: @contest, user: users(:alex), body: "good luck")
  end

  def freeze!
    @user.freeze!(reason: "test", source: "console")
  end

  # Every web write a player can make, as [label, request, rows-that-must-not-change].
  def web_writes
    [
      ["chat post", -> { post contest_messages_url(@contest), params: { message: { body: "hi" } }, as: :json },
       -> { Message.where(user: @user).count }],
      ["chat reaction", -> { post toggle_reaction_contest_message_url(@contest, @message), params: { emoji: Reaction::QUICK.first }, as: :json },
       -> { Reaction.where(user: @user).count }],
      ["username change", -> { post update_username_account_path, params: { value: "frozen_rename" }, as: :json },
       -> { @user.reload.username }],
      ["wallet link", -> { post link_solana_account_path, params: { address: Solana::Keypair.generate.to_base58 }, as: :json },
       -> { @user.reload.web3_solana_address.to_s }],
      ["pick a matchup", -> { post toggle_selection_contest_path(@contest), params: { slate_matchup_id: slate_matchups(:m1).id }, as: :json },
       -> { Entry.where(user: @user).count + Selection.joins(:entry).where(entries: { user_id: @user.id }).count }],
      ["enter a contest", -> { post enter_contest_path(@contest), as: :json },
       -> { Entry.where(user: @user).pluck(:status).sort }],
      ["edit an entry", -> { patch contest_entry_path(@contest, @entry.slug), params: { slate_matchup_ids: [slate_matchups(:m1).id] }, as: :json },
       -> { @entry.selections.reload.pluck(:slate_matchup_id).sort }],
      ["withdraw", -> { post withdraw_wallet_path, params: { amount: 10, destination_info: "paypal @me" }, as: :json },
       -> { TransactionLog.where(user: @user).count }],
      ["profile edit", -> { patch account_path, params: { user: { name: "Frozen Name" } }, as: :json },
       -> { @user.reload.name }]
    ]
  end

  def assert_frozen_answer(label)
    assert_response :forbidden, label
    assert_equal "account_frozen", response.parsed_body["code"], label
    assert_equal FrozenAccount::MESSAGE, response.parsed_body["error"], label
  end

  def frozen_answer?
    response.status == 403 && response.media_type == "application/json" &&
      response.parsed_body.is_a?(Hash) && response.parsed_body["code"] == "account_frozen"
  end

  # ── Web ──────────────────────────────────────────────────────────────────

  test "every web write answers the freeze and writes nothing" do
    log_in_as(@user)
    freeze!

    web_writes.each do |label, request, rows|
      before = rows.call
      request.call
      assert_frozen_answer(label)
      assert_equal before, rows.call, "#{label}: a frozen account's write landed"
    end
  end

  test "control: the same web writes, unfrozen, are never answered with the freeze" do
    log_in_as(@user)

    web_writes.each do |label, request, _rows|
      request.call
      assert_not frozen_answer?, "#{label}: an account in good standing got the freeze's answer"
    end
  end

  test "control: an unfrozen entrant's chat post lands" do
    log_in_as(@user)
    assert_difference -> { Message.where(user: @user).count }, 1 do
      post contest_messages_url(@contest), params: { message: { body: "hi" } }, as: :json
    end
    assert_response :success
  end

  test "a browser form post is sent back with the message, and nothing lands" do
    log_in_as(@user)
    freeze!

    assert_no_difference -> { Entry.where(user: @user).count } do
      post enter_contest_path(@contest), headers: { "Accept" => "text/html", "Referer" => contest_url(@contest) }
    end
    assert_response :see_other
    assert_redirected_to contest_url(@contest)
    assert_equal FrozenAccount::MESSAGE, flash[:alert]
  end

  # ── Agent API ────────────────────────────────────────────────────────────

  test "the agent API refuses a frozen account's entry and edit with 403 account_frozen" do
    key = mint_api_key(@user)
    freeze!

    assert_no_difference -> { Entry.count } do
      api_write(:post, api_v1_contest_entries_path(@contest.slug), key: key,
                body: { matchup_ids: [slate_matchups(:m1).id] }, headers: { "Idempotency-Key" => "frozen-1" })
    end
    assert_response :forbidden
    assert_equal "account_frozen", response.parsed_body.dig("error", "code")
    assert_equal FrozenAccount::MESSAGE, response.parsed_body.dig("error", "message")

    api_write(:patch, "/api/v1/entries/#{@entry.slug}", key: key, body: { matchup_ids: [slate_matchups(:m1).id] })
    assert_response :forbidden
    assert_equal "account_frozen", response.parsed_body.dig("error", "code")
  end

  test "control: the agent API passes an unfrozen account through the freeze gate" do
    key = mint_api_key(@user)
    api_write(:post, api_v1_contest_entries_path("no-such-contest"), key: key,
              body: { matchup_ids: [slate_matchups(:m1).id] }, headers: { "Idempotency-Key" => "control-1" })
    assert_response :not_found, "past the freeze gate, the request reaches the operation"
  end

  # ── Reads stay open ──────────────────────────────────────────────────────

  test "a frozen account still browses, sees its own entries, and signs out and in" do
    log_in_as(@user)
    freeze!

    [contests_path, contest_path(@contest), my_contests_path, account_path, wallet_path].each do |path|
      get path
      assert_response :success, path
    end

    get logout_path
    log_in_as(@user)
    get account_path
    assert_response :success
    assert_select "[data-frozen-banner]", 1
  end

  test "the agent API still answers a frozen account's reads" do
    key = mint_api_key(@user)
    freeze!
    api_get(api_v1_me_path, key: key)
    assert_response :success
  end

  # ── Gift tokens ──────────────────────────────────────────────────────────

  test "a frozen account claims no entry gift, and the gift stays claimable" do
    gift = EntryGift.create!(sender: users(:alex), recipient_email: @user.email, mint_ref: "frozen-#{SecureRandom.hex(4)}")
    freeze!

    result = EntryGifts::Claim.call(gift, @user)

    assert_not result.claimed?
    assert_equal EntryGifts::Claim::FROZEN_REASON, result.reason
    assert_nil gift.reload.claimed_at
  end
end
