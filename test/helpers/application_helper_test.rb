require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # Lazarus audit #2: session replay runs only in production AND never on pages
  # that render secrets (controllers set @suppress_session_replay).
  test "session replay is off outside production" do
    @suppress_session_replay = nil
    assert_not session_replay_active?, "replay must not run outside production (test env)"
  end

  test "session replay runs in production by default but is suppressed on secret pages" do
    original_env = Rails.env
    Rails.env = "production"
    begin
      @suppress_session_replay = nil
      assert session_replay_active?, "replay should be active in production by default"

      @suppress_session_replay = true
      assert_not session_replay_active?, "replay must be suppressed when a controller flags a secret page"
    ensure
      Rails.env = original_env
    end
  end

  # --- Hold button fizz table ---
  # The whole point of seeding off hold_id (rather than calling rand at render
  # time) is that the markup is STABLE: Turbo restores a cached page and the
  # bubbles must land where they were, and the component test must be able to
  # assert on them at all.
  test "fizz bits are deterministic per hold_id and differ between buttons" do
    assert_equal hold_button_fizz_bits("desktop"), hold_button_fizz_bits("desktop"),
      "same hold_id must produce the identical scatter on every render"
    assert_not_equal hold_button_fizz_bits("desktop"), hold_button_fizz_bits("mobile"),
      "two buttons on one page should not fizz in lockstep"
  end

  test "fizz bits stay inside the button box and carry a full animation table" do
    bits = hold_button_fizz_bits("desktop")
    assert_equal 30, bits.size, "five bubbles in each of the six zones"

    bits.each do |bit|
      assert_includes 0..100, bit[:x], "x must be a percentage inside the button"
      assert_includes 0..100, bit[:y], "y must be a percentage inside the button"
      assert bit[:size].positive?, "a bubble needs a size"
      assert bit[:duration].positive?, "a bubble needs a cycle duration"
      assert bit[:delay] >= 0, "delay must not be negative"
      assert_includes ApplicationHelper::FIZZ_HUES, bit[:hue], "hues stay in the brand palette"
    end
  end

  test "each zone keeps to its own corner of the button" do
    # Six zones in a 3x2 grid — three along the top edge, three along the bottom,
    # numbered left to right, top row first. A bubble only ever wears the colors
    # of the team whose zone it sits in.
    bits = hold_button_fizz_bits("desktop")
    span = 100.0 / ApplicationHelper::FIZZ_ZONE_COLUMNS

    assert_equal (1..ApplicationHelper::FIZZ_ZONES).to_a, bits.map { |b| b[:zone] }.uniq.sort
    bits.group_by { |b| b[:zone] }.each do |zone, zone_bits|
      row = (zone - 1) / ApplicationHelper::FIZZ_ZONE_COLUMNS
      col = (zone - 1) % ApplicationHelper::FIZZ_ZONE_COLUMNS
      side = zone_bits.select { |b| b[:dx].abs > 8 } # the outer columns' side spray

      (zone_bits - side).each do |bit|
        assert_operator bit[:x], :>=, col * span, "zone #{zone} drifted left of its column"
        assert_operator bit[:x], :<=, (col + 1) * span, "zone #{zone} drifted right of its column"
      end
      # Top-row zones ride the top edge and rise; bottom-row zones the bottom.
      zone_bits.each do |bit|
        if row.zero?
          assert_operator bit[:y], :<, 50, "zone #{zone} belongs to the top edge"
          assert_operator bit[:dy], :<, 0, "a top-row bubble must rise"
        else
          assert_operator bit[:y], :>, 50, "zone #{zone} belongs to the bottom edge"
          assert_operator bit[:dy], :>, 0, "a bottom-row bubble must fall"
        end
      end
    end
  end

  test "the layers split each zone's three colors light-at-rest, dark-and-alt-on-hover" do
    # Slots run light, dark, alt per team in pick order (the board's fizzPalette
    # getter fills them), so zone N owns slots 3N-2, 3N-1, 3N.
    base = hold_button_fizz_bits("desktop", layer: :base)
    hover = hold_button_fizz_bits("desktop~extra", layer: :hover)

    assert_equal [ 1, 4, 7, 10, 13, 16 ], base.map { |b| b[:slot] }.uniq.sort,
      "the resting layer wears each team's light color"
    assert_equal [ 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 ], hover.map { |b| b[:slot] }.uniq.sort,
      "the hover layer alternates each team's dark and its alt"
    assert_empty base.map { |b| b[:slot] } & hover.map { |b| b[:slot] },
      "a color belongs to one layer or the other, never both"

    # And a bubble's color always belongs to its own zone.
    (base + hover).each do |bit|
      assert_equal bit[:zone], ((bit[:slot] - 1) / ApplicationHelper::FIZZ_COLORS_PER_TEAM) + 1,
        "a bubble must wear the colors of the team whose zone it sits in"
    end
  end

  test "a fizz bit reads its slot's color and falls back to its own hue" do
    bit = hold_button_fizz_bits("desktop", layer: :base).first
    color = hold_button_fizz_color(bit)

    assert_equal "var(--fizz-c-#{bit[:slot]}, hsl(#{bit[:hue]} 92% 70%))", color,
      "unbound slots must still paint a bubble"
  end

  test "fizz bits drift off both edges so the button looks carbonated, not top-heavy" do
    bits = hold_button_fizz_bits("desktop")

    assert bits.any? { |b| b[:dy].negative? }, "some bubbles must rise off the top edge"
    assert bits.any? { |b| b[:dy].positive? }, "some bubbles must fall off the bottom edge"
    assert bits.any? { |b| b[:dx].abs > 8 }, "the end bubbles must spray sideways"
  end
end
