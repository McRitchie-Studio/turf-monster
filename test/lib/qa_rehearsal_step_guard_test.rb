# frozen_string_literal: true

require "test_helper"

# Every step runs NetworkGuard before it sends a script, shells out or loads a
# key. Each step is run here behind a guard that refuses, with everything it
# could reach replaced by a recorder.
class QaRehearsalStepGuardTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver
  Guard = TurfMonster::QaRehearsal::NetworkGuard

  CLI = Rails.root.join("bin/qa-contest-rehearsal").read.freeze
  STEP_METHODS = CLI.scan(/when "(?!status")[a-z]+"\s+then driver\.([a-z_]+)/).flatten.uniq.freeze

  DEVNET = { "SOLANA_NETWORK" => Guard::EXPECTED_NETWORK, "SOLANA_PROGRAM_ID" => Guard::EXPECTED_PROGRAM }.freeze
  QA_APP = Guard::ALLOWED_APPS.first

  # app, what the app's config answers, and the refusal it earns.
  REFUSALS = {
    "an app outside the allow-list" => ["some-other-app", DEVNET, /allow-list/],
    "a network that is not devnet" => [QA_APP, DEVNET.merge("SOLANA_NETWORK" => "mainnet-beta"), /SOLANA_NETWORK/],
    "a program id that is not devnet's" =>
      [QA_APP, DEVNET.merge("SOLANA_PROGRAM_ID" => "11111111111111111111111111111111"), /SOLANA_PROGRAM_ID/]
  }.freeze

  MANIFEST = { "contest_slug" => "qa-rehearsal-x", "picks_required" => 1, "matchup_ids" => [1],
               "kickoff_shift_seconds" => 0 }.freeze

  # A driver whose every way out is recorded in `reached`.
  def driver_for(app, reached)
    driver = Driver.new(app: app, io: StringIO.new)
    remote = Object.new
    remote.define_singleton_method(:call) do |source|
      reached << source
      Hash.new { |_hash, key| key == "seeded" ? [] : "x" }
    end
    manifest = Object.new
    manifest.define_singleton_method(:read) { MANIFEST }
    manifest.define_singleton_method(:merge) { |*| MANIFEST }
    manifest.define_singleton_method(:write) { |*| MANIFEST }
    driver.instance_variable_set(:@remote, remote)
    driver.instance_variable_set(:@manifest, manifest)
    driver.define_singleton_method(:system) { |*argv| reached << argv }
    driver
  end

  def run_step(method, app:, config:)
    reached = []
    build = Guard.method(:new)
    guarded = ->(app:) { build.call(app: app, reader: ->(_app, var) { config[var] }) }
    key_store = -> { reached << :key_store }

    Guard.stub(:new, guarded) do
      TurfMonster::QaRehearsal::KeyStore.stub(:new, key_store) do
        yield -> { driver_for(app, reached).public_send(method) }
      end
    end
    reached
  end

  test "the step list really derived from the CLI" do
    assert_equal %w[seed_roster create_contest enter_cast play_preseason conclude close_contest], STEP_METHODS
  end

  STEP_METHODS.each do |method|
    REFUSALS.each do |label, (app, config, reason)|
      test "#{method} sends nothing to #{label}" do
        reached = run_step(method, app: app, config: config) do |step|
          error = assert_raises(Guard::RefusedError) { step.call }
          assert_match reason, error.message
        end

        assert_empty reached, "#{method} reached past a refusing guard"
      end
    end
  end

  # The recorder is live: behind a guard that passes, the same harness sees the
  # step's script.
  test "the seed step sends its script once the guard passes" do
    reached = run_step("seed_roster", app: QA_APP, config: DEVNET, &:call)

    assert_equal 1, reached.size
    assert_includes reached.first, "seed_parked_identities!(proven_only: true)"
  end
end
