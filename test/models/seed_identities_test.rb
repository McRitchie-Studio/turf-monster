require "test_helper"

# The seeded identities every session signs in as.
#
# THE STANDARD ACROSS APPS (Mr. McRitchie, 2026-08-13): each app seeds the two
# SHARED identities — alex@mcritchie.studio as an admin and mack@mcritchie.studio
# as an ordinary member — plus ONE admin on its own domain. The shared pair is
# what makes an example mean the same thing in every app; the app-specific admin
# is how a session is "the operator of THIS app" without borrowing Studio's
# identity.
class SeedIdentitiesTest < ActiveSupport::TestCase
  def identity(email) = User::PARKED_IDENTITIES.find { |i| i[:email] == email }

  test "the shared admin is seeded here" do
    assert_equal "admin", identity("alex@mcritchie.studio")&.dig(:role)
  end

  # WITHOUT A MEMBER nothing in this app can be looked at as an ordinary user:
  # admin-only pages, member-facing copy, and anything branching on role each
  # have exactly one answer available locally.
  test "the shared member is seeded, and is not an admin" do
    member = identity("mack@mcritchie.studio")

    refute_nil member, "mack is the shared non-admin across the apps"
    refute_equal "admin", member[:role]
  end

  test "this app seeds an admin on its own domain" do
    own = User::PARKED_IDENTITIES.find { |i| i[:email].to_s.end_with?("@turfmonster.media") }

    refute_nil own, "every app seeds an admin on its own domain, not only Studio's"
    assert_equal "admin", own[:role]
  end

  # ONE ACCOUNT, NOT TWO. Until 2026-09-04 the own-domain admin above was a
  # separate `alex@turfmonster.media` / `alexturf` row sitting alongside the
  # house account on turf@mcritchie.studio. The house account moved onto the
  # real Google user at team@turfmonster.media, which satisfies the same
  # property, so the extra row was retired rather than left as a second
  # operator login nobody signs in as.
  test "the house account is the own-domain admin" do
    own = User::PARKED_IDENTITIES.select { |i| i[:email].to_s.end_with?("@turfmonster.media") }

    assert_equal [User::TURF_HOUSE_EMAIL], own.map { |i| i[:email] }
    assert_equal "turf", own.first[:username]
  end

  test "the retired alexturf identity is gone" do
    assert_nil User::PARKED_IDENTITIES.find { |i| i[:username] == "alexturf" }
    assert_nil identity("alex@turfmonster.media"),
      "alex@turfmonster.media is the support/marketing FROM address, not a seeded user"
  end

  # The operator swapped these on 2026-09-04. Asserted literally: a swap that
  # goes the wrong way is still a valid roster, so nothing derived can catch it.
  test "the human holds alex and the shared team account holds mcritchie" do
    assert_equal "alex", identity("alex@mcritchie.studio")&.dig(:username)
    assert_equal "mcritchie", identity("team@mcritchie.studio")&.dig(:username)
  end

  # THE GREETING BUG. The layered banner greets by the first name token, so
  # "Mr. McRitchie" rendered "Welcome Mr.!" in every sign-in email and on
  # /admin/emails. A title is not a first name.
  test "seeded names greet as a person, not a title" do
    User::PARKED_IDENTITIES.each do |i|
      first = i[:name].to_s.split.first
      refute_includes %w[Mr. Mrs. Ms. Dr. Mr Mrs Ms Dr], first,
        "#{i[:email]} is named #{i[:name].inspect}, so the banner greets \"Welcome #{first}!\""
    end
  end

  # THE NIL-LOOKUP TRAP, tested on the GUARD rather than on the roster.
  #
  # `db/seeds/users.rb` adopts an existing row by wallet, and
  # `find_by(web3_solana_address: nil)` matches the FIRST user with no wallet
  # rather than nobody — so an identity carrying no wallet ADOPTS a stranger:
  # their email, username and role are overwritten and
  # `encrypted_web2_solana_private_key` is nulled while their USDC stays
  # on-chain.
  #
  # This used to be pinned by asserting that alex@turfmonster.media was in the
  # roster without a wallet. That identity was retired on 2026-09-04 and EVERY
  # parked identity now carries a wallet — so the roster no longer demonstrates
  # the case at all, and a test that leans on it can only be deleted or made to
  # assert its own absence. The guard still has to hold for the next identity
  # added without one, so drive it with a synthetic identity instead: the roster
  # is no longer the thing under test.
  test "a wallet-less identity adopts nobody" do
    stranger = User.create!(email: "stranger@example.com", username: "stranger", role: "user",
                            web2_solana_address: "So11111111111111111111111111111111111111112",
                            encrypted_web2_solana_private_key: "managed-key")
    before = stranger.slice("email", "username", "role")

    found = silence_warnings do
      load Rails.root.join("db/seeds/users.rb")
      find_seed_user({ email: "nobody@example.com", name: "Nobody", username: nil, role: "user", wallet: nil })
    end

    refute found.persisted?, "a wallet-less identity adopted an existing row"
    assert_equal before, stranger.reload.slice("email", "username", "role")
    assert_equal "managed-key", stranger.encrypted_web2_solana_private_key
  end

  # The same trap on the OTHER nil-able key. A parked identity with no username
  # would otherwise match the first user who has none.
  test "a username-less identity adopts nobody" do
    User.create!(email: "nameless@example.com", role: "user").update_column(:username, nil)

    found = silence_warnings do
      load Rails.root.join("db/seeds/users.rb")
      find_seed_user({ email: "other@example.com", name: "Other", username: nil, role: "user", wallet: nil })
    end

    refute found.persisted?, "a username-less identity adopted an existing row"
  end

  # THE SWAP, against a database that already holds the OLD assignment — which is
  # the only database where it can fail. `alex` and `mcritchie` traded owners on
  # 2026-09-04, and seeding row-at-a-time asks alex@mcritchie.studio for a name
  # the team@ row still holds; the unique index refuses it. A fresh DB creates
  # every row in order and never reaches the collision, so this has to build the
  # pre-swap state by hand.
  test "the seed swaps two usernames on a database that already holds the old pair" do
    alex = users(:alex) # the fixture already sits on alex@mcritchie.studio
    team = User.create!(email: "team@mcritchie.studio", name: "Team McRitchie", role: "admin")
    # Order matters: `ensure_username` mints team@'s PARKED name on create, which
    # is now "mcritchie" — so free it before handing it to alex, or this setup
    # trips the unique index before the seed ever runs.
    team.update_column(:username, "alex")
    alex.update_column(:username, "mcritchie")

    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    seed_core_users!

    assert_equal "alex", alex.reload.username
    assert_equal "mcritchie", team.reload.username
    assert_equal alex.id, User.find_by(username: "alex").id, "the swap moved the name to a different account"
  end

  # A username held by a row no parked identity owns is REPORTED, never taken.
  # Renaming a real account out from under a person to satisfy a seed is worse
  # than the seed not getting the name it wanted — and letting `save!` raise
  # instead takes the WHOLE seed down with an opaque RecordInvalid on a database
  # that is otherwise fine.
  #
  # The identity has to be matchable by EMAIL for this to be the case under test.
  # `find_seed_user` falls back to a username lookup, so an identity with no
  # matching row at all legitimately ADOPTS the row holding its parked username —
  # that is the idempotency this seed is built on, not the trap.
  test "the seed keeps a username a stranger holds instead of failing the run" do
    mason = User.create!(email: "mason@mcritchie.studio", name: "Mason McRitchie", role: "user")
    mason.update_column(:username, "mason_existing")
    stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "user")
    stranger.update_column(:username, "mason")

    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }

    assert_equal "mason", stranger.reload.username, "the seed renamed an account it does not own"
    assert_equal "mason_existing", mason.reload.username
    assert_equal "Stranger", stranger.name, "the seed overwrote the stranger's identity"
  end

  test "every seeded identity is unique by email and username" do
    emails = User::PARKED_IDENTITIES.map { |i| i[:email] }
    usernames = User::PARKED_IDENTITIES.map { |i| i[:username] }.compact

    assert_equal emails.uniq, emails
    assert_equal usernames.uniq, usernames, "a duplicate username collides on the parked-name index"
  end
end
