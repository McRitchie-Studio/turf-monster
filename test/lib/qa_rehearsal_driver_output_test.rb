# frozen_string_literal: true

require "test_helper"

# What the driver PRINTS is part of the product here. The operator runs this
# from a terminal and watches it in a browser, so a step that says what it did
# without saying where to look sends them hunting for a URL.
class QaRehearsalDriverOutputTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  def capture
    io = StringIO.new
    yield Driver.new(io: io)
    io.string
  end

  test "the URL block names the contest, its live board, and the league board" do
    out = capture { |d| d.send(:say_urls, "qa-rehearsal-x") }

    assert_match %r{https://#{Driver::HOST}/contests/qa-rehearsal-x$}, out
    assert_match %r{https://#{Driver::HOST}/contests/qa-rehearsal-x/live}, out
    assert_match %r{https://#{Driver::HOST}/live}, out
  end

  # Step 3 is the watching step, so its links lead with the board that moves.
  test "the watching step leads with the live board" do
    out = capture { |d| d.send(:say_urls, "qa-rehearsal-x", live_first: true) }
    lines = out.lines.map(&:strip).reject(&:empty?)

    assert_match(/Live Board/, lines.first)
  end

  test "the default order leads with the contest itself" do
    out = capture { |d| d.send(:say_urls, "qa-rehearsal-x") }
    lines = out.lines.map(&:strip).reject(&:empty?)

    assert_match(/Contest:/, lines.first)
  end

  # The cast is a deliberate list — see DEFAULT_CAST's comment for why alex and
  # the turf-5 admin account cannot play. A silent change here would produce a
  # rehearsal that no longer exercises three real on-chain wallets.
  test "the default cast is the three wallets with filed keys" do
    assert_equal %w[mason mack turf], Driver::DEFAULT_CAST
    refute_includes Driver::DEFAULT_CAST, "alex", "alex IS the fee payer — it cannot also be a player"
    refute_includes Driver::DEFAULT_CAST, Driver::ADMIN_ACTOR, "the admin actor drives HTTP, it does not play"
  end
end
