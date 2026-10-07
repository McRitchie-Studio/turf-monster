require "test_helper"
require "minitest/mock"

# A BROADCAST ENTRY IS "SENT, STILL CONFIRMING", NEVER "TRY AGAIN"
# (turf-phantom-entry-still-confirming).
#
# confirm_onchain_entry stamps the PendingTransaction (signature + submitted) in
# `before_send`, before the bytes leave. Anything that fails after that stamp —
# a 429 on the getTransaction verify, a lost confirmation poll — is a payment
# that MAY have landed. Before this task the player read "The Solana network is
# busy right now — please try again in a moment.", and prepare_entry let them do
# exactly that: a second wire, a second payment.
#
# Now: the answer after a stamp is "sent and still confirming", the client routes
# it into recover_pending_entry, and prepare_entry refuses while that row stands.
class ContestsEntryStillConfirmingTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    SeasonConfig.set_current!(1)
    @user.update!(web3_solana_address: "Web3StillConfirming#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_still_confirming", season_id: 1)
    log_in_as_onchain(@user)
    @entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    %i[m1 m2 m3 m4 m5 m6].each { |m| @entry.selections.create!(slate_matchup: slate_matchups(m)) }
    @expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"
  end

  # A real 429 from the gem's own client, not a hand-built string.
  def rpc_429
    rpc = ThrottledRpc.client(retry_after: 3)
    assert_raises(Solana::Client::HttpError) { rpc.get_account_info("Wallet") }
  end

  def prepared_ptx(**attrs)
    PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx", status: "pending",
      target: @entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: @expected_pda }.to_json, **attrs
    )
  end

  def post_confirm
    post confirm_onchain_entry_contest_path(@contest),
         params: { signed_tx: "PHANTOM_SIGNED_WIRE_B64", entry_id: @entry.id, entry_pda: @expected_pda },
         as: :json
  end

  def assert_still_confirming(ptx)
    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal "entry_pending", body["code"]
    assert_equal ptx.slug, body["ptx_slug"], "the client resolves it through recover_pending_entry by this slug"
    assert_match(/sent/i, body["error"])
    assert_match(/still confirming/i, body["error"])
    refute_match(/try again|retry/i, body["error"], "a payment that may have landed is never offered a second try")
    assert_nil body["blocker"]
    assert @entry.reload.cart?, "nothing is credited until recovery verifies the signature"
    ptx.reload
    assert_equal "submitted", ptx.status
    assert_equal "fake-cosign-broadcast-sig", ptx.tx_signature
  end

  test "a 429 on the verify after the stamp answers sent and still confirming" do
    ptx = prepared_ptx
    error = rpc_429

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.to_s } do
        Solana::TxVerifier.stub :verify!, ->(*) { raise error } do
          post_confirm
        end
      end
    end

    assert_still_confirming(ptx)
  end

  test "CONTROL: the same 429 reads as try-again through the interpreter alone" do
    # What the player used to see for the case above. Pins that the fix lives at
    # the stamp, not in a rewording of the interpreter's 429 copy, which stays
    # correct for every pre-broadcast read (prepare_entry, ensure_user_account).
    result = Solana::ErrorInterpreter.interpret(rpc_429, contest: @contest, mode: :web3)
    assert_match(/try again/i, result[:message])
  end

  test "a failed send after the stamp answers sent and still confirming" do
    ptx = prepared_ptx
    vault = FakeVault.new
    vault.cosign_broadcast_raises = "send failed — reconcile before rebuilding: HTTP 429"

    Solana::Vault.stub :new, vault do
      post_confirm
    end

    assert_still_confirming(ptx)
  end

  test "the stamp records broadcast_at, the anchor recovery's never-landed verdict reads" do
    ptx = prepared_ptx
    vault = FakeVault.new
    vault.cosign_broadcast_raises = "send failed"

    freeze_time do
      Solana::Vault.stub :new, vault do
        post_confirm
      end
      assert_equal Time.current, ptx.reload.broadcast_at
    end
  end

  test "a wire refused before the stamp keeps its own answer (nothing was sent)" do
    ptx = prepared_ptx
    vault = FakeVault.new
    vault.cosign_verify_raises = "mismatch"

    Solana::Vault.stub :new, vault do
      post_confirm
    end

    assert_response :unprocessable_entity
    assert_equal "tx_rejected", JSON.parse(response.body)["code"]
    assert_equal "pending", ptx.reload.status
  end

  test "a stamp that fails to save sends nothing and does not claim the entry was sent" do
    ptx = prepared_ptx
    vault = FakeVault.new

    # Another row already holds the signature, so the stamp's update! hits the
    # unique index and raises inside before_send. The in-memory row still
    # carries the attributes it tried to write; only the database knows nothing
    # was stamped, and nothing was sent.
    other_entry = @contest.entries.create!(user: users(:alex), status: :cart)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "other", status: "failed",
                               target: other_entry, initiator_address: "OtherWallet",
                               tx_signature: "fake-cosign-broadcast-sig")

    Solana::Vault.stub :new, vault do
      post_confirm
    end

    assert_response :unprocessable_entity
    refute_equal "entry_pending", JSON.parse(response.body)["code"]
    assert ptx.reload.tx_signature.blank?
  end

  # --- prepare_entry ---

  test "prepare_entry refuses while a submitted entry transaction is pending, minting no new row" do
    ptx = prepared_ptx(status: "submitted", tx_signature: "sig-in-flight-#{SecureRandom.hex(3)}")
    vault = FakeVault.new

    assert_no_difference "PendingTransaction.count" do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal "entry_pending", body["code"]
    assert_equal ptx.slug, body["ptx_slug"]
    assert_match(/still confirming/i, body["error"])
    refute_match(/try again|retry/i, body["error"])
    assert_nil body["serialized_tx"], "no wire to sign means no second payment"
    assert_equal "submitted", ptx.reload.status
  end

  test "CONTROL: prepare_entry still builds over an unsigned prepared row" do
    prepared_ptx # pending, no signature: nothing ever left the server

    assert_difference "PendingTransaction.count", 1 do
      Solana::Vault.stub :new, FakeVault.new do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
  end

  test "prepare_entry builds again once recovery has failed the row" do
    prepared_ptx(status: "failed", tx_signature: "sig-dead-#{SecureRandom.hex(3)}")

    assert_difference "PendingTransaction.count", 1 do
      Solana::Vault.stub :new, FakeVault.new do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :success
  end

  # --- recover_pending_entry: the pending submit resolves here ---

  def post_recover(ptx, statuses: {})
    Solana::Vault.stub :new, FakeVault.new(signature_statuses: statuses) do
      post recover_pending_entry_contest_path(@contest), params: { ptx_slug: ptx.slug }, as: :json
    end
    JSON.parse(response.body)
  end

  test "recovery fails a signature still unseen past the blockhash window, freeing the player" do
    ptx = prepared_ptx(status: "submitted", tx_signature: "sig-dropped-#{SecureRandom.hex(3)}",
                       broadcast_at: (OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute).ago)

    body = post_recover(ptx)

    assert_equal "failed", body["status"]
    assert_equal "failed", ptx.reload.status
    assert @entry.reload.cart?
  end

  test "recovery keeps an unseen signature processing inside the blockhash window" do
    ptx = prepared_ptx(status: "submitted", tx_signature: "sig-young-#{SecureRandom.hex(3)}",
                       broadcast_at: 30.seconds.ago)

    assert_equal "processing", post_recover(ptx)["status"]
    assert_equal "submitted", ptx.reload.status
  end

  test "recovery never fails an unseen signature with no broadcast anchor" do
    ptx = prepared_ptx(status: "submitted", tx_signature: "sig-legacy-#{SecureRandom.hex(3)}")
    ptx.update_columns(created_at: 1.day.ago)

    assert_equal "processing", post_recover(ptx)["status"]
    assert_equal "submitted", ptx.reload.status
  end
end
