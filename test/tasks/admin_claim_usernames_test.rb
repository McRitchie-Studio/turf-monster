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

  # The parked usernames, read from the roster rather than spelled out: `alex`
  # and `mcritchie` traded owners on 2026-09-04, and this file is about the
  # claim mechanism, not about which name each identity currently parks.
  def parked(email) = User.parked_username_for(email: email)

  def create_kickoff_rows!
    # Mirrors prod: Alex's row holds a near-miss username and should be claimed
    # onto the parked one.
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

    assert_equal parked("alex@mcritchie.studio"), @alex.reload.username
    assert_equal parked("team@mcritchie.studio"), @team.reload.username
    assert_equal "mason",     @mason.reload.username # already claimed
    assert_equal "turf",      @house.reload.username
    assert_equal "admin",     @alex.role
    assert_equal "admin",     @team.role

    assert_match(/CLAIMED\s+#{parked("alex@mcritchie.studio")}/, out)
    assert_match(/CLAIMED\s+#{parked("team@mcritchie.studio")}/, out)
    assert_match(/already claimed/, out)
    assert_match(/On-chain set_username still owed/, out)
    assert_match(/v0\.25 admin init path/, out)            # house account's path
    assert_match(/owner signs via \/account/, out)         # Phantom-owned rows
  end

  test "repairs parked role and email when username was already claimed" do
    users(:alex).update!(email: "fixture-admin@example.com")
    user = User.create!(username: parked("alex@mcritchie.studio"), web3_solana_address: ALEX_WALLET)

    out = run_task

    assert_match(/CLAIMED\s+#{parked("alex@mcritchie.studio")}/, out)
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
    assert_equal parked("alex@mcritchie.studio"), @alex.reload.username
  end

  # THE SWAP DEADLOCK. `alex` and `mcritchie` traded owners on 2026-09-04, and
  # each row then wanted a name the OTHER was sitting on. The holder check saw a
  # squatter in both directions, reported two CONFLICTs, wrote nothing and exited
  # 0 — so the swap looked applied and had not been. Production is the only
  # database where this can happen (a fresh one creates every row already
  # correct), which is exactly why it has to be built by hand here.
  test "two rows that want each other's usernames both get claimed" do
    alex = User.create!(email: "human@mcritchie.studio", name: "Alex McRitchie", role: "admin",
                        username: parked("team@mcritchie.studio"), web3_solana_address: ALEX_WALLET)
    team = User.create!(email: "team@mcritchie.studio", name: "Team McRitchie", role: "admin",
                        username: parked("alex@mcritchie.studio"), web3_solana_address: ALEX_BOT_WALLET)

    out = run_task

    assert_equal parked("alex@mcritchie.studio"), alex.reload.username
    assert_equal parked("team@mcritchie.studio"), team.reload.username
    refute_match(/CONFLICT/, out, "a swap partner was mistaken for a squatter")
  end

  # The dry run has to READ as a swap too, or the operator previews two conflicts
  # and never runs the real thing.
  test "DRY_RUN previews a swap as a claim and writes nothing" do
    alex = User.create!(email: "human@mcritchie.studio", name: "Alex McRitchie", role: "admin",
                        username: parked("team@mcritchie.studio"), web3_solana_address: ALEX_WALLET)
    team = User.create!(email: "team@mcritchie.studio", name: "Team McRitchie", role: "admin",
                        username: parked("alex@mcritchie.studio"), web3_solana_address: ALEX_BOT_WALLET)
    ENV["DRY_RUN"] = "1"

    out = run_task

    refute_match(/CONFLICT/, out)
    assert_match(/releases it/, out)
    assert_equal parked("team@mcritchie.studio"), alex.reload.username, "DRY_RUN wrote"
    assert_equal parked("alex@mcritchie.studio"), team.reload.username, "DRY_RUN wrote"
  end

  # A row NO kickoff wallet owns keeps its name. Parking a swap partner must not
  # become a licence to rename a stranger — the partner is only ever released
  # because it is about to claim a parked name of its own.
  test "username conflict is reported, not raised, and the holder keeps the name" do
    # The squatter must hold the name this wallet actually WANTS, or there is no
    # conflict left to report.
    User.create!(email: "squatter@mcritchie.studio", username: parked("alex@mcritchie.studio"))
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
