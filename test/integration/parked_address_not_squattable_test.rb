require "test_helper"

# [integration] A parked address (User::PARKED_IDENTITIES) cannot be held
# unproven: every door that writes an email refuses it, and a mailbox proof never
# elevates a row someone else can still reach.
class ParkedAddressNotSquattableIntegrationTest < ActionDispatch::IntegrationTest
  HOUSE = User::TURF_HOUSE_EMAIL
  # The role every account starts with.
  UNGRANTED = User.column_defaults.fetch("role")

  # The fixture row sits on a parked address; move it so the roster starts unheld.
  setup { users(:alex).update_columns(email: "fixture-alex@example.com") }

  # A wallet-only account, signed in over HTTP with a real signature.
  def sign_in_wallet_account
    user = User.create!(web3_solana_address: Solana::Keypair.generate.to_base58)
    key = log_in_as_onchain(user)
    [ user.reload, key ]
  end

  def sign_in_again(user, key)
    get logout_path
    get "/auth/solana/nonce"
    nonce = JSON.parse(response.body)["nonce"]
    address = user.web3_solana_address
    message = "www.example.com wants you to sign in with your Solana account:\n#{address}\n\nNonce: #{nonce}"
    post "/auth/solana/verify",
         params: { message: message, signature: Solana::Keypair.encode_base58(key.sign(message)), pubkey: address },
         as: :json
    assert_response :success, response.body
    assert_equal user.id, session[:turf_user_id]
  end

  # The owner's click, in a browser of their own.
  def owner_clicks_magic_link(email = HOUSE)
    open_session.tap do |owner|
      owner.post owner.magic_link_consume_path(token: Studio::Link.create_magic_link(email: email).token)
    end
  end

  # A row as an earlier release could have stored it.
  def plant_parked_address(user, email = HOUSE)
    user.update_columns(email: email, email_verified_at: nil)
  end

  def assert_not_admin_here
    get "/admin/users"
    assert_response :redirect, "the session reached an admin page"
  end

  def assert_unheld(email = HOUSE)
    assert_empty User.where("LOWER(BTRIM(email)) = ?", email).pluck(:id), "the parked address was written unverified"
  end

  # --- every door that writes an email -----------------------------------------

  test "POST /signup refuses a parked address" do
    assert_no_difference "User.count" do
      post signup_path, params: { user: { email: HOUSE } }
    end

    assert_response :unprocessable_entity
    assert_nil session[:turf_user_id]
    assert_unheld
  end

  test "a first email on PATCH /account refuses a parked address" do
    user, = sign_in_wallet_account

    patch account_path, params: { user: { email: "Team@TurfMonster.media" } }

    assert_response :unprocessable_entity
    assert_nil user.reload.email
    assert_unheld
  end

  test "a confirmed email change refuses a parked address" do
    user = User.create!(email: "mine@example.com", email_verified_at: Time.current)
    token = Rails.application.message_verifier(AccountsController::EMAIL_CHANGE_TOKEN_KEY).generate(
      { user_id: user.id, new_email: HOUSE, current_email: user.email, requested_at: Time.current.to_i },
      expires_in: AccountsController::EMAIL_CHANGE_TOKEN_TTL
    )

    post apply_email_change_path(token: token)

    assert_equal "mine@example.com", user.reload.email
    assert user.email_verified_at.present?
    refute_match(/parked|reserved|admin/i, response.body)
    assert_unheld
  end

  test "PATCH /profile refuses a parked address" do
    user, = sign_in_wallet_account

    patch "/profile", params: { profile: { email: HOUSE } }

    assert_redirected_to edit_profile_path
    assert_equal "Email has already been taken", flash[:alert]
    assert_nil user.reload.email
    assert_unheld
  end

  test "POST /profile/newsletter refuses a parked address" do
    user, = sign_in_wallet_account

    post "/profile/newsletter", params: { profile: { email: HOUSE } }

    assert_nil user.reload.email
    assert_nil user.joined_email_list_at
    assert_unheld
  end

  test "POST /account/newsletter/subscribe refuses a parked address" do
    user, = sign_in_wallet_account

    post newsletter_subscribe_path, params: { email: HOUSE }, as: :json

    assert_response :unprocessable_entity
    assert_equal "Email has already been taken", response.parsed_body["error"]
    assert_nil user.reload.email
    assert_nil user.joined_email_list_at
    assert_unheld
  end

  # --- the residual, end to end -------------------------------------------------

  test "squat, the owner's magic link, then the squatter's session and wallet: not admin" do
    squatter, key = sign_in_wallet_account
    patch account_path, params: { user: { email: HOUSE } }

    owner = owner_clicks_magic_link

    assert_not_admin_here
    sign_in_again(squatter, key)
    assert_not_admin_here
    assert_equal UNGRANTED, squatter.reload.role
    house = User.find_by!(email: HOUSE)
    refute_equal squatter.id, house.id
    assert_equal house.id, owner.session[:turf_user_id]
    assert_equal %w[admin turf], [ house.role, house.username ]
  end

  # --- a row that already holds a parked address unverified ---------------------

  test "a magic link does not adopt a parked holder that keeps a wallet" do
    squatter, key = sign_in_wallet_account
    plant_parked_address(squatter)

    2.times do
      owner = owner_clicks_magic_link
      assert_nil owner.session[:turf_user_id]
      assert_redirected_to_signin(owner)
    end

    assert_not_admin_here
    sign_in_again(squatter, key)
    assert_not_admin_here
    squatter.reload
    assert_equal UNGRANTED, squatter.role
    assert_nil squatter.email_verified_at
    assert_equal 1, User.where(email: HOUSE).count
  end

  test "a magic link adopts a parked holder with no other credential and ends its sessions" do
    post signup_path, params: { user: { email: "squat@example.com" } }
    squatter = User.find_by!(email: "squat@example.com")
    assert_equal squatter.id, session[:turf_user_id]
    plant_parked_address(squatter)

    owner = owner_clicks_magic_link

    assert_equal squatter.id, owner.session[:turf_user_id]
    assert_equal %w[admin turf], [ squatter.reload.role, squatter.username ]
    assert_not_admin_here
    get account_path
    assert_nil session[:turf_user_id], "the earlier session outlived the adoption"
  end

  test "a verification link does not stamp a parked holder that keeps a wallet" do
    squatter, key = sign_in_wallet_account
    plant_parked_address(squatter)
    token = Rails.application.message_verifier(EmailVerificationsController::VERIFY_TOKEN_KEY).generate(
      { user_id: squatter.id, email: HOUSE, return_to: nil }, expires_in: 1.hour
    )

    open_session.get email_verifications_verify_path(token: token)

    sign_in_again(squatter, key)
    assert_not_admin_here
    squatter.reload
    assert_nil squatter.email_verified_at
    assert_equal UNGRANTED, squatter.role
  end

  # --- the owner is not locked out ----------------------------------------------

  test "the owner of each parked address with no row signs in by magic link and gets the role" do
    User::PARKED_IDENTITIES.each do |identity|
      owner = owner_clicks_magic_link(identity[:email])

      row = User.find_by!(email: identity[:email])
      assert_equal row.id, owner.session[:turf_user_id]
      assert row.email_verified_at.present?
      assert_equal [ identity[:role], identity[:username] ], [ row.role, row.username ]
    end
  end

  test "every seeded parked identity signs in by magic link and keeps its role" do
    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }

    User::PARKED_IDENTITIES.each do |identity|
      row = User.find_by!(email: identity[:email])
      assert_nil row.email_verified_at, "the seed stamps no verification"

      owner = owner_clicks_magic_link(identity[:email])

      assert_equal row.id, owner.session[:turf_user_id], "#{identity[:username]} was locked out"
      row.reload
      assert row.email_verified_at.present?
      assert_equal [ identity[:role], identity[:username] ], [ row.role, row.username ]
    end
  end

  # --- an ordinary player is unaffected -----------------------------------------

  test "an ordinary sign-up, first email and email change are unaffected" do
    post signup_path, params: { user: { email: "player@example.com" } }
    player = User.find_by!(email: "player@example.com")
    assert_equal player.id, session[:turf_user_id]

    wallet, = sign_in_wallet_account
    patch account_path, params: { user: { email: "First@Example.com" } }
    assert_redirected_to account_path
    assert_equal "first@example.com", wallet.reload.email

    token = Rails.application.message_verifier(AccountsController::EMAIL_CHANGE_TOKEN_KEY).generate(
      { user_id: wallet.id, new_email: "second@example.com", current_email: wallet.email, requested_at: Time.current.to_i },
      expires_in: AccountsController::EMAIL_CHANGE_TOKEN_TTL
    )
    post apply_email_change_path(token: token)
    assert_equal "second@example.com", wallet.reload.email

    owner = owner_clicks_magic_link("second@example.com")
    assert_equal wallet.id, owner.session[:turf_user_id]
    assert wallet.reload.email_verified_at.present?
  end

  private

  def assert_redirected_to_signin(owner)
    assert_equal 302, owner.response.status
    assert_match %r{/signin}, owner.response.location
    refute_match(/parked|reserved|admin/i, owner.flash[:alert].to_s)
  end
end
