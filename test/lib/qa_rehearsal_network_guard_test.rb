# frozen_string_literal: true

require "test_helper"

# The guard exists to stand between a mis-pointed driver and a mainnet-capable
# treasury key. Every test here is a REFUSAL test: the happy path is one line,
# and the value is entirely in what the guard declines to do.
class QaRehearsalNetworkGuardTest < ActiveSupport::TestCase
  Guard = TurfMonster::QaRehearsal::NetworkGuard

  # A reader that answers from a hash, so each test states the exact
  # deployment it is describing.
  def reader_for(values)
    ->(_app, var) { values[var] }
  end

  def devnet_values
    {
      "SOLANA_NETWORK"    => Guard::EXPECTED_NETWORK,
      "SOLANA_PROGRAM_ID" => Guard::EXPECTED_PROGRAM
    }
  end

  test "passes on the devnet QA app and reports what it proved" do
    facts = Guard.new(app: "turf-monster-qa", reader: reader_for(devnet_values)).assert!

    assert_equal "turf-monster-qa", facts[:app]
    assert_equal Guard::EXPECTED_NETWORK, facts[:network]
    assert_equal Guard::EXPECTED_PROGRAM, facts[:program_id]
  end

  test "refuses the production app even if it somehow answered devnet" do
    error = assert_raises(Guard::RefusedError) do
      Guard.new(app: "turf-monster-mainnet", reader: reader_for(devnet_values)).assert!
    end

    assert_match(/allow-list/, error.message)
  end

  test "refuses when the app reports mainnet" do
    values = devnet_values.merge("SOLANA_NETWORK" => "mainnet-beta")

    error = assert_raises(Guard::RefusedError) do
      Guard.new(app: "turf-monster-qa", reader: reader_for(values)).assert!
    end

    assert_match(/SOLANA_NETWORK/, error.message)
  end

  # The network check alone would pass here. This is the case that makes the
  # second assertion earn its place: a devnet-labelled app pointed at the
  # mainnet program is exactly the mix-up that would move real money.
  test "refuses a devnet-labelled app running a different program" do
    values = devnet_values.merge("SOLANA_PROGRAM_ID" => "DaFvSomeOtherProgramIdThatIsNotOurs11111111")

    error = assert_raises(Guard::RefusedError) do
      Guard.new(app: "turf-monster-qa", reader: reader_for(values)).assert!
    end

    assert_match(/SOLANA_PROGRAM_ID/, error.message)
  end

  # An unreadable config is not a pass. A `heroku config:get` against a missing
  # app exits non-zero and prints nothing, and treating that empty string as
  # "fine" is how a guard silently stops guarding.
  test "refuses when config cannot be read at all" do
    ["", nil, "   "].each do |blank|
      error = assert_raises(Guard::RefusedError) do
        Guard.new(
          app: "turf-monster-qa",
          reader: reader_for(devnet_values.merge("SOLANA_NETWORK" => blank))
        ).assert!
      end

      assert_match(/could not read SOLANA_NETWORK/, error.message)
    end
  end

  test "the refusal names itself as a refusal" do
    error = assert_raises(Guard::RefusedError) do
      Guard.new(app: "turf-monster-mainnet", reader: reader_for(devnet_values)).assert!
    end

    assert_match(/\AREFUSED/, error.message)
  end
end
