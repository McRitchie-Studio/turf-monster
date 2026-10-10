require "test_helper"
require "rake"

# users:clear_rotated_out_wallet (lib/tasks/users.rake) takes the rotated-out
# wallet off any user row and ends that row's live sessions.
class UsersClearRotatedOutWalletTaskTest < ActiveSupport::TestCase
  ROTATED = Solana::RotatedOutWallet::ADDRESS
  OTHER   = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("users:clear_rotated_out_wallet")
    @task = Rake::Task["users:clear_rotated_out_wallet"]
    @task.reenable
  end

  def run_task
    out, = capture_io { @task.invoke }
    @task.reenable
    out
  end

  def writes
    seen = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql] if payload[:sql].match?(/\A\s*(UPDATE|INSERT|DELETE)/i)
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  test "clears the wallet, keeps the account, and ends its sessions" do
    house = User.create!(email: User::TURF_HOUSE_EMAIL, name: "Turf Monster", role: "admin",
                         username: "turf", web3_solana_address: ROTATED, seeding_parked_identity: true)
    house.record_web3_authentication!(provider: "phantom")
    token = house.reload.session_token
    other = User.create!(email: "mason-task@mcritchie.studio", username: "mason", web3_solana_address: OTHER)

    out = run_task

    house.reload
    assert_nil house.web3_solana_address
    assert_nil house.web3_authenticated_at
    assert_nil house.web3_wallet_provider
    assert_equal :none, house.wallet_kind
    assert_equal ["admin", "turf", User::TURF_HOUSE_EMAIL], [house.role, house.username, house.email]
    refute_equal token, house.session_token, "a session opened by the rotated-out key survives"
    assert_nil User.from_solana_wallet(ROTATED)
    assert_equal OTHER, other.reload.web3_solana_address

    assert_match(/cleared 1 user: turf\b/, out)
  end

  test "prints the count and usernames, never the address" do
    User.create!(email: User::TURF_HOUSE_EMAIL, role: "admin", username: "turf", web3_solana_address: ROTATED, seeding_parked_identity: true)

    out = run_task

    refute_includes out, ROTATED
    refute_includes out, User::TURF_HOUSE_EMAIL
  end

  # A wallet-only row has no other sign-in method; the clear must not be refused
  # by the row's own validations.
  test "clears a row whose only sign-in method was the wallet" do
    user = User.create!(web3_solana_address: ROTATED)

    run_task

    assert_nil user.reload.web3_solana_address
  end

  test "a second run finds nothing and writes nothing" do
    User.create!(email: User::TURF_HOUSE_EMAIL, role: "admin", username: "turf", web3_solana_address: ROTATED, seeding_parked_identity: true)
    run_task

    out = nil
    sql = writes { out = run_task }

    assert_match(/cleared 0 users/, out)
    assert_empty sql
  end

  test "a database that never held the wallet is left alone" do
    out = nil
    sql = writes { out = run_task }

    assert_match(/cleared 0 users/, out)
    assert_empty sql
  end
end
