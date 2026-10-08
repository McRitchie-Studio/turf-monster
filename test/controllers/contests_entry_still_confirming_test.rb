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

  DEADLINE = 1_000_000 # the prepared wire's last valid block height

  def post_recover(ptx, statuses: {}, vault: nil, **vault_opts)
    vault ||= FakeVault.new(signature_statuses: statuses, **vault_opts)
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.to_s } do
        post recover_pending_entry_contest_path(@contest), params: { ptx_slug: ptx.slug }, as: :json
      end
    end
    JSON.parse(response.body)
  end

  # A signed, submitted row whose wire carries a deadline, broadcast `age` ago.
  def submitted_ptx(age:, deadline: DEADLINE)
    meta = { entry_pda: @expected_pda }
    meta[:last_valid_block_height] = deadline if deadline
    PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx", status: "submitted",
      target: @entry, initiator_address: @user.web3_solana_address,
      tx_signature: "sig-#{SecureRandom.hex(4)}", broadcast_at: age.ago, metadata: meta.to_json
    )
  end

  def landed
    { "err" => nil, "confirmationStatus" => "finalized" }
  end

  def lapsed
    OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute
  end

  def assert_still_processing(body, ptx)
    assert_equal "processing", body["status"], body.inspect
    assert_equal "submitted", ptx.reload.status, "the row keeps prepare_entry's 409 standing"
    assert @entry.reload.cart?
  end

  test "recovery fails a signature unseen past the window AND past the chain deadline, freeing the player" do
    ptx = submitted_ptx(age: lapsed)

    vault = FakeVault.new(block_height: DEADLINE + 1)
    body = post_recover(ptx, vault: vault)

    assert_equal "failed", body["status"]
    assert_equal "failed", ptx.reload.status
    assert @entry.reload.cart?
    assert_equal ["finalized"], vault.client.block_height_calls, "the deadline is judged at finalized height"
    assert_equal 2, vault.client.status_calls.size, "the status is read again AFTER the height, so nothing landed in between"
  end

  # --- the double charge: a landed entry must never read failed ---

  test "a 429 on the status read answers processing and keeps the row submitted" do
    ptx = submitted_ptx(age: 30.seconds)

    body = post_recover(ptx, status_raises: "HTTP 429 Too Many Requests")

    assert_still_processing(body, ptx)
  end

  test "a 429 on the verify of a LANDED signature answers processing and keeps the row submitted" do
    ptx = submitted_ptx(age: 30.seconds)
    error = rpc_429

    body = Solana::TxVerifier.stub :verify!, ->(**) { raise error } do
      post_recover(ptx, statuses: { ptx.tx_signature => landed })
    end

    assert_still_processing(body, ptx)
  end

  test "a lagging node that cannot find a LANDED signature answers processing, not failed" do
    ptx = submitted_ptx(age: 30.seconds)

    body = Solana::TxVerifier.stub :verify!, ->(**) { raise Solana::TxVerifier::NotFound, "Transaction not found on-chain" } do
      post_recover(ptx, statuses: { ptx.tx_signature => landed })
    end

    assert_still_processing(body, ptx)
  end

  test "a landed signature the verifier refuses is held, never released: a success on chain is a payment" do
    ptx = submitted_ptx(age: 30.seconds)

    body = Solana::TxVerifier.stub :verify!, ->(**) { raise Solana::TxVerifier::VerificationError, "Transaction does not contain a `enter_contest` instruction" } do
      post_recover(ptx, statuses: { ptx.tx_signature => landed })
    end

    assert_equal "held", body["status"]
    assert_equal "submitted", ptx.reload.status
    assert_equal "landed", @entry.reload.payment_state
    assert @entry.cart?
  end

  test "CONTROL: the same signature FAILED on chain is released, and the player may try again" do
    ptx = submitted_ptx(age: 30.seconds)
    failed = { "err" => { "InstructionError" => [0, { "Custom" => 6004 }] }, "confirmationStatus" => "finalized" }

    body = post_recover(ptx, statuses: { ptx.tx_signature => failed })

    assert_equal "failed", body["status"]
    assert_equal "failed", ptx.reload.status
    assert_equal "draft", @entry.reload.payment_state
  end

  test "five minutes elapsed before the chain passes the deadline does not fail the row" do
    ptx = submitted_ptx(age: lapsed)

    body = post_recover(ptx, block_height: DEADLINE) # AT the deadline the wire can still land

    assert_still_processing(body, ptx)
  end

  test "a failed block height read past the window answers processing" do
    ptx = submitted_ptx(age: lapsed)

    body = post_recover(ptx) # no height seeded: the read raises

    assert_still_processing(body, ptx)
  end

  test "a row with no recorded deadline is never failed on the wall clock alone" do
    ptx = submitted_ptx(age: 1.day, deadline: nil)

    body = post_recover(ptx, block_height: DEADLINE * 10)

    assert_still_processing(body, ptx)
  end

  test "a signature that lands between the height read and the re-read is verified, not failed" do
    ptx = submitted_ptx(age: lapsed)
    statuses = { ptx.tx_signature => ->(nth) { nth == 1 ? nil : { "err" => nil, "confirmationStatus" => "finalized" } } }

    body = Solana::TxVerifier.stub :verify!, true do
      post_recover(ptx, statuses: statuses, block_height: DEADLINE + 1)
    end

    assert_equal "confirmed", body["status"], body.inspect
    assert_equal "confirmed", ptx.reload.status
    assert @entry.reload.active?
  end

  # --- Carl's probe: a cart cleared mid-confirm must not open a second wire ---

  test "clear picks is refused while the cart's signed submit is pending, keeping its slot" do
    ptx = submitted_ptx(age: 30.seconds)

    post clear_picks_contest_path(@contest), as: :json

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal "entry_pending", body["code"]
    assert_equal ptx.slug, body["ptx_slug"]
    @entry.reload
    assert @entry.cart?, "the paying cart is not abandoned"
    assert_equal 0, @entry.entry_number, "the slot the PDA derives from stays put"
  end

  test "CONTROL: clear picks still abandons a cart with no pending submit" do
    post clear_picks_contest_path(@contest), as: :json

    assert_response :success
    assert @entry.reload.abandoned?
  end

  test "PROBE: a landed wire on a cart abandoned mid-confirm never fails, and the new cart stays refused" do
    ptx = submitted_ptx(age: 30.seconds)
    # The shape the probe reached: abandoned with the slot released, so no
    # entry_number to derive the PDA from. clear_picks now refuses this
    # transition while the wire is pending; the row is built directly to prove
    # recovery holds even if it arises some other way.
    @entry.update!(status: :abandoned)
    assert_nil @entry.reload.entry_number

    body = Solana::TxVerifier.stub :verify!, true do
      post_recover(ptx, statuses: { ptx.tx_signature => landed })
    end

    assert_equal "processing", body["status"], "the real vault's TypeError on a nil slot is no verdict"
    assert_equal "submitted", ptx.reload.status

    new_cart = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |m| new_cart.selections.create!(slate_matchup: slate_matchups(m)) }
    Solana::Vault.stub :new, FakeVault.new do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :conflict
    assert_nil JSON.parse(response.body)["serialized_tx"], "no second paying wire"
  end

  test "the fake vault's PDA derivation raises on a nil slot, as the real one does" do
    assert_raises(TypeError) { FakeVault.new.entry_pda(@contest.slug, @user.web3_solana_address, nil) }
  end

  [Socket::ResolutionError.new("getaddrinfo: nodename nor servname provided"),
   Errno::ECONNREFUSED.new, OpenSSL::SSL::SSLError.new("SSL_connect"), EOFError.new("end of file reached")].each do |fault|
    test "an unwrapped #{fault.class} during the verify of a landed signature answers processing" do
      ptx = submitted_ptx(age: 30.seconds)

      body = Solana::TxVerifier.stub :verify!, ->(**) { raise fault } do
        post_recover(ptx, statuses: { ptx.tx_signature => landed })
      end

      assert_still_processing(body, ptx)
    end
  end

  # --- the 409 covers every cart this player builds on this contest ---

  test "a new cart is refused while another entry submit is pending" do
    ptx = submitted_ptx(age: 30.seconds)
    # Clear picks abandons the paying cart; the next pick builds a fresh one.
    @entry.update!(status: :abandoned)
    new_cart = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |m| new_cart.selections.create!(slate_matchup: slate_matchups(m)) }

    assert_no_difference "PendingTransaction.count" do
      Solana::Vault.stub :new, FakeVault.new do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal "entry_pending", body["code"]
    assert_equal ptx.slug, body["ptx_slug"], "the board recovers the row that is actually pending"
    assert_nil body["serialized_tx"]
  end

  test "CONTROL: another player's pending submit does not refuse this player's cart" do
    other = users(:alex)
    other_entry = @contest.entries.create!(user: other, status: :cart)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "submitted",
                               target: other_entry, initiator_address: "OtherWallet#{SecureRandom.hex(3)}",
                               tx_signature: "sig-other-#{SecureRandom.hex(3)}", broadcast_at: Time.current)

    Solana::Vault.stub :new, FakeVault.new do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :success
  end

  # --- the stamp is conditional: a second confirm cannot overwrite the first ---

  test "a confirm whose row already carries another signature sends nothing and answers still confirming" do
    ptx = prepared_ptx(status: "submitted", tx_signature: "sig-first-confirm", broadcast_at: 5.seconds.ago)
    vault = FakeVault.new
    vault.cosign_broadcast_signature = "sig-second-confirm"

    Solana::Vault.stub :new, vault do
      post_confirm
    end

    assert_equal 0, vault.cosign_broadcast_sends, "the losing confirm never reaches the send"
    assert_response :accepted
    assert_equal ptx.slug, JSON.parse(response.body)["ptx_slug"]
    assert_equal "sig-first-confirm", ptx.reload.tx_signature, "the first stamp stands"
  end

  test "the stamp still lands on a fresh pending row" do
    ptx = prepared_ptx
    vault = FakeVault.new
    vault.cosign_broadcast_raises = "send failed"

    Solana::Vault.stub :new, vault do
      post_confirm
    end

    assert_equal 1, vault.cosign_broadcast_sends
    assert_equal "fake-cosign-broadcast-sig", ptx.reload.tx_signature
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
