require "test_helper"

# Web3-only onboarding, end to end across the auth boundary
# (AppFlags.web3_only_onboarding? — NFL 2026 operator call).
#
# The story this tier owns:
#   1. an email signup no longer mints a custodial wallet, and lands with the
#      wallet-setup modal armed instead of the entry-token upsell;
#   2. a returning web2 user holding 19+ USDC is NOT interrupted;
#   3. the same user under 19 USDC IS;
#   4. the entry endpoint refuses a wallet-less account server-side, so the
#      client-side gate is a convenience and not the security boundary;
#   5. linking a wallet clears the nudge.
class WalletSetupGateTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
    Rails.cache.clear
  end

  teardown do
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
    Rails.cache.clear
  end

  # The layout consumes session[:wallet_setup_prompt] on render and emits this
  # marker, which is what actually opens the modal. Asserting the RENDERED
  # marker (not just the session key) keeps the two halves honest together.
  #
  # Since the post-auth onboarding chain landed (2026-08-12) the wallet prompt is
  # the LAST STEP of that chain rather than its own one-shot key, so the rendered
  # marker is the chain payload. `window.__walletSetupPrompt` survives unchanged —
  # the contest board still reads it to defer its tokens picker — and is emitted
  # whenever the chain ends in the wallet step.
  PROMPT_MARKER = 'id="onboarding-chain-data"'.freeze

  # Isolate the WALLET question: this file is about WalletSetupPolicy, so settle
  # the chain's other steps (a first name, a verified DOB) and let the wallet step
  # be the only thing that can still be outstanding. Without this a returning
  # user with a blank first_name gets asked for it, which is correct behaviour and
  # pure noise here.
  def settle_non_wallet_steps(user)
    user.update_columns(first_name: "Jordan", age_attested_at: 30.years.ago)
    user
  end

  test "a new email signup gets no custodial wallet and lands with setup armed" do
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: magic_token(email: "fresh-web3@example.com"))
    end
    user = User.find_by(email: "fresh-web3@example.com")

    assert_nil user.web2_solana_address, "web3-only onboarding must not mint a custodial wallet"
    assert_equal :none, user.wallet_kind
    assert_equal user.id, session[Studio.session_key], "the account is still signed in"
    assert_equal true, session[:wallet_setup], "the policy verdict should be recorded on the session"

    # Follow the redirect: the landing render arms the modal.
    follow_redirect!
    assert_response :success
    assert_includes response.body, PROMPT_MARKER
    assert_includes response.body, "window.__walletSetupPrompt = true"
  end

  test "the new-signup landing skips the entry-token upsell copy" do
    # A wallet-less account cannot buy an entry token, so promising one is a
    # dead end. The setup modal owns this moment instead.
    post magic_link_consume_path(token: magic_token(email: "no-upsell@example.com"))
    assert_nil flash[:auth_toast], "no 'grab an entry token' toast for a wallet-less signup"
    assert_nil flash[:magic_link_welcome], "the welcome modal must not stack under the setup modal"
  end

  test "a returning web2 user holding an entry's worth of USDC is not interrupted" do
    user = settle_non_wallet_steps(users(:jordan))
    user.update_columns(web2_solana_address: "FundedManaged1", web3_solana_address: nil)
    with_usdc(25.0) do
      post magic_link_consume_path(token: magic_token(email: user.email))
    end

    assert_equal user.id, session[Studio.session_key]
    assert_equal false, session[:wallet_setup], "19+ USDC means useable as-is"
    assert_nil session[:onboarding_prompt], "nothing outstanding means no chain"
    # They keep their normal welcome-back toast. Read BEFORE follow_redirect! —
    # the followed render consumes the flash.
    assert_equal "Welcome back", flash[:auth_toast][:title]

    follow_redirect!
    assert_not_includes response.body, PROMPT_MARKER
  end

  test "a returning web2 user under the threshold is prompted" do
    user = settle_non_wallet_steps(users(:jordan))
    user.update_columns(web2_solana_address: "EmptyManaged1", web3_solana_address: nil)
    with_usdc(3.0) do
      post magic_link_consume_path(token: magic_token(email: user.email))
    end

    assert_equal true, session[:wallet_setup]
    assert_nil flash[:auth_toast], "the setup modal is the message; no toast over it"

    follow_redirect!
    assert_includes response.body, PROMPT_MARKER
  end

  test "a phantom-linked user is never prompted" do
    user = settle_non_wallet_steps(users(:jordan))
    user.update_columns(web3_solana_address: "PhantomLinked1")
    post magic_link_consume_path(token: magic_token(email: user.email))

    assert_equal false, session[:wallet_setup]
    follow_redirect!
    assert_not_includes response.body, PROMPT_MARKER
  end

  test "the prompt is one-shot — a second page view does not re-open the modal" do
    post magic_link_consume_path(token: magic_token(email: "one-shot@example.com"))
    follow_redirect!
    assert_includes response.body, PROMPT_MARKER

    get contests_path
    assert_response :success
    assert_not_includes response.body, PROMPT_MARKER,
                        "the prompt must not re-fire on every subsequent render"
  end

  test "the session payload keeps advertising walletSetupRequired after the one-shot" do
    # The one-shot only controls the AUTO-OPEN. The state that the entry gate
    # reads has to survive it, or a user who dismisses the modal can hold-to-
    # confirm straight into a server refusal.
    post magic_link_consume_path(token: magic_token(email: "state-persists@example.com"))
    follow_redirect!
    get contests_path
    assert_response :success
    assert_includes response.body, '"walletSetupRequired":true'
  end

  test "entering a contest without a wallet is refused server-side" do
    contest = contests(:one)
    user = users(:jordan)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as user

    post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal true, body["wallet_setup"], "the client needs the flag to reopen the setup modal"
    assert_match(/wallet/i, body["error"])
  end

  test "linking a wallet clears the nudge" do
    user = users(:jordan)
    user.update_columns(web2_solana_address: "EmptyManaged2", web3_solana_address: nil)
    with_usdc(0.0) do
      post magic_link_consume_path(token: magic_token(email: user.email))
    end
    assert_equal true, session[:wallet_setup]

    # log_in_as_onchain links a real Phantom address through the verify path.
    log_in_as_onchain(users(:jordan))
    assert_nil session[:wallet_setup], "a wallet login satisfies the nudge"
  end

  test "with the flag OFF a new signup still mints a wallet and sees no prompt" do
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
    post magic_link_consume_path(token: magic_token(email: "flag-off@example.com"))
    user = User.find_by(email: "flag-off@example.com")

    assert user.web2_solana_address.present?, "flag off keeps the pre-existing behaviour"
    assert_equal :managed, user.wallet_kind
    assert_equal false, session[:wallet_setup]

    follow_redirect!
    # The CHAIN still runs with the feature off — a new signup is still welcomed
    # and still asked for a first name. What must be absent is the WALLET step,
    # because web2 is a supported path when the flag is off.
    assert_includes response.body, PROMPT_MARKER
    assert_not_includes response.body, "window.__walletSetupPrompt = true",
                        "no wallet step, so the board must not defer its tokens picker"
    assert_includes response.body, '"walletSetupRequired":false'
    steps = JSON.parse(response.body[/id="onboarding-chain-data">\s*(\{.*?\})\s*<\/script>/m, 1])["steps"]
    assert_not_includes steps, "wallet"
  end

  test "with the flag OFF an empty managed wallet can still reach the web2 rails" do
    # The regression this guards: gating only the wallet MINTING would leave the
    # policy live with the feature off, so an existing web2 user under 19 USDC
    # would be nudged to Phantom and — worse — blocked by the entry gate from
    # the web2 funding rails that exist to fix exactly that balance.
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
    user = settle_non_wallet_steps(users(:jordan))
    user.update_columns(web2_solana_address: "EmptyManagedFlagOff", web3_solana_address: nil)
    with_usdc(0.0) do
      post magic_link_consume_path(token: magic_token(email: user.email))
    end

    assert_equal false, session[:wallet_setup]
    assert_equal "Welcome back", flash[:auth_toast][:title], "web2 login is untouched with the feature off"

    follow_redirect!
    assert_not_includes response.body, PROMPT_MARKER
    assert_includes response.body, '"walletSetupRequired":false',
                    "the entry gate must not block a web2 user while web2 is supported"
  end

  private

  # Pin the managed wallet's USDC balance for the duration of the request.
  #
  # This stubs the VAULT, not the cache: the test env runs :null_store, so a
  # cache write is silently discarded and every read misses — meaning the RPC
  # path is the only one these requests can take. Stubbing here therefore
  # exercises the real code path instead of a fixture that cannot load.
  def with_usdc(dollars)
    vault = Class.new do
      define_method(:fetch_wallet_balances) { |*| { sol: 0.0, usdc: dollars, usdt: 0.0 } }
      # Signup/entry paths can reach for these on the same stubbed instance.
      def ensure_user_account(*); true; end
      def list_entry_tokens(*); []; end
    end.new
    Solana::Vault.stub :new, vault do
      yield
    end
  end
end
