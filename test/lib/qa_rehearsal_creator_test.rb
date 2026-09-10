# frozen_string_literal: true

require "test_helper"

# WHO THE REHEARSAL CREATES ITS CONTEST AS.
#
# Step 1 built its creator lookup out of a hard-coded slug, `alex-2`. A User slug
# is "#{username}-#{id}" and Sluggable rewrites it on EVERY save, so the
# 2026-09-04 operator username swap renamed that row to `mcritchie-2` and the
# lookup would have returned nil — with no raise, because the `||` fallback beside
# it picked an arbitrary admin. The rehearsal would then have created its contest
# under an identity the server holds no key for, and failed four steps later with
# an error about signature counts.
#
# The script is generated locally and executed on the dyno, so these read the
# script the driver actually SENDS rather than the source it is written in — the
# whole defect lived in an interpolated literal.
class QaRehearsalCreatorTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  # Enough of a step-1 answer for the driver to finish printing.
  REMOTE_RESULT = {
    "contest_slug" => "qa-rehearsal-x", "name" => "QA Rehearsal", "onchain" => true,
    "picks_required" => 6, "payouts" => { "1" => 100 }, "prize_pool_cents" => 50_000,
    "matchup_ids" => [1, 2, 3], "locks_at" => "2026-09-06T00:00:00Z", "minted" => nil,
    "kickoff_shift_seconds" => 0
  }.freeze

  class ScriptSpy
    attr_reader :scripts

    def initialize = (@scripts = [])

    def call(source)
      @scripts << source
      REMOTE_RESULT
    end
  end

  class NullManifest
    def write(data) = data
    def read = REMOTE_RESULT
  end

  # NetworkGuard and RemoteRunner both reach the network; @facts is what `guard!`
  # memoizes, so priming it is how a test runs a step without a dyno.
  def create_contest_script
    spy = ScriptSpy.new
    driver = Driver.new(io: StringIO.new)
    driver.instance_variable_set(:@facts, { "network" => "devnet" })
    driver.instance_variable_set(:@remote, spy)
    driver.instance_variable_set(:@manifest, NullManifest.new)
    driver.create_contest
    spy.scripts.fetch(0)
  end

  test "the generated script keys the creator on an address, never on a slug" do
    script = create_contest_script

    assert_includes script, %(User.find_by(email: "#{Driver::CREATOR_EMAIL}"))
    refute_match(/User\.find_by\(slug:/, script,
                 "the creator is keyed on a slug again — Sluggable rewrites those on every save")
    refute_match(/User\.where\(role: "admin"\)\.first/, script,
                 "the unordered admin fallback is back: it substitutes silently for the identity " \
                 "the server can actually sign as")
  end

  test "a missing creator stops the run instead of substituting an admin" do
    script = create_contest_script

    assert_includes script, "raise #{Driver::CREATOR_MISSING.inspect} if creator.nil?"
  end

  # The address is only the right key if it names the right ROW. This is the
  # identity KeyStore files as "alex" (agent.alex.solana) — the wallet the server
  # signs with as fee payer and contest creator.
  test "the creator address is a parked admin identity in this app" do
    identity = User.parked_identity_for(email: Driver::CREATOR_EMAIL)

    refute_nil identity, "the rehearsal creates contests as an identity the roster does not seed"
    assert_equal "admin", identity[:role]
    assert_equal "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd", identity[:wallet],
                 "the creator must be the Alex Bot wallet the server signs with"
  end

  # THE MECHANISM, demonstrated rather than argued. Build the row as production
  # holds it — the creator on username `alex`, so slug `alex-<id>` — then let the
  # seed apply the swap, and watch the slug the old lookup used move.
  test "the swap rewrites the slug the creator used to be found by" do
    creator = User.create!(email: Driver::CREATOR_EMAIL, name: "Team McRitchie",
                           username: "alex", role: "admin",
                           web3_solana_address: "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd")
    users(:alex).update!(email: "fixture-admin@example.com", username: "fixtureadmin")
    was = creator.reload.slug
    assert_equal "alex-#{creator.id}", was

    silence_warnings { load Rails.root.join("db/seeds/users.rb").to_s }
    capture_io { seed_core_users! }

    creator.reload
    refute_equal was, creator.slug, "the slug did not move, so this test no longer covers the defect"
    assert_equal "mcritchie-#{creator.id}", creator.slug
    assert_equal creator.id, User.find_by(email: Driver::CREATOR_EMAIL).id,
                 "the address still finds the creator after the rename that broke the slug"
    assert_nil User.find_by(slug: was), "the slug the driver used to key on now finds nobody"
  end
end
