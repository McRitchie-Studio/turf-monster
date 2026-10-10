require "test_helper"

# The house account holds no wallet. Its former wallet is a rotated-out key, so
# no wallet signature may reach the house row or a parked admin identity.
class HouseAccountWalletTest < ActiveSupport::TestCase
  ROTATED = Solana::RotatedOutWallet::ADDRESS

  def house_identity = User::PARKED_IDENTITIES.find { |i| i[:email] == User::TURF_HOUSE_EMAIL }

  def seed!
    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }
  end

  test "the house account parks no wallet" do
    assert house_identity[:wallet].blank?, "the house account carries a wallet again"
    assert_equal "admin", house_identity[:role]
  end

  test "no parked identity carries the rotated-out wallet" do
    refute_includes User::PARKED_IDENTITIES.map { |i| i[:wallet] }, ROTATED
    assert_nil User.parked_identity_for(wallet: ROTATED)
  end

  # Every sign-in path runs claim_parked_identity!, which grants the parked role.
  test "an account created from the rotated-out wallet is an ordinary user" do
    user = User.create!(web3_solana_address: ROTATED)

    refute user.admin?
    refute_equal "turf", user.username
    refute user.claim_parked_identity!, "the rotated-out wallet still claims a parked identity"
    refute user.reload.admin?
  end

  test "a fresh seed gives the house account no wallet" do
    seed!
    house = User.turf

    assert_equal "admin", house.role
    assert_equal :none, house.wallet_kind
    assert_nil User.from_solana_wallet(ROTATED)
  end

  test "a re-seed takes the rotated-out wallet off a house row that holds it" do
    house = User.create!(email: User::TURF_HOUSE_EMAIL, name: "Turf Monster", role: "admin",
                         username: "turf", web3_solana_address: ROTATED, seeding_parked_identity: true)
    seed!

    assert_nil house.reload.web3_solana_address
    assert_equal "turf", house.username
    assert_equal "admin", house.role
    assert_nil User.from_solana_wallet(ROTATED)
  end

  # The house row is found by email; a wallet-less identity must not adopt the
  # first row that has no wallet.
  test "the wallet-less house identity adopts no stranger" do
    stranger = User.create!(email: "stranger@example.com", username: "stranger", role: "user")
    seed!

    assert_equal "stranger@example.com", stranger.reload.email
    assert_equal "user", stranger.role
    refute_equal stranger.id, User.turf.id
  end
end
