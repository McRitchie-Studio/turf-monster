require "test_helper"

# The post-auth onboarding chain, end to end across the auth boundary.
#
# What this tier owns:
#   1. a brand-new magic-link signup is armed with first name → age → wallet,
#      IN THAT ORDER, and the layout renders the driver payload;
#   2. the prompt is one-shot (it must not re-open on every later page);
#   3. moving the age PROMPT earlier did NOT move the age GATE — dismissing the
#      chain still cannot buy an unverified entry. That is the compliance
#      property of this change and the reason the entry check stays.
class OnboardingChainTest < ActionDispatch::IntegrationTest
  setup do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
    ENV["ENABLE_AGE_GATE"] = "true"
    Rails.cache.clear
  end

  teardown do
    ENV.delete("ENABLE_WEB3_ONLY_ONBOARDING")
    ENV.delete("ENABLE_AGE_GATE")
    Rails.cache.clear
  end

  CHAIN_MARKER = 'id="onboarding-chain-data"'.freeze

  # The steps the layout handed the driver on this render.
  def rendered_steps
    json = response.body[/id="onboarding-chain-data">\s*(\{.*?\})\s*<\/script>/m, 1]
    json ? JSON.parse(json)["steps"] : nil
  end

  test "a brand-new signup is armed with the full chain in order" do
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: magic_token(email: "chain-new@example.com"))
    end
    user = User.find_by(email: "chain-new@example.com")
    assert_equal user.id, session[Studio.session_key], "still signed in"

    follow_redirects!
    assert_response :success
    assert_includes response.body, CHAIN_MARKER
    assert_equal %w[first_name age wallet], rendered_steps,
                 "the operator's order: first name -> age -> wallet"
  end

  # The welcome step's retirement, at the layer that carries it to the browser.
  # The step must be absent from the payload, and the payload must have stopped
  # carrying the username the retired card was the only reader of.
  test "the chain payload carries steps only, and never the welcome step" do
    post magic_link_consume_path(token: magic_token(email: "chain-nowelcome@example.com"))
    follow_redirects!
    assert_not_includes rendered_steps, "welcome"
    assert_equal "first_name", rendered_steps.first,
                 "the chain greets with the first-name ask now"
    payload = JSON.parse(response.body[/id="onboarding-chain-data">\s*(\{.*?\})\s*<\/script>/m, 1])
    assert_equal %w[steps], payload.keys,
                 "username rode along for the retired welcome card and has no reader left"
  end

  test "the new-signup landing does not also fire the old welcome modal or a toast" do
    # The chain greets the user itself; a flash welcome would be a second
    # greeting stacked on the first.
    post magic_link_consume_path(token: magic_token(email: "chain-solo@example.com"))
    assert_nil flash[:magic_link_welcome]
    assert_nil flash[:auth_toast]
  end

  test "the chain prompt is one-shot" do
    post magic_link_consume_path(token: magic_token(email: "chain-once@example.com"))
    follow_redirects!
    assert_includes response.body, CHAIN_MARKER

    get contests_path
    assert_response :success
    assert_not_includes response.body, CHAIN_MARKER,
                        "the chain must not re-open on every later render"
  end

  test "a returning user with everything settled sees no chain" do
    user = users(:jordan)
    user.update_columns(first_name: "Alex", age_attested_at: Time.current,
                        web3_solana_address: "PhantomSettled#{user.id}")
    post magic_link_consume_path(token: magic_token(email: user.email))
    # Read the flash BEFORE following the redirect — the followed render CONSUMES
    # it, so asserting afterwards reads nil and looks like a missing toast.
    assert_equal "Welcome back", flash[:auth_toast][:title], "a settled login keeps its quiet toast"
    follow_redirects!
    assert_not_includes response.body, CHAIN_MARKER
  end

  test "a returning user who still owes a step is armed with just that step" do
    user = users(:jordan)
    user.update_columns(first_name: nil, name: nil, age_attested_at: Time.current,
                        web3_solana_address: "PhantomReturning#{user.id}")
    post magic_link_consume_path(token: magic_token(email: user.email))
    follow_redirects!
    assert_equal %w[first_name], rendered_steps,
                 "the chain is what you still owe, nothing else"
  end

  # --- The retired welcome flash --------------------------------------------

  test "no signup path sets the retired magic_link_welcome flash" do
    # It had ONE writer (MagicLinksController#sign_up_new's generic-signin
    # branch) and the chain made that branch unreachable: an account created in
    # this request always owes the first-name ask, so the branch above it always
    # won — and still does, now that the ask is the chain's opening card.
    # Dead-but-documented-as-live is the state this retirement removes — assert
    # the absence on BOTH signup shapes so a future edit cannot quietly
    # resurrect a second greeting.
    post magic_link_consume_path(token: magic_token(email: "no-flash-generic@example.com"))
    assert_nil flash[:magic_link_welcome], "generic /signin signup"

    reset!
    post magic_link_consume_path(token: magic_token(email: "no-flash-contest@example.com",
                                                    return_to: "/contests/the-cup"))
    assert_nil flash[:magic_link_welcome], "contest return_to signup"
  end

  test "the retired welcome modal partial is gone, not merely unreferenced" do
    # A partial left on disk reads as a live alternative to the next person.
    assert_not Rails.root.join("app/views/modals/_magic_link_welcome.html.erb").exist?,
               "the retired welcome modal partial should be deleted"
  end

  # --- The compliance property -----------------------------------------------

  test "dismissing the chain does NOT let an unverified user enter a contest" do
    # The whole reason the entry-time gate stays: the chain is dismissible, so if
    # moving the prompt had also moved the gate, closing the modal would buy an
    # unverified entry. Nothing here touches the chain — we just never answer it.
    contest = contests(:one)
    user = users(:jordan)
    user.update_columns(age_attested_at: nil, web3_solana_address: "PhantomAged#{user.id}")
    log_in_as user

    post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal true, body["age_required"],
                 "the entry gate must still demand DOB verification"
    assert_equal "age_required", body.dig("blocker", "reason"),
                 "and it must arrive as the blocker the client dispatches on"
  end

  test "the age endpoint is unchanged and still the enforcement point" do
    user = users(:jordan)
    user.update_columns(age_attested_at: nil)
    log_in_as user

    post age_verify_path, params: { year: 1990, month: 6, day: 15 }, as: :json
    assert_response :success
    assert JSON.parse(response.body)["verified"]
    assert user.reload.age_attested_at.present?
  end

  test "with the age gate OFF the chain skips that step but still asks the rest" do
    ENV.delete("ENABLE_AGE_GATE")
    post magic_link_consume_path(token: magic_token(email: "chain-noage@example.com"))
    follow_redirects!
    assert_equal %w[first_name wallet], rendered_steps
  end

  # "OFF" is an explicit "false" since the flag became a kill-switch — deleting
  # it now means ON.
  test "with web3-only onboarding OFF the wallet step drops out of the chain" do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "false"
    post magic_link_consume_path(token: magic_token(email: "chain-web2@example.com"))
    follow_redirects!
    assert_equal %w[first_name age], rendered_steps,
                 "a managed-wallet signup is still asked, minus the wallet step"
  end

  # --- The wallet-auth boundary ---------------------------------------------
  #
  # A Phantom signup is a REGISTRATION, and it used to be the one auth-success
  # path that armed nothing: the account walked no chain, so the first card it
  # ever saw was whatever the contest entry gate raised (a birthday prompt, then
  # a top-up) — and it was never asked its first name at all, because the signup
  # seeded `name: "anon"` and User#set_name_parts copied that into first_name.
  # Both halves are pinned here.

  # Mint a fresh keypair, sign the SIWS message, and POST the verify that CREATES
  # the account. Returns the base58 pubkey (the new user's web3 address).
  def wallet_signup!
    key = Ed25519::SigningKey.generate
    pubkey_b58 = Solana::Keypair.encode_base58(key.verify_key.to_bytes)

    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]

    message = "www.example.com wants you to sign in with your Solana account:\n#{pubkey_b58}\n\nNonce: #{nonce}"
    post "/auth/solana/verify",
         params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)),
                   pubkey: pubkey_b58 },
         as: :json
    assert_response :success, "wallet signup failed: #{response.body}"
    pubkey_b58
  end

  # #verify answers JSON and the CLIENT does the navigating, so the render that
  # carries the chain payload is one explicit GET away.
  def follow_wallet_redirect!
    get JSON.parse(response.body)["redirect"]
    follow_redirects!
  end

  test "a brand-new WALLET signup is armed with the chain, first name first" do
    assert_difference "User.count", 1 do
      wallet_signup!
    end
    follow_wallet_redirect!
    assert_response :success
    assert_includes response.body, CHAIN_MARKER
    assert_equal %w[first_name age], rendered_steps,
                 "first name -> age; the wallet step is already satisfied by the wallet they signed with"
  end

  test "a wallet signup stamps no placeholder name, so the first-name card can fire" do
    pubkey = wallet_signup!
    user = User.find_by(web3_solana_address: pubkey)

    assert_nil user.name, %q(the old "anon" placeholder is what made this unreachable)
    assert_nil user.first_name
    assert OnboardingFlow.steps_for(user, age_gate_enabled: true).include?(:first_name),
           "a fresh wallet account must still owe its first name"
    assert_equal user.username, user.display_name,
                 "display falls through to the generated username, so nothing needs the placeholder"
  end

  test "a returning wallet login owes nothing once it has answered" do
    pubkey = wallet_signup!
    user = User.find_by(web3_solana_address: pubkey)
    user.update_columns(first_name: "Alex", age_attested_at: Time.current)

    reset!
    log_in_as_onchain(user)
    follow_wallet_redirect!
    assert_not_includes response.body, CHAIN_MARKER,
                        "a settled wallet account must not be re-asked on every login"
  end
end
