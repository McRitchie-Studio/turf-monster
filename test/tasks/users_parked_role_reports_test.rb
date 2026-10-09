require "test_helper"
require "rake"

# The two read-only operator reports in lib/tasks/users.rake.
class UsersParkedRoleReportsTaskTest < ActiveSupport::TestCase
  HOUSE   = User::TURF_HOUSE_EMAIL
  VARIANT = "Team@turfmonster.media".freeze
  WALLET  = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("users:parked_role_audit")
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    out, = capture_io { task.invoke }
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

  # A row as it could sit in a database written before the case rule.
  def stored(username, email, role: "admin", verified: false, wallet: nil)
    user = User.create!(web3_solana_address: wallet || Solana::Keypair.generate.to_base58, username: username)
    user.update_columns(email: email, role: role, email_verified_at: (Time.current if verified))
    user
  end

  test "email_case_collisions counts colliding addresses and prints none" do
    User.create!(email: "pair@example.com")
    stored("pair-two", "Pair@Example.com", role: "viewer")
    stored("pair-three", "PAIR@example.com", role: "viewer")
    stored("padded", " Lone@example.com", role: "viewer")

    out = nil
    assert_empty writes { out = run_task("users:email_case_collisions") }

    assert_match(/1 colliding address across 3 rows/, out)
    assert_match(/3 rows hold an address that is not stripped and downcased/, out)
    assert_match(/would fail/, out)
    refute_match(/@/, out, "the report prints an address")
  end

  test "email_case_collisions reports a clean table" do
    out = run_task("users:email_case_collisions")

    assert_match(/0 colliding addresses across 0 rows/, out)
    assert_match(/would build/, out)
  end

  test "parked_role_audit lists the usernames to check and writes nothing" do
    users(:alex).update_columns(email_verified_at: Time.current)
    stored("case-variant", VARIANT, verified: true)
    team = User.parked_identity_for(email: "team@mcritchie.studio")
    stored("seeded-team", team[:email], wallet: team[:wallet])
    stored("parked-email-no-role", "mason@mcritchie.studio", role: "viewer")
    stored("stray-admin", "stray@example.com", verified: true)

    out = nil
    assert_empty writes { out = run_task("users:parked_role_audit") }

    assert_match(/^users:parked_role_audit — 2 holding a parked role/, out)
    assert_match(/^  case-variant — role admin; email is not an exact match; parked wallet does not match$/, out)
    assert_match(/^  seeded-team — role admin; email unverified; parked wallet matches$/, out)
    assert_match(/^1 admin row matching no parked identity\n  stray-admin$/, out)
    refute_match(/#{users(:alex).username}|parked-email-no-role/, out)
    refute_match(/@/, out, "the report prints an address")
  end

  test "parked_role_audit is quiet on a verified roster" do
    users(:alex).update_columns(email_verified_at: Time.current)

    out = run_task("users:parked_role_audit")

    assert_match(/— 0 holding a parked role/, out)
    assert_match(/^0 admin rows matching no parked identity$/, out)
  end
end
