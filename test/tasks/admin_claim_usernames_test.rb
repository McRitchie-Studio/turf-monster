require "test_helper"
require "rake"

# admin:claim_usernames — idempotent DB-only claim of parked kickoff
# usernames by wallet address (lib/tasks/admin_usernames.rake). On-chain
# set_username is deliberately NOT pushed (Phantom-owned wallets can't be
# signed server-side); the task reports what's still owed.
class AdminClaimUsernamesTaskTest < ActiveSupport::TestCase
  ALEX_BOT_WALLET = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  ALEX_WALLET     = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON_WALLET    = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  TURF_WALLET     = "BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("admin:claim_usernames")
    @task = Rake::Task["admin:claim_usernames"]
    @task.reenable
  end

  teardown { ENV.delete("DRY_RUN") }

  def create_kickoff_rows!
    # Mirrors prod: Alex's row holds "mcritchiee" and should become "mcritchie".
    @alex  = User.create!(email: "human@mcritchie.studio", name: "Mr. McRitchie", role: "admin",
                          username: "mcritchiee", web3_solana_address: ALEX_WALLET)
    @team  = User.create!(email: "team@mcritchie.studio", name: "Team McRitchie", role: "admin",
                          username: "team-auto", web3_solana_address: ALEX_BOT_WALLET)
    @mason = User.create!(email: "mason-task@mcritchie.studio", name: "Mason",
                          username: "mason", web3_solana_address: MASON_WALLET)
    @house = User.create!(email: User::TURF_HOUSE_EMAIL, name: "Turf Monster", role: "admin",
                          username: "turf", web3_solana_address: TURF_WALLET)
  end

  def run_task
    out = nil
    capture_io { @task.invoke }.then { |stdout, _| out = stdout }
    out
  end

  test "claims kickoff usernames by wallet and reports owed on-chain updates" do
    create_kickoff_rows!
    out = run_task

    assert_equal "mcritchie", @alex.reload.username
    assert_equal "alex",      @team.reload.username
    assert_equal "mason",     @mason.reload.username # already claimed
    assert_equal "turf",      @house.reload.username
    assert_equal "admin",     @alex.role
    assert_equal "admin",     @team.role

    assert_match(/CLAIMED\s+mcritchie/, out)
    assert_match(/CLAIMED\s+alex/, out)
    assert_match(/already claimed/, out)
    assert_match(/On-chain set_username still owed/, out)
    assert_match(/v0\.25 admin init path/, out)            # house account's path
    assert_match(/owner signs via \/account/, out)         # Phantom-owned rows
  end

  test "repairs parked role and email when username was already claimed" do
    users(:alex).update!(email: "fixture-admin@example.com")
    user = User.create!(username: "mcritchie", web3_solana_address: ALEX_WALLET)

    out = run_task

    assert_match(/CLAIMED\s+mcritchie/, out)
    user.reload
    assert_equal "admin", user.role
    assert_equal "alex@mcritchie.studio", user.email
    # Derived from the identity list: this asserts the REPAIR, and pinning the
    # literal name made a seed-copy rename read as a broken repair.
    assert_equal User.parked_identity_for(email: "alex@mcritchie.studio").fetch(:name), user.name
  end

  test "second run is a no-op (idempotent)" do
    create_kickoff_rows!
    run_task

    @task.reenable
    out = run_task
    refute_match(/CLAIMED/, out) # uppercase CLAIMED only appears on a write
    assert_equal "mcritchie", @alex.reload.username
  end

  test "username conflict is reported, not raised, and the holder keeps the name" do
    User.create!(email: "squatter@mcritchie.studio", username: "mcritchie")
    alex = User.create!(email: "human@mcritchie.studio", role: "admin",
                        username: "mcritchiee", web3_solana_address: ALEX_WALLET)

    out = run_task
    assert_match(/CONFLICT/, out)
    assert_equal "mcritchiee", alex.reload.username
  end

  test "DRY_RUN=1 reports the plan without writing" do
    create_kickoff_rows!
    ENV["DRY_RUN"] = "1"

    out = run_task
    assert_match(/DRY RUN/, out)
    assert_match(/CLAIM\s+mcritchie/, out)
    assert_equal "mcritchiee", @alex.reload.username
    assert_equal "team-auto", @team.reload.username
  end

  test "wallets with no matching user are reported as SKIP" do
    out = run_task
    assert_match(/SKIP/, out)
    assert_match(/no user holds this wallet/, out)
  end
end
