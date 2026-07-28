require "test_helper"
require "minitest/mock"

# Username quest — the FIRST manual (on-chain) username change pays a one-time
# seed bonus.
#
# HARDENING ("things you can't do"): the controller returns a seeds payload only
# on the first change; a second rename pays nothing. And the plain account update
# CANNOT change the username — so the on-chain rename + the can_change_username?
# gate + the once-ever seed marker can't be bypassed via PATCH /account. See
# AccountsController#update_username / #update and the private
# #grant_first_username_seeds. (The seed AMOUNT is Season-configured on-chain;
# FakeVault#seeds_for_quest returns 25 here.)
class AccountsUsernameSeedsTest < ActionDispatch::IntegrationTest
  setup do
    # Managed-wallet user (custodial co-sign path: not Phantom, not
    # self-custodied) that has entered a contest, so can_change_username? holds.
    @user = User.create!(email: "renamer-seeds@mcritchie.studio")
    @user.update_columns(contest_entered: true)
    assert @user.managed_wallet?, "email signup should auto-generate a managed wallet"
  end

  test "the FIRST username change returns the seed payload and stamps username_changed_at" do
    log_in_as @user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post update_username_account_path, params: { value: "renamed-first" }, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert_equal "saved", body["status"]
    assert_equal "renamed-first", @user.reload.username
    assert_equal 25, body["seeds_earned"], "the first rename pays the quest bonus"
    assert @user.username_changed_at.present?, "the once-ever marker is stamped"
    assert_equal 1, fake.grant_calls.length
    assert_equal :username, fake.grant_calls.first[:kind]
  end

  test "a SECOND username change pays no seeds (once-ever)" do
    log_in_as @user
    fake = FakeVault.new
    Solana::Vault.stub :new, fake do
      post update_username_account_path, params: { value: "renamed-first" }, as: :json
      assert_equal 25, response.parsed_body["seeds_earned"]

      post update_username_account_path, params: { value: "renamed-second" }, as: :json
      assert_response :success
      body = response.parsed_body
      assert_equal "saved", body["status"]
      assert_equal "renamed-second", @user.reload.username, "the rename itself still applies"
      assert_nil body["seeds_earned"], "the username bonus only fires once"
    end
    assert_equal 1, fake.grant_calls.length, "exactly one grant across two renames"
  end

  test "an already-existing on-chain username grant returns a seed snapshot for navbar reconciliation" do
    log_in_as @user
    fake = FakeVault.new
    fake.grant_seeds_error = RuntimeError.new(
      "Transaction simulation failed: Error processing Instruction 0: custom program error: 0x0"
    )
    fake.sync_balance_seeds = 460

    Solana::Vault.stub :new, fake do
      post update_username_account_path, params: { value: "renamed-snapshot" }, as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "saved", body["status"]
    assert_equal "renamed-snapshot", @user.reload.username
    assert_nil body["seeds_earned"], "a duplicate on-chain grant must not claim a fresh award"
    assert_equal 460, body["seeds_total"], "the client can reconcile the navbar from the latest total"
    assert_equal User.level_for(460), body["seeds_level"]
    assert_equal true, body["seeds_reconciled"]
    assert @user.username_changed_at.present?, "the username quest still completes"
    assert_equal 1, fake.grant_calls.length
  end

  test "the plain account update cannot change the username (off-chain bypass blocked)" do
    # account_params permits only :name and :email — a username smuggled through
    # PATCH /account is dropped, so it can't bypass the on-chain rename, the
    # can_change_username? gate, or the once-ever seed marker.
    log_in_as @user
    original = @user.username

    patch account_path, params: { user: { username: "smuggled-name", name: "Keep Me" } }

    @user.reload
    assert_equal original, @user.username, "username is not settable via the plain account update"
    assert_equal "Keep Me", @user.name, "permitted fields still save"
    assert @user.first_username_change?, "the once-ever seed marker is untouched by a plain update"
  end

  test "confirm_username (phantom step 2) verifies the tx, mirrors the DB, and pays the first-username bonus" do
    # Phantom / self-custody step 2: the engine finalize step POSTs { token, proof }
    # (proof = the tx signature TM's finalize_hook returned). The controller verifies
    # the on-chain set_username, mirrors the rename to the DB, and pays the one-time
    # bonus. Solana::TxVerifier + the PDA derivation are stubbed so no live RPC is
    # needed — this is the coverage substitute for the browser Phantom step we can't
    # drive headless.
    log_in_as @user
    token = Rails.application.message_verifier(:account_username_change)
                 .generate({ user_id: @user.id, username: "phantom-confirmed" }, expires_in: 10.minutes)
    fake = FakeVault.new

    Solana::Keypair.stub :encode_base58, ->(bytes) { bytes.to_s } do
      Solana::TxVerifier.stub :verify!, true do
        Solana::Vault.stub :new, fake do
          post confirm_username_account_path, params: { token: token, proof: "phantom-sig" }, as: :json
        end
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "saved", body["status"]
    assert_equal "phantom-confirmed", @user.reload.username, "the confirmed rename mirrors to the DB"
    assert_equal 25, body["seeds_earned"], "the first confirmed rename pays the quest bonus"
    assert_equal 1, fake.grant_calls.length
    assert_equal :username, fake.grant_calls.first[:kind]
  end
end
