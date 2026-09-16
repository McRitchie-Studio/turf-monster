# frozen_string_literal: true

require "test_helper"

# [component] The DEV-ONLY quest walkthrough (/test/quest_walk).
#
# WHAT IT IS. A page that drives a real user up and down the quest ladder so the
# gear sidebar's lead line can be seen in every state it has. Five of the six
# states are otherwise reachable only by doing the quest for real — entering a
# contest, changing a username on chain, sending a chat message — and the sixth
# (a free entry) was not reachable live at all, because development runs
# :null_store and the badge is cache-first.
#
# WHY IT IS TESTED AT ALL, being a dev affordance. It REWRITES A REAL USER'S
# STATE from a browser and can mint a wallet key. Two things therefore have to
# hold, and both are pinned below:
#
#   1. THE GATE. It must be unreachable outside development. There are two
#      layers — config/routes.rb draws the pair under
#      `if Rails.env.development? || Rails.env.test?`, and
#      TestController#require_dev_walkthrough repeats the condition at request
#      time. Only the SECOND is observable from here: a route that was not drawn
#      leaves nothing to assert against, and this process cannot boot a
#      production route set to check. So these tests pin the request-time gate,
#      which is the layer that actually refuses a request, and they pin it for
#      production AND for a staging-shaped env — the case the neighbouring
#      `unless Rails.env.production?` block would let through.
#
#   2. THE LADDER MAP. TestController::QUEST_WALK_RUNGS states each rung as a
#      COMPLETE column set so a move is absolute rather than a ratchet. If it
#      drifts from User#next_quest the page silently lies about which state it
#      just put you in, so every rung is driven through the model.
class QuestWalkTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam)
  end

  def as_env(name)
    Rails.stub :env, ActiveSupport::StringInquirer.new(name) do
      yield
    end
  end

  # ── THE GATE ────────────────────────────────────────────────────────────
  test "[component] the walkthrough is refused in production" do
    log_in_as_onchain(@user)

    as_env("production") { get "/test/quest_walk" }
    assert_response :forbidden,
      "this page rewrites a real user's quest columns — it must not serve in production"

    as_env("production") { post "/test/quest_walk", params: { rung: "invite" } }
    assert_response :forbidden, "the WRITE half needs the gate more than the read half"
  end

  test "[component] the walkthrough is refused on a staging-shaped env" do
    # The reason the pair is NOT drawn under the `unless Rails.env.production?`
    # block its siblings use: that guard admits every other RAILS_ENV, and a
    # staging or review-app dyno is not production. #grant_web3_wallet carries
    # the same warning for the same reason.
    log_in_as_onchain(@user)

    as_env("staging") { get "/test/quest_walk" }
    assert_response :forbidden

    as_env("staging") { post "/test/quest_walk", params: { rung: "invite" } }
    assert_response :forbidden
  end

  test "[component] a refused POST changes nothing" do
    # A gate that renders 403 AFTER doing the work is not a gate. Drive the one
    # column a rung move always writes and prove it did not move.
    log_in_as_onchain(@user)
    @user.update!(contest_entered: false)

    as_env("production") { post "/test/quest_walk", params: { rung: "invite" } }

    assert_response :forbidden
    refute @user.reload.contest_entered?,
      "the refusal must happen BEFORE the columns are written"
  end

  test "[component] the walkthrough serves in the test env" do
    log_in_as_onchain(@user)
    get "/test/quest_walk"

    assert_response :success
    assert_includes response.body, "Quest Walk"
    assert_includes response.body, "Development only",
      "the page must say out loud what it is"
  end

  test "[component] a signed-out visitor is told to sign in rather than shown controls" do
    get "/test/quest_walk"

    assert_response :success
    assert_includes response.body, "Sign in first"
    refute_includes response.body, "Put me here",
      "there is no user to move — offering the buttons would 500 or move nobody"
  end

  # ── THE LADDER MAP ──────────────────────────────────────────────────────
  test "[component] every rung in the map lands the user on that rung" do
    # The map is the page's whole claim: click rung X, be on rung X. Driven
    # through User#next_quest so a change to the ladder reddens HERE rather than
    # leaving the page confidently mislabelled.
    log_in_as_onchain(@user)

    TestController::QUEST_WALK_RUNGS.each_key do |rung|
      post "/test/quest_walk", params: { rung: rung }
      assert_redirected_to quest_walk_path

      assert_equal rung.to_sym, @user.reload.next_quest,
        "clicking '#{rung}' must leave User#next_quest on :#{rung}"
    end
  end

  test "[component] the map covers every rung the ladder has" do
    # Stated against the model so a new rung cannot be added to User#next_quest
    # and silently go undemonstrable.
    assert_equal %i[join username chat newsletter invite],
      TestController::QUEST_WALK_RUNGS.keys.map(&:to_sym),
      "the five rungs of User#next_quest, in ladder order"
  end

  test "[component] a rung move is absolute, not a ratchet" do
    # THIS IS WHAT #set_quest_state COULD NOT DO. That endpoint only writes
    # timestamps forward, which is right for a spec that stages once and is
    # useless to someone walking the ladder both ways. Walk DOWN and prove it.
    log_in_as_onchain(@user)

    post "/test/quest_walk", params: { rung: "invite" }
    assert_equal :invite, @user.reload.next_quest

    post "/test/quest_walk", params: { rung: "join" }
    assert_equal :join, @user.reload.next_quest,
      "the ladder must be walkable downward — a forward-only ratchet strands " \
      "the operator on :invite after one click"
  end

  test "[component] the page reports the state it just moved you to" do
    # data-quest-walk-state is the page's one machine-readable fact, and the
    # only thing a browser driver can wait on: every button POSTs to this same
    # path and redirects back to it, so the URL never changes.
    log_in_as_onchain(@user)

    post "/test/quest_walk", params: { rung: "chat" }
    follow_redirect!

    assert_select '[data-quest-walk-state="chat"]'
  end

  # ── THE FREE-ENTRY RUNG ─────────────────────────────────────────────────
  test "[component] staging a free entry warms the wallet the SESSION reads" do
    # Keyed on entry_token_wallet_address, NOT User#solana_address. The two
    # differ for a combo account and the sidebar reads the former, so warming
    # the account-level key would leave the badge dark and send the reader
    # hunting for a bug in the view.
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      log_in_as_onchain(@user)
      post "/test/quest_walk", params: { rung: "invite", free_entries: 2 }

      tokens = store.read(Solana::Vault.entry_tokens_cache_key(@user.reload.web3_solana_address))
      assert_equal 2, tokens.to_a.count { |t| !t[:consumed] },
        "an onchain session spends from the web3 wallet — that is the key to warm"
    end
  end

  test "[component] the free-entry rung outranks the quest it is stacked on" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      log_in_as_onchain(@user)
      post "/test/quest_walk", params: { rung: "chat" }          # an OPEN quest
      post "/test/quest_walk", params: { free_entries: 2 }       # no rung: stack on it
      follow_redirect!

# TWO NOTES, both earned the hard way.
#
# No MESSAGE argument: assert_select's second positional is a TEXT test,
# not a failure message. Prose there asserts the element's text EQUALS
# the prose, which is always false.
#
# No COUNT either. Every signed-in page in this app renders its own
# template TWICE — studio/modals/blocks/_card_header hits the Rails
# hazard its own comment warns about (a partial's block_given? inherits
# the layout's yield), so the whole page body is emitted a second time
# inside the username modal's "Saved" card. It is inert, being inside a
# template, but it doubles every count taken over a whole response.
# Asserting presence keeps this test about the walkthrough rather than
# about that bug.
assert_select '[data-quest-walk-state="free_entry"]'
      assert_equal :chat, @user.reload.next_quest,
        "staging tokens must not move the ladder underneath the operator"
    end
  end

  test "[component] clearing free entries drops back to the rung underneath" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      log_in_as_onchain(@user)
      post "/test/quest_walk", params: { rung: "chat", free_entries: 2 }
      post "/test/quest_walk", params: { rung: "chat", free_entries: 0 }
      follow_redirect!

      assert_select '[data-quest-walk-state="chat"]'
      tokens = store.read(Solana::Vault.entry_tokens_cache_key(@user.reload.web3_solana_address))
      assert_equal [], tokens,
        "zero must write an EMPTY list, not leave the key cold — a cold key is " \
        "'loading', and the page would report a count it never staged"
    end
  end
end
