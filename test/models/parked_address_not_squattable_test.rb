require "test_helper"

# [unit] A parked address (User::PARKED_IDENTITIES) is written only with its
# proof, and a mailbox proof never lands on a row someone else can still reach.
class ParkedAddressNotSquattableTest < ActiveSupport::TestCase
  HOUSE = User::TURF_HOUSE_EMAIL
  # The role every account starts with.
  UNGRANTED = User.column_defaults.fetch("role")
  TAKEN = "Email has already been taken".freeze

  # The fixture row sits on a parked address; move it so the roster starts unheld.
  setup { users(:alex).update_columns(email: "fixture-alex@example.com") }

  def wallet_account
    User.create!(web3_solana_address: Solana::Keypair.generate.to_base58)
  end

  # A row as an earlier release could have stored it.
  def legacy_holder(email = HOUSE, **attrs)
    user = User.create!(web3_solana_address: Solana::Keypair.generate.to_base58)
    user.update_columns({ email: email, web3_solana_address: nil }.merge(attrs))
    user.reload
  end

  test "an unverified parked address is refused on create with the taken message" do
    user = User.new(email: HOUSE)

    refute user.save
    assert_equal [ TAKEN ], user.errors.full_messages
  end

  test "an unverified parked address is refused on update, in any casing" do
    [ HOUSE, " Team@TurfMonster.media " ].each do |typed|
      user = wallet_account

      refute user.update(email: typed), "#{typed.inspect} was saved"
      assert_equal [ TAKEN ], user.errors.full_messages
      assert_nil user.reload.email
    end
  end

  test "a stamp earned for another address does not carry a parked one" do
    user = User.create!(email: "mine@example.com", email_verified_at: Time.current)

    refute user.update(email: HOUSE)
    refute user.update(email: HOUSE, email_verified_at: nil)
    assert_equal "mine@example.com", user.reload.email
  end

  test "a held parked address reads the same as an unheld one" do
    held = User.new(email: users(:jordan).email).tap(&:valid?).errors.full_messages

    assert_equal [ TAKEN ], held
  end

  test "a parked address saves with a stamp set in the same save" do
    born = User.create!(email: HOUSE, email_verified_at: Time.current)
    assert_equal %w[admin turf], [ born.role, born.username ]

    mason = wallet_account
    mason.update!(email: "mason@mcritchie.studio", email_verified_at: Time.current)
    assert_equal "mason@mcritchie.studio", mason.reload.email
  end

  test "a wallet proof still fills its parked address" do
    alex = User::PARKED_IDENTITIES.find { |identity| identity[:username] == "alex" }
    user = User.create!(web3_solana_address: alex[:wallet])

    assert_equal [ alex[:email], "admin" ], [ user.email, user.role ]
    assert_nil user.email_verified_at
  end

  test "the seed writes every parked identity, unverified" do
    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }

    User::PARKED_IDENTITIES.each do |identity|
      row = User.find_by!(username: identity[:username])
      assert_equal [ identity[:email], identity[:role] ], [ row.email, row.role ]
      assert_nil row.email_verified_at
    end
  end

  test "the seed flag is not a request parameter" do
    permitted = ActionController::Parameters.new(user: { email: HOUSE, seeding_parked_identity: "1" })
                                            .require(:user).permit(*Studio.registration_params, :name)

    refute User.new(permitted).save
  end

  test "an ordinary address is unaffected" do
    user = User.create!(email: "player@example.com")
    assert_nil user.email_verified_at

    wallet = wallet_account
    wallet.update!(email: "first@example.com")
    wallet.update!(email: "second@example.com", email_verified_at: nil)
    assert_equal "second@example.com", wallet.reload.email
  end

  test "a row already holding a parked address unverified still saves its other fields" do
    holder = legacy_holder(HOUSE, web3_solana_address: Solana::Keypair.generate.to_base58)

    holder.update!(name: "Renamed")

    assert_equal [ "Renamed", HOUSE ], [ holder.reload.name, holder.email ]
  end

  # --- the mailbox proof on a row that already exists --------------------------

  test "a mailbox proof stamps an ordinary row and leaves its session" do
    user = User.create!(email: "player@example.com")
    token = user.session_token

    assert user.accept_mailbox_proof!
    assert user.reload.email_verified_at.present?
    assert_equal token, user.session_token
  end

  test "a mailbox proof stamps a wallet-proven parked row and leaves its session" do
    team = User::PARKED_IDENTITIES.find { |identity| identity[:username] == "mcritchie" }
    row = User.create!(web3_solana_address: team[:wallet])
    token = row.session_token

    assert row.accept_mailbox_proof!
    assert row.reload.email_verified_at.present?
    assert_equal token, row.session_token
  end

  test "a mailbox proof on an unproven parked holder with no other credential ends its sessions" do
    holder = legacy_holder
    token = holder.session_token

    assert holder.accept_mailbox_proof!
    assert holder.reload.email_verified_at.present?
    refute_equal token, holder.session_token
  end

  test "a mailbox proof is refused while an unproven parked holder keeps another credential" do
    with_wallet = legacy_holder(HOUSE, web3_solana_address: Solana::Keypair.generate.to_base58)
    with_google = legacy_holder("mason@mcritchie.studio", provider: "google_oauth2", uid: "g-1")
    with_key = legacy_holder("mack@mcritchie.studio")
    ApiKey.mint!(user: with_key, name: "agent", geo_country: "US", geo_state: "CO", age_result: "passed")

    [ with_wallet, with_google, with_key ].each do |holder|
      token = holder.session_token

      refute holder.accept_mailbox_proof!, "#{holder.email} was adopted"
      assert_nil holder.reload.email_verified_at
      assert_equal token, holder.session_token
      holder.claim_parked_identity!
      assert_equal UNGRANTED, holder.reload.role
    end
  end
end
