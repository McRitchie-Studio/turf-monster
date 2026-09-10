require "test_helper"

# EntryGift — the promise a gifted free entry rides on between "sent to an
# email" and "minted to a wallet".
class EntryGiftTest < ActiveSupport::TestCase
  setup do
    @sender  = users(:alex)
    @contest = contests(:one)
  end

  def build_gift(**attrs)
    EntryGift.new({ recipient_email: "friend@example.com", sender: @sender }.merge(attrs))
  end

  # --- validation + normalization ---

  test "normalizes the recipient email" do
    gift = build_gift(recipient_email: "  Friend@Example.COM ")
    assert gift.save
    assert_equal "friend@example.com", gift.recipient_email
  end

  test "refuses an address the magic-link path could not mail" do
    gift = build_gift(recipient_email: "not-an-email")
    assert_not gift.save
    assert_includes gift.errors[:recipient_email].to_sentence, "not a valid email"
  end

  test "refuses a blank recipient" do
    assert_not build_gift(recipient_email: "  ").save
  end

  # --- the idempotency key ---

  test "assigns a mint_ref on create and never reuses one" do
    a = build_gift
    b = build_gift(recipient_email: "other@example.com")
    assert a.save
    assert b.save
    assert a.mint_ref.present?
    assert_not_equal a.mint_ref, b.mint_ref
  end

  test "source_ref is deterministic across reloads" do
    gift = build_gift
    gift.save!
    assert_equal gift.mint_source_ref, EntryGift.find(gift.id).mint_source_ref
  end

  test "source_ref is namespaced by deployment" do
    gift = build_gift
    gift.save!
    assert_match(/\Agift:#{Rails.env}:#{gift.mint_ref}\z/, gift.mint_source_ref)
  end

  # THE CONSTRAINT THAT SILENTLY CORRUPTS IF IT SLIPS. Vault#padded_source_ref
  # raises past 64 BYTES, and a truncated ref would collide two gifts onto ONE
  # PDA — the exact failure the multi-token purchase hit (see its comment).
  # Asserted in bytes, not characters.
  test "source_ref fits the on-chain [u8;64] field" do
    gift = build_gift
    gift.save!
    assert_operator gift.mint_source_ref.b.bytesize, :<=, 64
  end

  # --- status is derived from the stamps, never stored ---

  test "status walks sent to claimed to minted" do
    gift = build_gift
    gift.save!
    assert_equal :sent, gift.status

    gift.update!(claimed_by: users(:jordan), claimed_at: Time.current)
    assert_equal :claimed, gift.status
    assert gift.claimed?

    gift.update!(minted_at: Time.current, mint_signature: "sig")
    assert_equal :minted, gift.status
    assert gift.minted?
  end

  test "a claim carrying a mint error reads as failed" do
    gift = build_gift
    gift.save!
    gift.update!(claimed_at: Time.current, mint_error: "no wallet")
    assert_equal :failed, gift.status
  end

  test "a minted gift stays minted even with a stale error on the row" do
    gift = build_gift
    gift.save!
    gift.update!(claimed_at: Time.current, mint_error: "transient", minted_at: Time.current)
    assert_equal :minted, gift.status
  end

  # --- stalled? is what the ledger renders loudly ---

  test "a fresh claim is not stalled" do
    gift = build_gift
    gift.save!
    gift.update!(claimed_at: 1.minute.ago)
    assert_not gift.stalled?
  end

  test "a claim with no token after ten minutes is stalled" do
    gift = build_gift
    gift.save!
    gift.update!(claimed_at: 30.minutes.ago)
    assert gift.stalled?
  end

  test "a minted gift is never stalled" do
    gift = build_gift
    gift.save!
    gift.update!(claimed_at: 30.minutes.ago, minted_at: 29.minutes.ago)
    assert_not gift.stalled?
  end

  test "an unclaimed gift is never stalled however old" do
    gift = build_gift
    gift.save!
    gift.update_column(:created_at, 1.year.ago)
    assert_not gift.stalled?
  end

  # --- landing ---

  test "landing_contest prefers its own contest" do
    gift = build_gift(contest: @contest)
    gift.save!
    assert_equal @contest, gift.landing_contest
  end

  test "landing_contest falls back to the featured contest" do
    gift = build_gift
    gift.save!
    assert_equal Contest.featured, gift.landing_contest
  end
end
