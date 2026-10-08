require "test_helper"
require "minitest/mock"

# [integration] The kickoff race on the Phantom paths (Carl's block on
# nfl-sunday-morning-lock): #confirm_onchain_entry's pre-flight passes, the
# kickoff passes while the wire is cosigned and broadcast, and the entry must
# still activate; #recover_pending_entry must heal the same row from the
# transaction's blockTime. See test/services/entries/kickoff_race_test.rb for
# the managed and reconciler paths.
class ContestsKickoffRaceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    freeze_time
    SeasonConfig.set_current!(1)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain-race", season_id: 1)
    @user = users(:sam)
    @user.update!(web3_solana_address: "Web3Race#{SecureRandom.hex(4)}")
    @kickoff = Time.current + 5.minutes
    game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: @kickoff, status: "scheduled")
    slate_matchups(:m1).update!(game_slug: game.slug)
    @entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    %i[m1 m2 m3 m4 m5 m6].each { |name| @entry.selections.create!(slate_matchup: slate_matchups(name)) }
  end

  def pda = "epda-#{@contest.slug}-#{@user.reload.web3_solana_address[0, 4]}-0" # after any login rewrote the wallet

  def on_fake_chain(vault, &block)
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true, &block
      end
    end
  end

  test "confirm_onchain_entry activates when the team kicks off during the broadcast" do
    log_in_as_onchain(@user)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "pending",
                               target: @entry, initiator_address: @user.reload.web3_solana_address,
                               metadata: { entry_pda: pda }.to_json)
    vault = FakeVault.new
    vault.sync_balance_seeds = 100
    test = self
    kickoff = @kickoff
    broadcast = vault.method(:cosign_and_broadcast_entry)
    vault.define_singleton_method(:cosign_and_broadcast_entry) do |*args, **kwargs|
      broadcast.call(*args, **kwargs).tap { test.travel_to(kickoff + 1.minute) } # the kickoff passes mid-flight
    end

    on_fake_chain(vault) do
      post confirm_onchain_entry_contest_path(@contest),
           params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: @entry.id, entry_pda: pda }, as: :json
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert Time.current > @kickoff
    assert @entry.reload.active?, "paid before the kickoff, active after it"
  end

  test "recover_pending_entry heals the stranded row from the transaction's blockTime, and refuses a late one" do
    log_in_as @user
    ptx = PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "submitted",
                                     tx_signature: "sig-race-recover", target: @entry,
                                     initiator_address: @user.web3_solana_address,
                                     metadata: { entry_pda: pda }.to_json)
    travel_to(@kickoff + 1.minute)
    vault = FakeVault.new(signature_statuses: { "sig-race-recover" => { "err" => nil, "confirmationStatus" => "finalized" } })
    transactions = vault.client.instance_variable_get(:@transactions)

    transactions["sig-race-recover"] = { "blockTime" => (@kickoff + 5.seconds).to_i }
    on_fake_chain(vault) { post recover_pending_entry_contest_path(@contest), params: { ptx_slug: ptx.slug }, as: :json }
    # Landed after the kickoff: still not credited. But the payment LANDED, so
    # the entry gate's refusal is no verdict on it — the wire stays submitted
    # and the 409 stands, rather than freeing a second paying wire
    # (recovery-never-fails-landed-entries). The entry is HELD (`landed`) and
    # the player is told so, with where to go; an operator resolves it.
    held = JSON.parse(response.body)
    assert_equal "held", held["status"], "landed after the kickoff: still refused"
    assert_match(/payment for this contest arrived.*contact support@turfmonster.media/, held["error"])
    assert @entry.reload.cart?
    assert_equal %w[landed team_locked], @entry.values_at(:payment_state, :payment_refusal_code)
    assert_equal "submitted", ptx.reload.status
    transactions["sig-race-recover"] = { "blockTime" => (@kickoff - 5.seconds).to_i }
    on_fake_chain(vault) { post recover_pending_entry_contest_path(@contest), params: { ptx_slug: ptx.slug }, as: :json }
    assert_equal "confirmed", JSON.parse(response.body)["status"]
    assert @entry.reload.active?
  end
end
