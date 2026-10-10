require "test_helper"
require "minitest/mock"

# [integration] Two POST /contests/:slug/enter for ONE player, contest and cart,
# with the second arriving while the first is still inside its request (task
# board-hold-enters-once: a board that answered one hold twice sent exactly
# this). The claim: the second is refused with a 4xx and a sentence, and one
# payment exists.
#
# Non-transactional, on real connections: each request runs on its own thread
# and its own database connection, so the row lock and the unique in-flight key
# (index_entries_one_payment_in_flight) are the ones Postgres enforces, and a
# write one request commits is what the other reads. The chain is LedgerVault,
# held open at the moment under test; a ticket exists there iff a payment
# landed. The model's own races are test/models/entry_payment_concurrency_test.rb;
# the sequential double click is test/controllers/contests_entry_payment_test.rb.
class ContestsEnterDuplicateRequestTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  self.use_transactional_tests = false

  # LedgerVault, with one more place to stop: after this attempt's signature is
  # recorded on the row and before the wire lands.
  class HeldVault < LedgerVault
    attr_accessor :after_sign

    private

    def land!(wallet, slug, slot, method, before_send = nil)
      signed = before_send && lambda do |signature, ceiling|
        before_send.call(signature, ceiling)
        hook, self.after_sign = after_sign, nil
        hook&.call
      end
      super(wallet, slug, slot, method, signed)
    end
  end

  PENDING_SENTENCE = /still confirming.*not be charged twice/i

  setup do
    @high_water = high_water_marks
    @season_before = SeasonConfig.first&.current_season_id
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = HeldVault.new(tokens: [], usdc: 100.0)
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
    @first = session_for(@user)
    @second = session_for(@user)
  end

  # Nothing rolls back here, so every row this test adds is removed by hand:
  # fixture tables are reloaded for the next test, and the rest return to the
  # ids they held at setup.
  teardown do
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      @high_water.each do |table, max_id|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{max_id.to_i}")
      end
    end
    SeasonConfig.first&.update_columns(current_season_id: @season_before) # the one row this test edits in place
  end

  def high_water_marks
    connection = ActiveRecord::Base.connection
    (connection.tables - %w[schema_migrations ar_internal_metadata]).filter_map do |table|
      next unless connection.columns(table).any? { |column| column.name == "id" && column.type == :integer }

      [table, connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i]
    end.to_h
  end

  # One browser tab's worth of cookies, signed in as `user`.
  def session_for(user)
    open_session.tap do |tab|
      tab.post tab.magic_link_consume_path(token: Studio::Link.create_magic_link(email: user.email).token)
    end
  end

  def chain(&block) = AppFlags.stub(:web2_usdc_entry?, true) { on_chain(@vault, &block) }

  def enter(tab)
    tab.post tab.enter_contest_path(@contest), as: :json
    [tab.response.status, (JSON.parse(tab.response.body) rescue {})]
  end

  # Run the first request on its own thread and stop it where `hold_at` says
  # (a writer on the vault that takes a single-use hook). Yields while it is
  # stopped, then lets it finish and returns its [status, body].
  def with_first_request_held(hold_at)
    inside = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)
    fired = false
    @vault.public_send(hold_at, lambda do
      next if fired # LedgerVault keeps before_enter set; only the first request stops

      fired = true
      inside.count_down
      release.wait(15)
    end)
    first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { enter(@first) } }
    assert inside.wait(15), "the first request never reached the hold point"
    yield
    release.count_down
    first.value
  ensure
    release&.count_down
    first&.join(15)
  end

  def fee_dollars = @contest.entry_fee_cents / 100.0

  def assert_one_payment
    assert_equal 1, @vault.enter_calls.size, "exactly one attempt reached the vault"
    assert_equal 1, @vault.tickets.size, "exactly one ticket exists"
    assert_in_delta 100.0 - fee_dollars, @vault.usdc_balance, 0.001, "the wallet paid one fee"
    assert_equal 1, @contest.entries.where(user: @user).where.not(status: :cart).count
    assert_equal %w[active confirmed], @entry.reload.values_at(:status, :payment_state)
  end

  def assert_refused_in_flight(status, body)
    assert_equal 409, status
    assert_equal ["entry_pending", @entry.slug, false, false], body.values_at("code", "entry", "success", "retry")
    assert_match PENDING_SENTENCE, body["error"]
  end

  test "the second arrives while the first is at the vault, before its signature is recorded" do
    second = nil
    during = nil
    first = chain do
      with_first_request_held(:before_enter=) do
        second = enter(@second)
        during = [@entry.reload.payment_state, @entry.payment_signature, @vault.enter_calls.size, @vault.tickets.size]
      end
    end

    assert_refused_in_flight(*second)
    assert_equal ["submitted", nil, 1, 0], during, "the refusal left the first attempt's row and the vault alone"
    assert_equal [200, true], [first[0], first[1]["success"]], "the first request still completes"
    assert_one_payment
  end

  test "the second arrives after the first signed and before its wire landed" do
    second = nil
    during = nil
    first = chain do
      with_first_request_held(:after_sign=) do
        second = enter(@second)
        during = [@entry.reload.payment_state, @entry.payment_signature, @vault.enter_calls.size, @vault.tickets.size]
      end
    end

    assert_refused_in_flight(*second)
    assert_equal ["submitted", "ledger-sig-1", 1, 0], during
    assert_equal [200, true], [first[0], first[1]["success"]]
    assert_one_payment
  end

  # Both requests are past the controller's "is a payment in flight?" question
  # before either has begun a charge: the first is stopped inside the slot pin,
  # holding the entry's row lock, and the second waits on that lock.
  test "both pass the in-flight check before either charges: one pays, one is refused" do
    second_thread = nil
    first = chain do
      with_first_request_held(:before_slot_probe=) do
        second_thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { enter(@second) } }
        sleep 0.5 # long enough for the second to reach the row lock the first holds
        assert second_thread.alive?, "the second request is waiting on the first's row lock"
        assert_equal "draft", @entry.reload.payment_state
      end
    end
    second = second_thread.value

    paid, refused = [first, second].partition { |status, _| status == 200 }
    assert_equal 1, paid.size, "exactly one request paid: #{[first, second].map(&:first).inspect}"
    assert_equal true, paid.first[1]["success"]
    assert_refused_in_flight(*refused.first)
    assert_one_payment
  ensure
    second_thread&.join(15)
  end

  # The late duplicate finds no cart. It is told the entry is in, as JSON: 409
  # with the reason, never a redirect. It claims no success and charges nothing.
  test "CONTROL: one request alone pays once, and a duplicate that arrives after it finished charges nothing" do
    first = chain { enter(@first) }
    assert_equal [200, true], [first[0], first[1]["success"]]
    assert_one_payment

    status, body = chain { enter(@second) }
    assert_equal [409, "entry_confirmed", false], [status, body["code"], body["success"]]
    assert_match(/not charged again/i, body["error"])
    assert_one_payment
  end
end
