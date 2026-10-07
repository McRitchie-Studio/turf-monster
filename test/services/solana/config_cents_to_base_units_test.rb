require "test_helper"

# Money reaches the chain as USDC base units, and it is converted from integer
# cents with integer arithmetic only.
#
# USDC carries 6 decimals and a cent carries 2, so one cent is exactly 10_000
# base units. A path through a Float (`cents / 100.0 * 10**6`, then `to_i`)
# truncates one base unit short whenever the binary product lands a hair under
# the integer: 201 cents becomes 2_009_999. That happens for 9_552 of the cent
# values 0..500_000 and 19_102 of 0..1_000_000.
class Solana::ConfigCentsToBaseUnitsTest < ActiveSupport::TestCase
  RANGE = 0..1_000_000

  # The float formula the app used before the integer path. Kept here as the
  # control: the property below must be one this formula FAILS.
  def float_path(cents) = (cents / 100.0 * 10**Solana::Config::DECIMALS).to_i

  test "one cent is 10_000 base units because USDC has 6 decimals" do
    assert_equal 6, Solana::Config::DECIMALS
    assert_equal 10_000, Solana::Config::BASE_UNITS_PER_CENT
  end

  test "every cent value converts exactly, by integer arithmetic" do
    wrong = RANGE.reject { |cents| Solana::Config.cents_to_base_units(cents) == cents * 10_000 }
    assert_empty wrong.first(10), "#{wrong.size} cent values convert inexactly"
  end

  test "201 cents is 2_010_000 base units, the audit's example" do
    assert_equal 2_010_000, Solana::Config.cents_to_base_units(201)
  end

  test "control: the float path fails the same property" do
    wrong = (0..500_000).count { |cents| float_path(cents) != cents * 10_000 }
    assert_equal 9_552, wrong, "the property must bite the formula it replaces"
    assert_equal 2_009_999, float_path(201)
  end

  test "a non-integer amount raises instead of being truncated" do
    [ 2.01, BigDecimal("2.01"), Rational(201, 100), "201", nil ].each do |bad|
      assert_raises(ArgumentError, "#{bad.inspect} must not convert") do
        Solana::Config.cents_to_base_units(bad)
      end
    end
  end

  test "base units read back as exact BigDecimal dollars" do
    RANGE.step(7).each do |cents|
      dollars = Solana::Config.base_units_to_dollars(cents * 10_000)
      assert_kind_of BigDecimal, dollars
      assert_equal BigDecimal(cents) / 100, dollars, "#{cents} cents"
    end
    assert_equal "2.01", Solana::Config.base_units_to_dollars(2_010_000).to_s("F")
  end

  test "base_units_to_dollars refuses a non-integer amount" do
    assert_raises(ArgumentError) { Solana::Config.base_units_to_dollars(2.01) }
  end

  test "the float conversions are gone" do
    refute_respond_to Solana::Config, :dollars_to_lamports
    refute_respond_to Solana::Config, :lamports_to_dollars
  end
end
