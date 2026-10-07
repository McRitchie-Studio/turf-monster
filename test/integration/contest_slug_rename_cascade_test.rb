require "test_helper"

# The purchase tables name a contest by its slug (contest_slug) with no
# association on Contest, so the rename reaches them only through the
# has_slug_children declaration. This runs the rename against the real tables:
# an off-chain rename carries every purchase row with it, and a refused rename
# of an on-chain contest leaves both the contest and its purchases where they
# were.
class ContestSlugRenameCascadeTest < ActiveSupport::TestCase
  PURCHASE_CLASSES = [AeropayPurchase, CoinflowPurchase, PaypalPurchase].freeze

  setup do
    @contest = contests(:one)
    @user = users(:jordan)
    @purchases = PURCHASE_CLASSES.map { |klass| create_purchase(klass, contest_slug: @contest.slug) }
    @bystanders = PURCHASE_CLASSES.map { |klass| create_purchase(klass, contest_slug: "some-other-contest") }
  end

  test "renaming an off-chain contest carries its purchase rows" do
    counts = @contest.rename_slug!("renamed-contest")

    assert_equal "renamed-contest", @contest.reload.slug
    @purchases.each { |purchase| assert_equal "renamed-contest", purchase.reload.contest_slug }
    @bystanders.each { |purchase| assert_equal "some-other-contest", purchase.reload.contest_slug }
    %w[aeropay_purchases coinflow_purchases paypal_purchases].each do |table|
      assert_equal 1, counts.fetch("#{table}.contest_slug")
    end
  end

  test "a refused rename of an on-chain contest moves nothing" do
    @contest.update_columns(onchain_contest_id: "PDA#{SecureRandom.hex(8)}")

    assert_raises(Sluggable::SlugRefused) { @contest.rename_slug!("renamed-contest") }

    assert_equal "test-contest", @contest.reload.slug
    @purchases.each { |purchase| assert_equal "test-contest", purchase.reload.contest_slug }
  end

  private

  def create_purchase(klass, contest_slug:)
    attributes = { user: @user, pack_id: "single", quantity: 1, price_cents: 19_00, status: "pending", contest_slug: contest_slug }
    attributes[:paypal_order_id] = "ORDER_#{SecureRandom.hex(4)}" if klass == PaypalPurchase
    klass.create!(attributes)
  end
end
