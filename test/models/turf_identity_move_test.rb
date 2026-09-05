require "test_helper"
require Rails.root.join("db/migrate/20260905030000_reconcile_turf_parked_identities.rb").to_s

# WHAT A ROSTER EDIT DOES NOT DO.
#
# `PARKED_IDENTITIES` describes what a fresh database gets. This app has no
# save-time reconciler — `ensure_username` runs on create only — so a database
# with people in it keeps whatever it was seeded with, indefinitely. Two of the
# 2026-09-04 changes therefore need a carrier: the house account's move onto its
# own domain, and the retirement of the `alexturf` admin seat.
#
# The migration is what reaches production (release phase is `bin/rails
# db:migrate`; the `admin:claim_usernames` post-deploy writes usernames only).
# The seed is what a local, test or QA reset runs. Both are exercised here.
class TurfIdentityMoveTest < ActiveSupport::TestCase
  OLD = "turf@mcritchie.studio"
  NEW = "team@turfmonster.media"
  RETIRED = "alex@turfmonster.media"

  setup do
    User.where(email: [OLD, NEW, RETIRED]).delete_all
  end

  # "turf" is a RESERVED prefix in this app (mirrored from the on-chain list), so
  # a test row cannot be called the thing it represents.
  def house_row(email = OLD, username: "gridiron")
    User.create!(name: "Turf Monster", email: email, username: username)
  end

  # A row shaped like one already in production: seeded under the roster in force
  # THEN. `update_column` is the only way to make a row today's roster disagrees
  # with, which is exactly the state these carriers exist to find.
  def retired_admin
    user = User.create!(name: "Alex McRitchie", email: RETIRED, username: "alexturf")
    user.update_column(:role, "admin")
    user
  end

  # Through `seed_core_users!`, the entry point db/seeds.rb and e2e/seed.rb both
  # call — NOT the retirement method directly. Calling the method under test by
  # name proves the method works and says nothing about whether the seed runs it,
  # which is the half that can silently go missing.
  def run_seed
    silence_warnings { load Rails.root.join("db/seeds/users.rb").to_s }
    capture_io { seed_core_users! }
  end

  def migrate(direction) = capture_io { ReconcileTurfParkedIdentities.new.public_send(direction) }

  # --- the two copies ---------------------------------------------------------

  test "the migration's spelled-out identities still agree with the live ones" do
    assert_equal User::TURF_HOUSE_EMAIL, ReconcileTurfParkedIdentities::NEW_EMAIL
    assert_equal User::RETIRED_IDENTITIES, ReconcileTurfParkedIdentities::RETIRED_ROLES

    assert_nil User.parked_identity_for(email: ReconcileTurfParkedIdentities::OLD_EMAIL),
               "the roster still parks the address this migration retires"
    User::RETIRED_IDENTITIES.each_key do |email|
      assert_nil User.parked_identity_for(email: email),
                 "#{email} is being retired and parked at the same time"
    end
  end

  # --- the house address ------------------------------------------------------

  test "the migration moves the deployed house row onto its own domain" do
    row = house_row

    migrate(:up)

    assert_equal NEW, row.reload.email
    assert_equal 1, User.where(email: [OLD, NEW]).count, "the move duplicated the house account"
  end

  test "the migration leaves both rows alone when the new address is taken" do
    row = house_row
    other = house_row(NEW, username: "sideline")

    migrate(:up)

    assert_equal OLD, row.reload.email, "the row should be left in place for a manual merge"
    assert_equal NEW, other.reload.email
  end

  test "the migration is harmless with nothing to move" do
    migrate(:up)

    assert_nil User.find_by(email: OLD)
    assert_nil User.find_by(email: NEW)
  end

  test "the move reverses" do
    row = house_row

    migrate(:up)
    migrate(:down)

    assert_equal OLD, row.reload.email
  end

  # --- the retired seat -------------------------------------------------------

  # THE ORPHAN ADMIN. Dropping an identity from the roster takes nothing away
  # from its row — and this one sits on the address printed in the site footer as
  # the support contact, in an app where signing in is a magic link to that
  # mailbox.
  test "the migration takes admin off the seat the roster retired" do
    seat = retired_admin

    migrate(:up)

    assert_equal "user", seat.reload.role, "the retired seat kept admin"
  end

  test "the migration does not delete the retired account" do
    seat = retired_admin

    migrate(:up)

    assert User.exists?(seat.id), "a real account with entries and a wallet was destroyed"
    assert_equal RETIRED, seat.reload.email
  end

  test "the retirement re-runs without touching a row it already agrees with" do
    seat = retired_admin
    migrate(:up)

    # NOW() inside a transaction is the TRANSACTION's clock, so a second run would
    # stamp an identical timestamp and this would pass either way. Park the row in
    # the past so an UPDATE that should not happen has somewhere visible to land.
    long_ago = 1.year.ago.change(usec: 0)
    seat.update_column(:updated_at, long_ago)

    migrate(:up)

    assert_equal long_ago, seat.reload.updated_at, "a re-run rewrote a row it already agreed with"
  end

  test "the migration leaves an admin the roster never retired alone" do
    stranger = User.create!(name: "Stranger", email: "stranger@example.com", username: "stranger")
    stranger.update_column(:role, "admin")

    migrate(:up)

    assert_equal "admin", stranger.reload.role, "the retirement reached past the list it was handed"
  end

  test "the retirement reverses" do
    seat = retired_admin

    migrate(:up)
    migrate(:down)

    assert_equal "admin", seat.reload.role, "rolling back should restore the role that roster gave it"
  end

  # --- the seed: local, test, and a QA reset ----------------------------------

  test "the seed takes admin off the seat the roster retired" do
    seat = retired_admin

    run_seed

    assert_equal "user", seat.reload.role
    assert User.exists?(seat.id), "the seed destroyed a real account instead of demoting it"
  end

  test "the seed leaves an admin the roster never retired alone" do
    stranger = User.create!(name: "Stranger", email: "stranger@example.com", username: "stranger")
    stranger.update_column(:role, "admin")

    run_seed

    assert_equal "admin", stranger.reload.role
  end
end
