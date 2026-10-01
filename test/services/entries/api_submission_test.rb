require "test_helper"

# [unit] Entries::ApiSubmission: one entry per Idempotency-Key, one spend per
# entry, whatever the request, the chain or the database does in between.
#
# Every test counts spends on LedgerVault, which keeps the chain's own books:
# a consumed token stays consumed and a ticket stays on chain. "One spend" is
# `vault.tickets.size == 1`, never "the method was called once".
# Makes Entry#assert_enterable! raise on its Nth call while armed, and is inert
# otherwise. Minitest has no any-instance stub, and the entry under test is
# built inside the service, so there is no instance to stub from outside.
module FailingBackstop
  mattr_accessor :remaining

  def self.arm!(on_call:)
    self.remaining = on_call
    yield
  ensure
    self.remaining = nil
  end

  def assert_enterable!(**options)
    if FailingBackstop.remaining
      FailingBackstop.remaining -= 1
      raise ActiveRecord::StatementInvalid, "simulated database failure" if FailingBackstop.remaining.zero?
    end
    super
  end
end
Entry.prepend(FailingBackstop)

class Entries::ApiSubmissionTest < ActiveSupport::TestCase
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @picks = fixture_matchups.map(&:id)
    @vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }])
  end

  def submit(key: "key-1", picks: @picks, allow_usdc: false, user: @user)
    on_chain(@vault) do
      Entries::ApiSubmission.new(user: User.find(user.id), contest: Contest.find(@contest.id),
                                 matchup_ids: picks, allow_usdc: allow_usdc, idempotency_key: key,
                                 serializer: ->(entry) { { slug: entry.slug, status: entry.status } }).call
    end
  end

  def record(key = "key-1")
    ApiEntryRequest.find_by!(user: @user, idempotency_key: key)
  end

  def entries
    @contest.entries.where(user: @user)
  end

  def assert_error(result, code, status)
    assert_equal code, result.error_code, result.message
    assert_equal status, result.status
  end

  def assert_nothing_spent
    assert_empty @vault.tickets, "a ticket exists on chain"
    assert_empty @vault.spent_tokens, "a token was consumed"
    assert_empty entries, "an entry row was left behind"
  end

  # ── the happy path and what it writes ─────────────────────────────────────

  test "a first request spends one token and returns the active entry" do
    result = submit

    assert_equal :created, result.status
    assert_not result.replayed
    entry = entries.sole
    assert entry.active?
    assert_equal({ "slug" => entry.slug, "status" => "active" }, result.body["entry"])
    assert_equal({ "method" => "token", "token_consumed" => true }, result.body["funding"])
    assert_equal @vault.tickets.sole[:signature], entry.onchain_tx_signature
    assert_equal @vault.tickets.sole[:pda], entry.onchain_entry_id
    assert_equal 1, @vault.spent_tokens.size

    row = record
    assert_equal ["succeeded", entry.id, 201, "token", true],
                 [row.state, row.entry_id, row.response_status, row.funding_method, row.token_consumed]
    assert_equal result.body, JSON.parse(row.response_body)
  end

  # ── succeeded: replay ─────────────────────────────────────────────────────

  test "succeeded: the same key replays the first response and spends nothing more" do
    first = submit
    @vault.grant_token("token-2")

    again = submit

    assert_equal :created, again.status
    assert again.replayed
    assert_equal first.body, again.body
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, entries.count
    assert_equal 1, record.attempts, "a replay is not an attempt"
  end

  test "succeeded: the replay is the FIRST response even after the entry has changed" do
    first = submit
    entries.sole.update_columns(status: "complete")

    assert_equal "active", submit.body.dig("entry", "status")
    assert_equal first.body, submit.body
  end

  test "the same picks in another order are the same request" do
    submit
    again = submit(picks: @picks.reverse)

    assert again.replayed
    assert_equal 1, @vault.tickets.size
  end

  test "the same key with different picks is refused and spends nothing" do
    submit
    @vault.grant_token("token-2")
    other = (@picks.first(5) + [extra_matchups.first.id])

    assert_error submit(picks: other), :idempotency_key_reused, :conflict
    assert_error submit(allow_usdc: true), :idempotency_key_reused, :conflict
    assert_equal 1, @vault.tickets.size
    assert_equal 1, entries.count
  end

  test "a key belongs to its player: another player's same key is a separate request" do
    submit
    other = make_managed!(users(:jordan))
    @vault.grant_token("token-2")

    result = submit(user: other)

    assert_equal :created, result.status
    assert_not result.replayed
    assert_equal 2, @vault.tickets.size
  end

  # ── failed: nothing spent, retry runs again ───────────────────────────────

  test "failed: a refusal before any spend leaves the key free to run again" do
    @vault = LedgerVault.new(tokens: [])

    assert_error submit, :no_entry_token, :unprocessable_entity
    assert_nothing_spent
    assert_equal %w[failed no_entry_token], [record.state, record.last_error_code]

    @vault.grant_token("token-late")
    result = submit

    assert_equal :created, result.status
    assert_equal 1, @vault.tickets.size
    assert_equal ["succeeded", 2], [record.state, record.attempts]
  end

  test "failed: a transaction the chain rejected moved nothing, and the retry may spend" do
    @vault.fail_next_enter = :rejected

    assert_error submit, :contest_full, :unprocessable_entity
    assert_nothing_spent
    assert_equal "failed", record.state

    assert_equal :created, submit.status
    assert_equal 1, @vault.tickets.size
  end

  test "failed: an unreadable token list is chain_unavailable, not 'no token'" do
    @vault.token_read_raises = true

    result = submit(allow_usdc: true)

    assert_error result, :chain_unavailable, :service_unavailable
    assert_nothing_spent
    assert_empty @vault.balance_calls, "USDC must not be considered while the token read is unknown"
    assert_equal "failed", record.state
  end

  # ── executing: a concurrent duplicate ─────────────────────────────────────

  test "executing: a duplicate arriving while the first is in flight is told to wait and spends nothing" do
    nested = []
    @vault.before_enter = lambda do
      @vault.before_enter = nil
      nested << submit                                   # the same key, mid-flight
      nested << submit(key: "key-2")                     # a second key, same contest
    end

    outer = submit

    assert_equal :created, outer.status
    nested.each { |result| assert_error result, :idempotency_in_progress, :conflict }
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, entries.count
    assert_nil ApiEntryRequest.find_by(user: @user, idempotency_key: "key-2"), "the blocked key recorded nothing"
  end

  test "executing: once the first finishes, the duplicate gets its result" do
    submit
    assert submit.replayed
  end

  # ── uncertain: the response was lost after the spend ──────────────────────

  test "uncertain: the spend landed and the answer was lost; the retry adopts it and never pays twice" do
    @vault.fail_next_enter = :lost
    @vault.grant_token("token-2")

    first = submit

    assert_error first, :chain_unavailable, :service_unavailable
    assert_equal 1, @vault.tickets.size, "the spend landed"
    assert_empty entries, "the lock transaction rolled back, so no row"
    assert_equal "uncertain", record.state

    again = submit

    assert_equal :created, again.status
    entry = entries.sole
    assert entry.active?
    assert_equal @vault.tickets.sole[:signature], entry.onchain_tx_signature
    assert_equal @picks.sort, entry.selections.pluck(:slate_matchup_id).sort
    assert_equal 1, @vault.tickets.size, "no second ticket"
    assert_equal 1, @vault.spent_tokens.size, "token-2 is untouched"
    assert_equal({ "method" => "token", "token_consumed" => true }, again.body["funding"])
    assert_equal "succeeded", record.state

    assert submit.replayed
    assert_equal 1, @vault.tickets.size
  end

  test "uncertain: nothing landed yet, so the retry waits rather than spends" do
    @vault.fail_next_enter = :unlanded

    assert_error submit, :chain_unavailable, :service_unavailable
    assert_nothing_spent

    waiting = submit

    assert_error waiting, :chain_unavailable, :service_unavailable
    assert_operator waiting.retry_after, :>, 0
    assert_operator waiting.retry_after, :<=, ApiEntryRequest::SETTLE_WINDOW
    assert_nothing_spent
    assert_empty @vault.enter_calls.drop(1), "no second broadcast inside the settle window"
    assert_equal "uncertain", record.state
  end

  test "uncertain: once the transaction can no longer land, the retry spends exactly once" do
    @vault.fail_next_enter = :unlanded
    submit

    travel ApiEntryRequest::SETTLE_WINDOW + 1.second do
      result = submit

      assert_equal :created, result.status
      assert_equal 1, @vault.tickets.size
      assert_equal 1, @vault.spent_tokens.size
      assert entries.sole.active?
    end
  end

  test "uncertain: if the chain cannot be read, nothing is assumed and nothing is spent" do
    @vault.fail_next_enter = :lost
    submit
    probe_down = LedgerVault.new(tokens: [{ pda: "token-9", consumed: false }], account_info_raises: true)

    result = travel(ApiEntryRequest::SETTLE_WINDOW + 1.second) do
      on_chain(probe_down) do
        Entries::ApiSubmission.new(user: @user, contest: @contest, matchup_ids: @picks, allow_usdc: false,
                                   idempotency_key: "key-1", serializer: ->(entry) { { slug: entry.slug } }).call
      end
    end

    assert_error result, :chain_unavailable, :service_unavailable
    assert_empty probe_down.tickets
    assert_empty probe_down.spent_tokens
    assert_equal "uncertain", record.state
  end

  test "uncertain: a NEW key does not escape the doubt; the lost spend is adopted first" do
    @vault.fail_next_enter = :lost
    @vault.grant_token("token-2")
    submit

    same_lineup = submit(key: "key-2")

    assert_error same_lineup, :duplicate_lineup, :unprocessable_entity
    assert_equal 1, @vault.tickets.size, "the second key must not buy the same lineup again"
    assert entries.sole.active?, "the first key's entry was built on the ticket it paid for"
    assert_equal entries.sole.id, record("key-1").entry_id

    assert_equal :created, submit.status, "and the first key now finds it"
    assert_equal 1, @vault.tickets.size
  end

  test "uncertain: a new key for a different lineup waits while the first spend could still land" do
    @vault.fail_next_enter = :unlanded
    @vault.grant_token("token-2")
    submit
    other = @picks.first(5) + [extra_matchups.first.id]

    waiting = submit(key: "key-2", picks: other)

    assert_error waiting, :chain_unavailable, :service_unavailable
    assert_nothing_spent
    assert_equal "failed", record("key-2").state, "the new key spent nothing and may simply run again"

    travel ApiEntryRequest::SETTLE_WINDOW + 1.second do
      assert_equal :created, submit(key: "key-2", picks: other).status
      assert_equal 1, @vault.tickets.size
      assert_equal %w[failed unspent], [record("key-1").state, record("key-1").last_error_code]
    end
  end

  # ── executing, abandoned: the process died mid-request ────────────────────

  def abandon!(key = "key-1")
    ApiEntryRequest.create!(user: @user, contest: @contest, idempotency_key: key, matchup_ids: @picks,
                            fingerprint: ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: @picks, allow_usdc: false),
                            state: "executing", attempts: 1, attempted_at: Time.current)
  end

  test "abandoned: a request that died is held as in-flight, then read as uncertain" do
    abandon!

    assert_error submit, :idempotency_in_progress, :conflict

    travel ApiEntryRequest::IN_FLIGHT_TIMEOUT + 1.second do
      assert_error submit, :chain_unavailable, :service_unavailable
      assert_nothing_spent
    end

    travel ApiEntryRequest::IN_FLIGHT_TIMEOUT + ApiEntryRequest::SETTLE_WINDOW + 2.seconds do
      assert_equal :created, submit.status
      assert_equal 1, @vault.tickets.size
    end
  end

  test "abandoned: a request that died AFTER its spend landed is adopted, not repeated" do
    abandon!
    on_chain(@vault) do
      @vault.enter_contest_with_token(@user.web2_solana_address, @contest.slug, 0, "token-1",
                                      user_keypair: "fake-keypair-object", season_id: 1)
    end
    @vault.grant_token("token-2")

    result = travel(ApiEntryRequest::IN_FLIGHT_TIMEOUT + 1.second) { submit }

    assert_equal :created, result.status
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal @vault.tickets.sole[:signature], entries.sole.onchain_tx_signature
  end

  test "abandoned: a request that died after the lock committed, before the proof was written, is finished from the chain" do
    row = abandon!
    on_chain(@vault) do
      @vault.enter_contest_with_token(@user.web2_solana_address, @contest.slug, 0, "token-1",
                                      user_keypair: "fake-keypair-object", season_id: 1)
    end
    paid = enter!(@user, @contest, fixture_matchups, status: :cart)
    paid.update!(entry_number: 0)
    row.update!(entry: paid)
    @vault.grant_token("token-2")

    result = travel(ApiEntryRequest::IN_FLIGHT_TIMEOUT + 1.second) { submit }

    assert_equal :created, result.status
    assert_equal [paid.id], entries.pluck(:id)
    assert paid.reload.active?
    assert_equal @vault.tickets.sole[:signature], paid.onchain_tx_signature
    assert_equal 1, @vault.spent_tokens.size
    assert_equal({ "method" => "unknown", "token_consumed" => nil }, result.body["funding"])
  end

  # ── confirming: paid, the confirming write failed ─────────────────────────

  def with_failing_confirm(&block)
    boom = ->(*, **) { raise ActiveRecord::StatementInvalid, "simulated post-broadcast DB failure" }
    TransactionLog.stub :record!, boom, &block
  end

  test "confirming: the spend landed and confirm failed; the answer is 202 and the reconcile job is queued" do
    result = nil
    assert_enqueued_with(job: Entries::OnchainReconcileJob) do
      with_failing_confirm { result = submit }
    end

    assert_equal :accepted, result.status
    assert_equal({ "entry" => nil, "funding" => { "method" => "token", "token_consumed" => true },
                   "pending" => true, "retry_after" => 5 }, result.body)
    entry = entries.sole
    assert entry.cart?
    assert_equal @vault.tickets.sole[:signature], entry.onchain_tx_signature
    assert_equal ["confirming", entry.id], [record.state, record.entry_id]
  end

  test "confirming: the retry finishes the SAME entry and spends nothing more" do
    with_failing_confirm { submit }
    @vault.grant_token("token-2")
    paid = entries.sole

    result = submit

    assert_equal :created, result.status
    assert_equal paid.id, entries.sole.id
    assert entries.sole.active?
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal "succeeded", record.state
  end

  test "confirming: the reconcile job and the retry converge on one entry" do
    with_failing_confirm { submit }
    @vault.grant_token("token-2")

    on_chain(@vault) { Entries::OnchainReconcileJob.perform_now(entries.sole.id) }
    assert entries.sole.active?

    result = submit

    assert_equal :created, result.status
    assert_equal 1, entries.count
    assert_equal 1, @vault.tickets.size
    assert_equal 1, TransactionLog.where(user: @user, transaction_type: "entry_fee").count
  end

  test "confirming: while the confirm keeps failing, every retry is 202 and nothing more is spent" do
    with_failing_confirm do
      submit
      @vault.grant_token("token-2")

      assert_equal :accepted, submit.status
      assert_equal 1, @vault.tickets.size
      assert_equal 1, entries.count
    end
  end

  # ── token only by default ─────────────────────────────────────────────────

  test "no token and no allow_usdc: refused, with USDC in the wallet untouched" do
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)

    AppFlags.stub :web2_usdc_entry?, true do
      assert_error submit, :no_entry_token, :unprocessable_entity
    end

    assert_nothing_spent
    assert_equal 100.0, @vault.usdc_balance
    assert_empty @vault.balance_calls
  end

  test "allow_usdc: no token, enough USDC, the fee is paid in USDC" do
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)

    result = AppFlags.stub(:web2_usdc_entry?, true) { submit(allow_usdc: true) }

    assert_equal :created, result.status
    assert_equal({ "method" => "usdc", "token_consumed" => false }, result.body["funding"])
    assert_equal :usdc, @vault.tickets.sole[:method]
    assert_in_delta 81.0, @vault.usdc_balance
  end

  test "allow_usdc: a token is still spent first" do
    @vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }], usdc: 100.0)

    result = AppFlags.stub(:web2_usdc_entry?, true) { submit(allow_usdc: true) }

    assert_equal({ "method" => "token", "token_consumed" => true }, result.body["funding"])
    assert_equal 100.0, @vault.usdc_balance
  end

  test "allow_usdc: not enough USDC is insufficient_funds and nothing moves" do
    @vault = LedgerVault.new(tokens: [], usdc: 5.0)

    result = AppFlags.stub(:web2_usdc_entry?, true) { submit(allow_usdc: true) }

    assert_error result, :insufficient_funds, :unprocessable_entity
    assert_nothing_spent
    assert_equal 5.0, @vault.usdc_balance
  end

  test "allow_usdc: with USDC entry switched off for the site, it is still no_entry_token" do
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)

    result = AppFlags.stub(:web2_usdc_entry?, false) { submit(allow_usdc: true) }

    assert_error result, :no_entry_token, :unprocessable_entity
    assert_match(/not available right now/, result.message)
    assert_nothing_spent
  end

  test "a free contest needs no token and spends nothing" do
    @contest.update!(entry_fee_cents: 0, onchain_contest_id: nil)
    @vault = LedgerVault.new(tokens: [])

    result = submit

    assert_equal :created, result.status
    assert_equal({ "method" => "free", "token_consumed" => false }, result.body["funding"])
    assert entries.sole.active?
    assert_empty @vault.tickets
    assert_empty @vault.entry_token_list_calls
  end

  test "a free entry whose confirm fails leaves no row behind, and the retry makes one entry" do
    @contest.update!(entry_fee_cents: 0, onchain_contest_id: nil)

    # The gate passes inside the lock and fails as confirm!'s backstop: the
    # entry row is committed, never activated, and there is no payment to honour.
    FailingBackstop.arm!(on_call: 2) do
      assert_raises(ActiveRecord::StatementInvalid) { submit }
    end

    assert_empty entries, "a failed request must not leave a half-made entry"
    assert_equal ["failed", nil], [record.state, record.entry_id]

    assert_equal :created, submit.status
    assert entries.sole.active?
  end

  # ── the player's web cart ─────────────────────────────────────────────────

  test "the player's web cart is neither submitted nor changed by an API entry" do
    cart = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.first(2).each { |matchup| cart.selections.create!(slate_matchup: matchup) }
    before = cart.attributes

    submit

    cart.reload
    assert cart.cart?
    assert_equal before.except("updated_at"), cart.attributes.except("updated_at")
    assert_equal 2, cart.selections.count
    assert_equal 1, entries.where(status: :active).count
    assert_not_equal cart.id, record.entry_id
  end

  test "a refused request leaves the web cart alone and creates no row of its own" do
    cart = @contest.entries.create!(user: @user, status: :cart)
    @vault = LedgerVault.new(tokens: [])

    submit

    assert_equal [cart.id], entries.pluck(:id)
    assert cart.reload.cart?
  end

  # ── side effects of a web entry happen here too ───────────────────────────

  test "a confirmed API entry announces the join and nudges the level-up mint" do
    nudges = []
    @vault.sync_balance_seeds = 75

    LevelUpTokenMintJob.stub :nudge, ->(user, seeds_total:) { nudges << [user.id, seeds_total] } do
      submit
    end

    assert_equal [[@user.id, 75]], nudges
    assert_equal 1, TransactionLog.where(user: @user, transaction_type: "entry_fee").count
    assert_equal 1, Message.where(contest: @contest, user: @user, system: true).count
  end
end
