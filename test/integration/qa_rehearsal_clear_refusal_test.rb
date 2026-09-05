# frozen_string_literal: true

require "test_helper"

# EntryFlow across its ONE external boundary — HTTP — with the transport, and
# only the transport, replaced. WalletSession is real here: its CSRF fetch, its
# cookie jar, its status handling and its JSON parsing all run, because the
# defect this pins lives in the seam BETWEEN the two classes and is invisible
# from either side alone.
#
# The seam: WalletSession#post_json returns whatever came back and raises on
# nothing but unparseable JSON, so a 422 arrives at EntryFlow as an ordinary
# Hash. EntryFlow#clear_cart used to discard that Hash. Neither class was
# wrong by itself; together they let a refused clear pass for a clear that
# worked, and a probe ran the whole flow to confirm_onchain_entry while
# clear_picks refused every single time.
#
# The canned bodies are shaped from ContestsController#clear_picks, not from
# the driver: `render json: { success: true }` on the happy path, and
# `render json: { success: false, error: e.message },
#  status: :unprocessable_entity` from its rescue.
class QaRehearsalClearRefusalTest < ActiveSupport::TestCase
  Flow = TurfMonster::QaRehearsal::EntryFlow
  Session = TurfMonster::QaRehearsal::WalletSession

  CSRF_PAGE = %(<html><head><meta name="csrf-token" content="tok"></head></html>)

  # Answers like the app does, and records the path of every request that
  # reaches the wire — which is how "it never got as far as toggling" is
  # asserted rather than assumed.
  class FakeTransport
    attr_reader :paths

    def initialize(clear:)
      @clear = clear
      @paths = []
      @selected = 0
    end

    def request(req)
      @paths << req.path

      case req.path
      when "/" then response("200", CSRF_PAGE, type: "text/html")
      when "/age/verify" then response("200", { verified: true }.to_json)
      when %r{/clear_picks\z}
        # An ACCEPTED clear empties the cart; a refused one leaves it alone.
        # That difference is the point of the whole flow step.
        @selected = 0 if @clear.fetch(:code) == "200"
        response(@clear.fetch(:code), @clear.fetch(:body))
      when %r{/toggle_selection\z}
        @selected += 1
        response("200", { selections: {}, selection_count: @selected }.to_json)
      when %r{/prepare_entry\z}
        response("200", { success: true, serialized_tx: "AA==", entry_id: 7,
                          entry_pda: "PDA", ptx_slug: "ptx-1" }.to_json)
      when %r{/confirm_onchain_entry\z}
        response("200", { success: true, tx_signature: "SIG" }.to_json)
      else
        raise "unexpected request to #{req.path}"
      end
    end

    private

    def response(code, body, type: "application/json")
      # CODE_TO_OBJ rather than a named constant: 422's class was renamed in
      # Ruby 3.4 (UnprocessableEntity -> UnprocessableContent) and the lookup
      # table is stable across both.
      klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
      res = klass.new("1.1", code, nil)
      res["Content-Type"] = type
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end
  end

  class FakeKeypair
    def to_base58 = "CastMemberPubkey11111111111111111111111111"
  end

  def with_transport(transport)
    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(transport) }) do
      yield
    end
  end

  def session_for(transport)
    Session.new(host: "localhost:3118", keypair: FakeKeypair.new, scheme: "http")
  end

  def flow_for(session)
    Flow.new(session: session, contest_slug: "c", matchup_ids: [1, 2, 3], picks_required: 3)
  end

  REFUSAL = { code: "422",
              body: { success: false, error: "Entry is locked" }.to_json }.freeze

  # THE PREMISE, asserted rather than assumed: a 422 does not raise on its way
  # out of WalletSession. If this ever stops being true the guard in
  # EntryFlow#clear_cart becomes dead code, and the test below would keep
  # passing for the wrong reason.
  test "a 422 comes back through WalletSession as a plain parsed body" do
    transport = FakeTransport.new(clear: REFUSAL)
    session = session_for(transport)

    body = with_transport(transport) { session.post_json("/contests/c/clear_picks") }

    assert_equal({ "success" => false, "error" => "Entry is locked" }, body)
  end

  test "a refused clear stops the flow at the clear" do
    transport = FakeTransport.new(clear: REFUSAL)

    error = assert_raises(Flow::EntryError) do
      with_transport(transport) { flow_for(session_for(transport)).call }
    end

    assert_match(/clear_picks refused/, error.message)
    assert_match(/Entry is locked/, error.message)
    assert_includes transport.paths, "/contests/c/clear_picks"
    assert_empty transport.paths.grep(%r{toggle_selection}),
                 "it must not build picks onto a cart the server refused to clear"
    assert_empty transport.paths.grep(%r{prepare_entry})
  end

  # The other half of the guard: the shape the app returns when the clear
  # WORKED must sail straight through. clear_picks answers `{ success: true }`
  # whether or not there was a cart to clear, and this step is the one an
  # operator re-runs after a failure.
  test "an accepted clear lets the flow proceed to the picks" do
    transport = FakeTransport.new(clear: { code: "200", body: { success: true }.to_json })

    with_transport(transport) do
      Solana::Transaction.stub :cosign_wire_base64, "SIGNED" do
        flow_for(session_for(transport)).call
      end
    end

    assert_operator transport.paths.index("/contests/c/clear_picks"), :<,
                    transport.paths.index { |p| p.include?("toggle_selection") }
  end
end
