require "test_helper"

# A parked role (User::PARKED_IDENTITIES) is granted on proof: a wallet match,
# or a verified email equal to the parked address. Email is unique without
# regard to case for new writes.
class ParkedRoleVerifiedEmailTest < ActiveSupport::TestCase
  HOUSE   = User::TURF_HOUSE_EMAIL
  VARIANT = "Team@turfmonster.media".freeze
  # The role every account starts with.
  UNGRANTED = User.column_defaults.fetch("role")
  WALLET  = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze

  def wallet_account
    User.create!(web3_solana_address: WALLET)
  end

  # A row stored before email was normalised on write.
  def store_email(user, email, verified: false)
    user.update_columns(email: email, email_verified_at: (Time.current if verified))
    user.reload
  end

  test "the premise: the parked house identity carries an elevated role" do
    assert_equal "admin", User.parked_identity_for(email: HOUSE).fetch(:role)
    assert_equal HOUSE.downcase, VARIANT.downcase
    refute_equal HOUSE, VARIANT
  end

  test "an unverified case-variant parked email grants no role" do
    user = store_email(wallet_account, VARIANT)

    user.claim_parked_identity!

    assert_equal UNGRANTED, user.reload.role
    refute_equal "turf", user.username
  end

  test "an unverified exact parked email grants no role" do
    user = store_email(wallet_account, HOUSE)

    user.claim_parked_identity!

    assert_equal UNGRANTED, user.reload.role
  end

  test "a new account on an unverified parked email is refused" do
    user = User.new(email: HOUSE)

    refute user.save
    assert_equal UNGRANTED, user.role
    refute_equal "turf", user.username
  end

  test "a verified case-variant parked email grants no role" do
    user = store_email(wallet_account, VARIANT, verified: true)

    user.claim_parked_identity!

    assert_equal UNGRANTED, user.reload.role
  end

  test "a verified parked email claims its role, name and username" do
    user = store_email(wallet_account, HOUSE, verified: true)

    assert user.claim_parked_identity!

    user.reload
    assert_equal %w[admin turf], [user.role, user.username]
    assert_equal "Turf Monster", user.name
  end

  test "a new account created with a verified parked email claims its role" do
    user = User.create!(email: HOUSE, email_verified_at: Time.current)

    assert_equal %w[admin turf], [user.role, user.username]
  end

  test "a wallet match claims its role with no email at all" do
    identity = User.parked_identity_for(email: "team@mcritchie.studio")

    user = User.create!(web3_solana_address: identity.fetch(:wallet))

    assert_equal "admin", user.role
    assert_equal identity.fetch(:username), user.username
  end

  test "email is stripped and downcased on write" do
    user = User.create!(email: "  Mixed.Case@Example.COM ")

    assert_equal "mixed.case@example.com", user.reload.email
  end

  test "a second account cannot be created with a case variant of an existing email" do
    User.create!(email: "taken@example.com")
    store_email(wallet_account, "Stored@Example.com")

    [ "Taken@Example.com", "stored@example.com", "STORED@EXAMPLE.COM" ].each do |email|
      dup = User.new(email: email)

      refute dup.valid?, "#{email} was accepted"
      assert_includes dup.errors[:email], "has already been taken"
    end
  end

  test "an account cannot be updated to a case variant of an existing email" do
    store_email(User.create!(email: "holder@example.com"), "Holder@Example.com")
    other = wallet_account

    refute other.update(email: "holder@example.com")
    assert_includes other.errors[:email], "has already been taken"
    assert_nil other.reload.email
  end

  test "a row that already collides by case still saves an unrelated change" do
    first  = User.create!(email: "pair@example.com")
    second = store_email(wallet_account, "Pair@example.com")

    assert second.update(name: "Second"), second.errors.full_messages.to_sentence
    assert first.update(name: "First"), first.errors.full_messages.to_sentence
    assert_equal "Pair@example.com", second.reload.email
  end

  test "changing the address clears the verified stamp" do
    user = User.create!(email: "before@example.com", email_verified_at: Time.current)

    user.update!(email: "after@example.com")

    assert_nil user.reload.email_verified_at
  end

  test "a case-only rewrite of the address keeps the verified stamp" do
    user = store_email(wallet_account, "Kept@Example.com", verified: true)

    user.update!(email: "Kept@Example.com")

    assert_equal "kept@example.com", user.reload.email
    assert user.email_verified_at.present?
  end

  test "an address and its verified stamp written together both hold" do
    user = wallet_account

    user.update!(email: "both@example.com", email_verified_at: Time.current)

    assert user.reload.email_verified_at.present?
  end

  # The lock-out check. The seed writes roles directly and stamps no
  # verification, so a seeded row must keep its role through a claim.
  test "seeded parked rows keep their roles before and after a claim" do
    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }
    roster = User::PARKED_IDENTITIES.to_h { |identity| [ identity[:email], identity[:role] ] }

    assert_equal roster, User.where(email: roster.keys).pluck(:email, :role).to_h
    assert_equal [ nil ], User.where(email: roster.keys).distinct.pluck(:email_verified_at),
                 "the seed stamps no verification"

    User.where(email: roster.keys).find_each(&:claim_parked_identity!)
    assert_equal roster, User.where(email: roster.keys).pluck(:email, :role).to_h

    house = User.turf
    house.update!(email_verified_at: Time.current)
    house.claim_parked_identity!
    assert_equal %w[admin turf], [ house.reload.role, house.username ]
  end
end
