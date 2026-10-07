require "test_helper"

class CentsTest < ActiveSupport::TestCase
  test "every two-place dollar string parses to its exact cents" do
    wrong = (0..100_000).reject do |cents|
      Cents.from_dollars(format("%d.%02d", cents / 100, cents % 100)) == cents
    end
    assert_empty wrong.first(10), "#{wrong.size} dollar strings parse inexactly"
  end

  test "control: the Float parse it replaces drops a cent" do
    assert_equal 200, ("2.01".to_f * 100).to_i
    assert_equal 201, Cents.from_dollars("2.01")
  end

  test "integers, sub-cent amounts and junk" do
    assert_equal 25_00, Cents.from_dollars(25)
    assert_equal 1_99, Cents.from_dollars("1.999")
    assert_equal(-10_00, Cents.from_dollars("-10"))
    [ nil, "", "  ", "abc", "NaN", "Infinity" ].each do |junk|
      assert_equal 0, Cents.from_dollars(junk), junk.inspect
    end
  end
end
