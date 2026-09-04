# frozen_string_literal: true

require "test_helper"

# THE SLOT AN ABANDONED ENTRY LEAVES BEHIND.
#
# Two places decide what "taken" means, and they disagreed:
#
#   Entry#assign_onchain_entry_number! builds its `taken` list from
#     cart/active/complete — it deliberately IGNORES abandoned rows
#   index_entries_on_user_contest_entry_number is partial on
#     `entry_number IS NOT NULL` — it does NOT ignore them
#
# So a player who reached the Phantom prompt (which stamps entry_number) and
# then tapped "Clear picks" (which abandons the row and left the number on it)
# got the same number handed back on their next attempt, and the insert died
# with a raw PG::UniqueViolation. Every retry collided identically, so they were
# locked out of that contest until someone cleared the row by hand.
#
# Reproduced three times on QA during the rehearsal build (mason-3 on qatest13
# held abandoned entries at numbers 0 and 1, and the third attempt raised).
class EntrySlotReleaseTest < ActiveSupport::TestCase
  setup do
    @user = users(:alex)
    @contest = Contest.create!(
      name: "Slot Release #{SecureRandom.hex(2)}",
      slate: slates(:one),
      contest_type: "tiny",
      status: "open",
      max_entries: 3,
      entry_fee_cents: 1900,
      starts_at: 1.hour.from_now,
      rank: 7000 + rand(900)
    )
  end

  # A vault that always offers the lowest index the caller did not exclude —
  # which is exactly what the real one does, and what makes the disagreement
  # above reachable.
  def vault_offering_lowest_free
    Class.new do
      def next_free_entry_index(_slug, _wallet, max:, skip: [])
        (0...max).find { |i| !skip.include?(i) }
      end
    end.new
  end

  def entry_at(number, status:)
    @contest.entries.create!(user: @user, status: status, entry_number: number)
  end

  test "abandoning an entry releases its slot number" do
    entry = entry_at(0, status: :cart)

    entry.update!(status: :abandoned)

    assert_nil entry.reload.entry_number,
               "an abandoned entry must not keep a slot the allocator already ignores"
  end

  # THE BUG, end to end at the model level. Without the fix the second
  # assignment re-offers 0 and the update violates the partial unique index.
  test "a player can be allocated a slot again after clearing picks" do
    first = entry_at(0, status: :cart)
    first.update!(status: :abandoned) # what clear_picks does

    second = @contest.entries.create!(user: @user, status: :cart)

    assigned = nil
    assert_nothing_raised do
      assigned = second.assign_onchain_entry_number!("WALLET", vault_offering_lowest_free)
    end

    assert_equal 0, assigned, "slot 0 is free again — nothing active holds it"
    assert_equal 0, second.reload.entry_number
  end

  # The release must not hand out a slot that is genuinely in use. This is the
  # assertion that stops the fix from becoming "null every entry_number".
  test "an ACTIVE entry keeps its slot, and the next allocation skips it" do
    active = entry_at(0, status: :active)
    second = @contest.entries.create!(user: @user, status: :cart)

    assigned = second.assign_onchain_entry_number!("WALLET", vault_offering_lowest_free)

    assert_equal 0, active.reload.entry_number, "an active entry keeps its slot"
    assert_equal 1, assigned, "the allocator must skip a slot that is still held"
  end

  # A confirmed entry that is later abandoned has REAL on-chain state at that
  # number — the PDA exists whatever the database says. Releasing the number
  # there would let a second entry be built against an occupied PDA.
  test "an entry with an on-chain signature keeps its slot even when abandoned" do
    confirmed = @contest.entries.create!(user: @user, status: :active, entry_number: 0,
                                         onchain_tx_signature: "sig-#{SecureRandom.hex(4)}")

    confirmed.update!(status: :abandoned)

    assert_equal 0, confirmed.reload.entry_number,
                 "the on-chain entry PDA still exists at this index — the slot is NOT free"
  end
end
