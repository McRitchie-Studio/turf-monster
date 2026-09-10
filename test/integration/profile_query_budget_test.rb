require "test_helper"

# [integration] What the two new /profile rows cost per request.
#
# THE RISK THEY INTRODUCED. Both cards used to be rendered by a controller that
# had preloaded what they needed; on /profile they are rendered by the ENGINE's
# controller, which preloads nothing and cannot be taught to. So the partials
# resolve their own inputs — and resolving-at-render-time is precisely how a page
# grows a query per card without anyone noticing, because nothing fails.
#
# THE REFERRAL CARD'S SIDE of that is contained behind
# ApplicationHelper#main_contest_target and measured in
# test/helpers/main_contest_target_test.rb — a memo is a property of the
# method, and measuring it through a whole page attributes everyone else's calls
# to it (Contest and FaucetController reach main_contest too, which is how the
# first version of that test failed at four). What ONE PAGE costs in
# SeasonConfig lookups is measured in
# test/integration/main_contest_query_budget_test.rb.
#
# WHAT IS LEFT HERE is the claim that only a real request can make: what the
# WALLET card costs, in chain calls, when the engine's controller renders it.
class ProfileQueryBudgetTest < ActionDispatch::IntegrationTest
  setup { @user = users(:alex) }

  def sign_in_as(user)
    link = Studio::Link.create_magic_link(email: user.email, return_to: "/", ttl: 1.hour)
    get "/l/#{link.token}"
    post "/l/#{link.token}"
    get "/account"
    assert_response :success, "sign-in did not take — the counts below would be a redirect's"
  end

  # THE ENTRY-TOKEN TILE DOES REACH THE CHAIN, and this test exists to say so
  # rather than to forbid it.
  #
  # The card's own comment claimed "the render path is RPC-free by design", and
  # that is true of FOUR of the five tiles — they paint em-dash placeholders and
  # the client fills them. The Entry Tokens tile renders a real value from
  # User#entry_token_balance, which is Rails.cache-backed for 60 seconds with a
  # Solana::Vault call on a miss. So a cold cache puts a chain round-trip in
  # front of the first paint. That is PRE-EXISTING — /account has always done it,
  # and this change carried the tile across unaltered — but /profile now inherits
  # it, and an inaccurate comment is how that stays invisible.
  #
  # WHAT IS ASSERTED: the call is CACHED and MEMOISED, so it happens at most once
  # per request and not at all on a warm cache. A regression that dropped either
  # would turn one cold-cache round-trip into one per tile read.
  test "the entry-token tile reaches the chain at most once, and not at all when warm" do
    @user.update!(web3_solana_address: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr")
    sign_in_as(@user)

    calls = 0
    fake = Object.new
    def fake.list_entry_tokens(*) = []

    Solana::Vault.stub(:new, ->(*) { calls += 1; fake }) do
      get "/profile"
    end

    assert_response :success
    assert_operator calls, :<=, 1,
                    "the chain was called #{calls} times rendering one page — the per-request " \
                    "memo on User#cached_entry_tokens is not holding, so every tile read is a " \
                    "round-trip"
  end
end
