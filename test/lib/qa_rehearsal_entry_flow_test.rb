# frozen_string_literal: true

require "test_helper"

# EntryFlow drives HTTP, so what it is worth testing is the ORDER and SHAPE of
# the calls it makes — the things that broke in practice.
class QaRehearsalEntryFlowTest < ActiveSupport::TestCase
  Flow = TurfMonster::QaRehearsal::EntryFlow

  # Records every call and answers the way the real endpoints do.
  class FakeSession
    attr_reader :calls, :keypair

    def initialize(prepare: nil, confirm: nil, toggle_error: nil)
      @calls = []
      @prepare = prepare || { "success" => true, "serialized_tx" => "AA==",
                              "entry_id" => 7, "entry_pda" => "PDA", "ptx_slug" => "ptx-1" }
      @confirm = confirm || { "success" => true, "tx_signature" => "SIG" }
      @toggle_error = toggle_error
      @selected = 0
      @keypair = Object.new
    end

    def verify_age!(**) = @calls << [:verify_age]

    def post_json(path, **params)
      @calls << [path.split("/").last.to_sym, params]

      case path
      when %r{/clear_picks} then (@selected = 0) && { "success" => true }
      when %r{/toggle_selection}
        return { "error" => @toggle_error } if @toggle_error

        @selected += 1
        { "selections" => {}, "selection_count" => @selected }
      when %r{/prepare_entry} then @prepare
      when %r{/confirm_onchain_entry} then @confirm
      end
    end
  end

  def flow_for(session, picks: [1, 2, 3])
    Flow.new(session: session, contest_slug: "c", matchup_ids: picks, picks_required: picks.size)
  end

  # The order is the point. Clearing AFTER building would wipe the picks it
  # just made; not clearing at all is what made a re-run toggle them off.
  test "the cart is cleared BEFORE any pick is toggled" do
    session = FakeSession.new
    Solana::Transaction.stub :cosign_wire_base64, "SIGNED" do
      flow_for(session).call
    end

    names = session.calls.map(&:first)
    assert_equal :verify_age, names.first
    assert_equal :clear_picks, names[1], "the cart must be cleared before the first toggle"
    assert_equal :toggle_selection, names[2]
    assert_operator names.index(:clear_picks), :<, names.index(:toggle_selection)
  end

  test "every required pick is toggled, in order, then prepared and confirmed" do
    session = FakeSession.new
    Solana::Transaction.stub :cosign_wire_base64, "SIGNED" do
      flow_for(session, picks: [11, 22, 33]).call
    end

    toggles = session.calls.select { |name, _| name == :toggle_selection }.map { |_, p| p[:matchup_id] }
    assert_equal [11, 22, 33], toggles
    assert_includes session.calls.map(&:first), :prepare_entry
    assert_includes session.calls.map(&:first), :confirm_onchain_entry
  end

  # confirm_onchain_entry re-derives the entry PDA and compares. Omitting the
  # echo does not skip that check, it FAILS it — with "Entry PDA mismatch",
  # which reads like a wallet fault rather than a missing field.
  test "confirm echoes back everything prepare handed over" do
    session = FakeSession.new
    Solana::Transaction.stub :cosign_wire_base64, "SIGNED" do
      flow_for(session).call
    end

    _, params = session.calls.find { |name, _| name == :confirm_onchain_entry }
    assert_equal 7, params[:entry_id]
    assert_equal "PDA", params[:entry_pda]
    assert_equal "ptx-1", params[:ptx_slug]
    assert_equal "SIGNED", params[:signed_tx]
  end

  # A toggle that no-ops would otherwise surface much later as "exactly N picks
  # required" from prepare_entry, pointing at the wrong step entirely.
  test "a refused pick fails at the pick, naming it" do
    session = FakeSession.new(toggle_error: "Game has already started")

    error = assert_raises(Flow::EntryError) { flow_for(session).call }

    assert_match(/pick 1 refused/, error.message)
    assert_match(/already started/, error.message)
    refute_includes session.calls.map(&:first), :prepare_entry, "it must not reach prepare"
  end

  test "it refuses to build with fewer matchups than picks required" do
    assert_raises(ArgumentError) do
      Flow.new(session: FakeSession.new, contest_slug: "c", matchup_ids: [1], picks_required: 6)
    end
  end
end
