require "test_helper"

# [unit] The kickoff race (Carl's block on nfl-sunday-morning-lock).
#
# An NFL contest now locks on Sunday, so Thursday, London and Saturday kickoffs
# happen while it is open and each team freezes at its own kickoff. A player
# who submits seconds before one passes the pre-flight, the chain accepts the
# payment (its lock is Sunday), and then the post-broadcast backstop used to
# re-judge the kickoff against NOW and refuse — paid, on chain, never active —
# and every heal re-ran the same check. The time gates of an already-paid entry
# are now judged as of the moment the spend was cleared: the pre-flight on the
# live paths, the transaction's blockTime on the recovery paths.
class Entries::KickoffRaceTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    freeze_time
    @kickoff = Time.current + 5.minutes
    @game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: @kickoff, status: "scheduled")
    slate_matchups(:m1).update!(game_slug: @game.slug)
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
  end

  def cart(**attrs)
    entry = @contest.entries.create!(user: @user, status: :cart, **attrs)
    fixture_matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
    entry
  end

  def past_kickoff! = travel_to(@kickoff + 1.minute)

  test "confirm_onchain! activates a paid entry whose team kicked off after its pre-flight" do
    entry = cart
    entry.assert_enterable!
    preflight_at = Time.current
    past_kickoff!

    control = assert_raises(Entry::Refusal) { entry.confirm_onchain!(tx_signature: "sig-race", entry_pda: "pda-race") }
    assert_equal :team_locked, control.code, "judged at now, the paid entry strands — the defect"

    entry.confirm_onchain!(tx_signature: "sig-race", entry_pda: "pda-race", as_of: preflight_at)
    assert entry.reload.active?
  end

  test "confirm! with a signature activates the same way; without one as_of is ignored" do
    entry = cart
    preflight_at = Time.current
    past_kickoff!

    unpaid = assert_raises(Entry::Refusal) { cart(user: users(:jordan)).confirm!(comped: true, as_of: preflight_at) }
    assert_equal :team_locked, unpaid.code, "no spend, so nothing to honour: judged now"

    entry.confirm!(tx_signature: "sig-race-2", onchain_entry_id: "pda-2", as_of: preflight_at)
    assert entry.reload.active?
  end

  test "the pre-broadcast pre-flight is still judged now, and as_of is never later than now" do
    past_kickoff!

    assert_equal :team_locked, assert_raises(Entry::Refusal) { cart.assert_enterable! }.code
    assert_equal Time.current, Entry.gate_time(1.day.from_now)
    assert_equal Time.current - 1.minute, Entry.gate_time(Time.current - 1.minute)
  end

  test "capacity and duplicate-lineup backstops stay judged now" do
    entry = cart
    preflight_at = Time.current
    enter!(@user, @contest, fixture_matchups) # the same lineup lands in between
    past_kickoff!

    error = assert_raises(Entry::Refusal) { entry.confirm!(tx_signature: "sig-dup", onchain_entry_id: "pda-dup", as_of: preflight_at) }
    assert_equal :duplicate_lineup, error.code
  end

  test "ManagedEntry (browser #enter and the agent API) activates when the kickoff passes during the spend" do
    vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }])
    vault.before_enter = -> { past_kickoff! }
    entry = cart

    outcome = on_chain(vault) do
      Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: false).call(entry)
    end

    assert Time.current > @kickoff
    assert_equal 1, vault.tickets.size
    assert outcome.entry.reload.active?, "paid before kickoff, active after it"
  end

  test "the reconciler heals a stranded row of that shape from the transaction's blockTime" do
    entry = cart(onchain_tx_signature: "sig-strand", onchain_entry_id: "pda-strand", entry_number: 0)
    past_kickoff!
    vault = FakeVault.new
    vault.client.instance_variable_get(:@transactions)["sig-strand"] = { "blockTime" => (@kickoff - 3.seconds).to_i }

    assert_equal :reconciled, Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    assert entry.reload.active?
  end

  test "the reconciler still refuses when the chain says the spend landed after the kickoff, or cannot say" do
    late = cart(onchain_tx_signature: "sig-late", onchain_entry_id: "pda-late", entry_number: 0)
    past_kickoff!
    vault = FakeVault.new
    vault.client.instance_variable_get(:@transactions)["sig-late"] = { "blockTime" => (@kickoff + 10.seconds).to_i }

    assert_not_equal :reconciled, Entries::OnchainReconciler.reconcile_entry(late, vault: vault)
    assert late.reload.cart?

    unknown = cart(user: users(:jordan).tap { |u| make_managed!(u) },
                   onchain_tx_signature: "sig-unknown", onchain_entry_id: "pda-unknown", entry_number: 0)
    assert_not_equal :reconciled, Entries::OnchainReconciler.reconcile_entry(unknown, vault: vault)
    assert unknown.reload.cart?
  end

  test "TxVerifier.block_time reads blockTime and answers nil for anything it cannot read" do
    client = Object.new
    def client.get_transaction(signature, **)
      case signature
      when "with" then { "blockTime" => 1_790_000_000 }
      when "boom" then raise "rpc down"
      end
    end

    assert_equal Time.zone.at(1_790_000_000), Solana::TxVerifier.block_time("with", client: client)
    assert_nil Solana::TxVerifier.block_time("missing", client: client)
    assert_nil Solana::TxVerifier.block_time("boom", client: client)
    assert_nil Solana::TxVerifier.block_time("", client: client)
  end
end
