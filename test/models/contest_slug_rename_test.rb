require "test_helper"

# A contest's slug seeds its on-chain PDAs: the contest, prize pool and entry
# addresses all hash sha256(slug), and every settle, read, lock and reconcile
# path derives the PDA from the slug again. Once a contest is bound to chain,
# renaming it would point every later instruction at an empty address and
# strand the pool, so the rename is refused. An off-chain contest may still be
# renamed, under the contest's own slug rules, and the rename carries the
# purchase rows that name it.
class ContestSlugRenameTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
  end

  test "a contest with an onchain_contest_id refuses a rename and keeps its slug" do
    @contest.update_columns(onchain_contest_id: "PDA#{SecureRandom.hex(8)}")

    error = assert_raises(Sluggable::SlugRefused) { @contest.rename_slug!("renamed-contest") }

    assert_match(/on chain/, error.record.errors[:slug].to_sentence)
    assert_equal "test-contest", @contest.reload.slug
  end

  test "a contest with only an onchain_tx_signature refuses a rename" do
    @contest.update_columns(onchain_tx_signature: "SIG#{SecureRandom.hex(16)}")

    assert_raises(Sluggable::SlugRefused) { @contest.rename_slug!("renamed-contest") }
    assert_equal "test-contest", @contest.reload.slug
  end

  test "rename_slug answers false with the reason for an on-chain contest" do
    @contest.update_columns(onchain_contest_id: "PDA#{SecureRandom.hex(8)}")

    assert_equal false, @contest.rename_slug("renamed-contest")
    assert_match(/on chain/, @contest.errors[:slug].to_sentence)
    assert_equal "test-contest", @contest.reload.slug
  end

  test "an on-chain contest refuses a direct slug write too" do
    @contest.update_columns(onchain_contest_id: "PDA#{SecureRandom.hex(8)}")

    refute @contest.update(slug: "renamed-contest")
    assert_match(/on chain/, @contest.errors[:slug].to_sentence)
    assert_equal "test-contest", @contest.reload.slug
  end

  test "an on-chain contest still saves other edits" do
    @contest.update_columns(onchain_contest_id: "PDA#{SecureRandom.hex(8)}")

    assert @contest.update(name: "A New Display Name")
    assert_equal "test-contest", @contest.reload.slug
  end

  test "an off-chain contest renames" do
    @contest.rename_slug!("renamed-contest")

    assert_equal "renamed-contest", @contest.reload.slug
  end

  test "a rename past the 64-byte PDA seed cap is refused" do
    too_long = "a" * (Contest::SLUG_MAX_BYTES + 1)

    assert_raises(Sluggable::SlugRefused) { @contest.rename_slug!(too_long) }
    assert_equal "test-contest", @contest.reload.slug
  end

  test "the rename uses the contest's slug format" do
    assert_equal Contest::SLUG_FORMAT, Contest.slug_format
    assert_raises(Sluggable::SlugRefused) { @contest.rename_slug!("Not A Slug") }
  end

  test "the purchase tables are declared as contest_slug children" do
    %w[aeropay_purchases coinflow_purchases paypal_purchases].each do |table|
      assert_includes Contest.slug_children, [table, "contest_slug"]
    end
  end
end
