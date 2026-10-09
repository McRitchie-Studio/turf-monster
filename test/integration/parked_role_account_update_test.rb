require "test_helper"

# [integration] A parked role is never reached through the account update path:
# an address typed into /account is unverified, and nothing short of proof of
# the mailbox verifies it.
class ParkedRoleAccountUpdateTest < ActionDispatch::IntegrationTest
  HOUSE   = User::TURF_HOUSE_EMAIL
  VARIANT = "Team@turfmonster.media".freeze
  # The role every account starts with.
  UNGRANTED = User.column_defaults.fetch("role")

  def seeded_house
    User.create!(email: HOUSE, name: "Turf Monster", username: "turf", role: "admin")
  end

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

  test "a case variant of a seeded parked email is refused and never elevates" do
    house = seeded_house
    user, key = sign_in_wallet_account

    patch account_path, params: { user: { email: VARIANT } }
    sign_in_again(user, key)

    user.reload
    assert_equal UNGRANTED, user.role
    assert_nil user.email, "a case variant of a held address was saved"
    assert_equal %w[admin turf], [ house.reload.role, house.username ]
  end

  test "an unheld parked email saves unverified and never elevates" do
    user, key = sign_in_wallet_account

    patch account_path, params: { user: { email: VARIANT } }
    assert_redirected_to account_path
    sign_in_again(user, key)

    user.reload
    assert_equal HOUSE, user.email, "the first email saves normalised"
    assert_nil user.email_verified_at
    assert_equal UNGRANTED, user.role
    refute_equal "turf", user.username
  end

  test "linking a Google account does not verify a different address" do
    user, key = sign_in_wallet_account
    patch account_path, params: { user: { email: HOUSE } }
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{SecureRandom.hex(4)}",
      info: { email: "someone-else@example.com", name: "Someone Else" }
    )

    get "/auth/google_oauth2/callback"
    sign_in_again(user, key)

    user.reload
    assert_equal "google_oauth2", user.provider, "the link itself still lands"
    assert_nil user.email_verified_at
    assert_equal UNGRANTED, user.role
  end

  test "linking the Google account of the same address verifies it" do
    user, = sign_in_wallet_account
    patch account_path, params: { user: { email: "mine@example.com" } }
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{SecureRandom.hex(4)}",
      info: { email: "Mine@Example.com", name: "Mine" }
    )

    get "/auth/google_oauth2/callback"

    assert user.reload.email_verified_at.present?
  end

  test "a seeded parked row signs in by magic link and keeps its role" do
    house = seeded_house
    assert_nil house.email_verified_at

    post magic_link_consume_path(token: Studio::Link.create_magic_link(email: HOUSE).token)

    house.reload
    assert_equal house.id, session[:turf_user_id]
    assert house.email_verified_at.present?
    assert_equal %w[admin turf], [ house.role, house.username ]
  end

  test "a parked email that signs up by magic link claims its role" do
    post magic_link_consume_path(token: Studio::Link.create_magic_link(email: HOUSE).token)

    user = User.find_by!(email: HOUSE)
    assert_equal user.id, session[:turf_user_id]
    assert user.email_verified_at.present?
    assert_equal %w[admin turf], [ user.role, user.username ]
  end

  test "a parked email that signs up with Google claims its role" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{SecureRandom.hex(4)}",
      info: { email: HOUSE, name: "Turf Monster" }
    )

    get "/auth/google_oauth2/callback"

    user = User.find_by!(email: HOUSE)
    assert_equal %w[admin turf], [ user.role, user.username ]
  end
end
