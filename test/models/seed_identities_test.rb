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

  # THE NIL-LOOKUP TRAP. db/seeds/users.rb adopts an existing row by wallet, and
  # find_by(web3_solana_address: nil) matches the FIRST user with no wallet
  # rather than nobody — so an identity without a wallet would adopt a
  # stranger's row and overwrite their email, name, username and role. The seed
  # guards each lookup on presence; this pins the shape that makes the guard
  # necessary, so removing it fails here rather than in someone's account.
  test "an identity without a wallet exists, which is what the seed must tolerate" do
    walletless = User::PARKED_IDENTITIES.reject { |i| i[:wallet].present? }

    refute_empty walletless,
      "if every identity gains a wallet, keep the presence guards anyway — the next one may not"
    assert_includes walletless.map { |i| i[:email] }, "alex@turfmonster.media"
  end

  test "the seed guards its wallet and username lookups on presence" do
    seed = Rails.root.join("db/seeds/users.rb").read

    refute_match(/User\.find_by\(web3_solana_address: data\[:wallet\]\)\s*\|\|/, seed,
      "an unguarded wallet lookup adopts the first wallet-less user for any identity without one")
  end

  test "every seeded identity is unique by email and username" do
    emails = User::PARKED_IDENTITIES.map { |i| i[:email] }
    usernames = User::PARKED_IDENTITIES.map { |i| i[:username] }.compact

    assert_equal emails.uniq, emails
    assert_equal usernames.uniq, usernames, "a duplicate username collides on the parked-name index"
  end
end
