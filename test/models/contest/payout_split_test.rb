require "test_helper"

# Contest::PayoutSplit is a pure function of finishing scores and a payout
# table, so the tie rules are pinned here without a database.
class Contest::PayoutSplitTest < ActiveSupport::TestCase
  STANDARD = { 1 => 300_00, 2 => 100_00, 3 => 50_00, 4 => 50_00 }.freeze

  def split(scores, payouts = STANDARD)
    Contest::PayoutSplit.call(scores, payouts)
  end

  test "no ties pays each place its prize and nothing past the last place" do
    assert_equal [[1, 300_00], [2, 100_00], [3, 50_00], [4, 50_00], [5, 0]], split([9, 8, 7, 6, 5])
  end

  test "a tie at the last paid rank pays the earliest entry alone" do
    assert_equal [[1, 300_00], [2, 100_00], [3, 50_00], [4, 50_00], [4, 0], [4, 0]], split([9, 8, 7, 6, 6, 6])
  end

  test "a tie inside the paid ranks pools and splits the places it covers" do
    assert_equal [[1, 200_00], [1, 200_00], [3, 50_00], [4, 50_00]], split([9, 9, 7, 6])
    assert_equal [[1, 300_00], [2, 75_00], [2, 75_00], [4, 50_00], [5, 0]], split([9, 8, 8, 6, 5])
  end

  test "a tie across the last paid rank pays its earliest entries the places left" do
    # Ranks 3 and 4 are the places left; the two earliest of the three split them.
    assert_equal [[1, 300_00], [2, 100_00], [3, 50_00], [3, 50_00], [3, 0]], split([9, 8, 7, 7, 7])
    large = { 1 => 1000_00, 2 => 400_00, 3 => 200_00, 4 => 200_00 }
    assert_equal [[1, 1000_00], [2, 266_67], [2, 266_67], [2, 266_66], [2, 0]], split([9, 8, 8, 8, 8], large)
  end

  test "everyone tied pays only as many entries as there are places" do
    result = split(Array.new(29, 1))
    assert_equal 4, result.count { |_rank, cents| cents > 0 }
    assert_equal [125_00] * 4, result.first(4).map(&:last)
    assert(result.all? { |rank, _cents| rank == 1 })
  end

  test "the remainder cent goes to the earliest entries" do
    assert_equal [[1, 133_34], [1, 133_33], [1, 133_33]], split([5, 5, 5], { 1 => 200_00, 2 => 100_00, 3 => 100_00 })
  end

  test "paid entries never exceed the places and the total never exceeds the table" do
    patterns = [[1] * 10, [3, 2, 2, 2, 2, 1], [4, 4, 3, 3, 2, 2, 1, 1], (1..10).to_a.reverse, [7, 7, 7, 7, 7, 1]]
    [STANDARD, { 1 => 100_00, 2 => 40_00 }, { 1 => 45_00 }].each do |table|
      patterns.each do |scores|
        result = split(scores, table)
        assert_operator result.count { |_r, c| c > 0 }, :<=, table.size
        assert_operator result.sum(&:last), :<=, table.values.sum
      end
    end
  end

  test "an empty field pays nothing" do
    assert_equal [], split([])
  end
end
