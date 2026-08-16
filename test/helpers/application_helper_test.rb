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
    assert_equal 26, bits.size

    bits.each do |bit|
      assert_includes 0..100, bit[:x], "x must be a percentage inside the button"
      assert_includes 0..100, bit[:y], "y must be a percentage inside the button"
      assert bit[:size].positive?, "a bubble needs a size"
      assert bit[:duration].positive?, "a bubble needs a cycle duration"
      assert bit[:delay] >= 0, "delay must not be negative"
      assert_includes ApplicationHelper::FIZZ_HUES, bit[:hue], "hues stay in the brand palette"
    end
  end

  test "fizz bits cover every color slot so a full pick set shows all twelve colors" do
    bits = hold_button_fizz_bits("desktop")
    slots = bits.map { |b| b[:slot] }

    assert_equal (1..ApplicationHelper::FIZZ_SLOTS).to_a, slots.uniq.sort,
      "every one of the twelve slots must be worn by at least one bubble"
    assert_equal 26, slots.size
    # Round-robin, so no slot hogs the button.
    assert_operator slots.tally.values.max - slots.tally.values.min, :<=, 1
  end

  test "a fizz bit reads its slot's color and falls back to its own hue" do
    bit = hold_button_fizz_bits("desktop").first
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
