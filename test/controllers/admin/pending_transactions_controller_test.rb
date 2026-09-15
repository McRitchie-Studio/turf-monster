require "test_helper"
require "minitest/mock"

# Admin::PendingTransactionsController — the generalized multisig cosign queue.
# Covers the tx_type dispatch added in the unused-instructions cleanup:
# rebuild → the right Vault builder, confirm → the right post-verify DB flip.
# Vault + TxVerifier are stubbed so nothing hits RPC.
class Admin::PendingTransactionsControllerTest < ActionDispatch::IntegrationTest
  USDC = "222Dcu2RgAXE3T8A4mGSG3kQyXaNjqePx7vva1RdWBN9".freeze

  setup do
    @admin   = users(:alex)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_ptx")
  end

  def ptx(tx_type, metadata, target: nil)
    PendingTransaction.create!(
      tx_type: tx_type,
      serialized_tx: "OLD_TX",
      status: "pending",
      target: target,
      initiator_address: "init",
      metadata: metadata.to_json
    )
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE THIRD SIGNATURE
  # ══════════════════════════════════════════════════════════════════════════
  #
  # turf-vault v0.26 raised six operator actions to THREE vault signatures.
  # Rails supplied two — the server's admin key plus one Phantom cosigner — so
  # every one of them reached the chain one signature short. Five came back
  # 6046 InsufficientSigners; `settle_contest`, the only instruction that also
  # uses `remaining_accounts` for payload, came back 6047 CosignerDidNotSign
  # because the first settlement's `user_account` sat in the slot the third
  # signer should hold.
  #
  # `Config.governance?` is stubbed rather than set: the switch is frozen at
  # class load and this build ships v0.25, so the method is the seam that
  # reaches the v0.26 branch. Every test in this block goes through it.

  def with_governance(on = true, &block)
    Solana::Config.stub(:governance?, on, &block)
  end

  def spare_signer
    (Solana::CosignPlan.eligible_cosigners - [Solana::Config::MULTISIG_COSIGNER]).first
  end

  # THE REGRESSION. Against the code this change replaces, `extra_cosigners`
  # was never passed to any builder and this assertion fails — which is the
  # whole point of it.
  test "rebuild reserves the third signer slot on settle_contest" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    with_governance do
      Solana::Vault.stub :new, vault do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: [spare_signer] }, as: :json
      end
    end

    assert_response :success
    assert_equal 1, vault.settle_calls.length
    assert_equal [spare_signer], vault.settle_calls.first[:extra_cosigners],
                 "settle_contest must reserve the third signer's slot or the chain " \
                 "reads the settlement payload as a cosigner and fails 6047"
  end

  test "rebuild reserves the third signer slot on every raised queued type" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)

    cases = {
      "cancel_contest"         => [{ creator: "Creator11111111111111111111111111111111111" }, :cancel_calls],
      "register_currency"      => [{ mint: USDC, kind: 0 }, :register_calls],
      "deactivate_currency"    => [{ currency_idx: 2 }, :deactivate_calls],
      "sweep_operator_revenue" => [{ currency_mint: USDC, treasury_ata: "t", amount: 0 }, :sweep_calls]
    }

    cases.each do |tx_type, (meta, log)|
      tx = ptx(tx_type, meta, target: @contest)
      vault = FakeVault.new

      with_governance do
        Solana::Vault.stub :new, vault do
          post rebuild_admin_pending_transaction_path(slug: tx.slug),
               params: { extra_cosigners: [spare_signer] }, as: :json
        end
      end

      assert_response :success, "#{tx_type} rebuild should succeed"
      assert_equal [spare_signer], vault.public_send(log).first[:extra_cosigners],
                   "#{tx_type} needs three signatures and must reserve the third slot"
    end
  end

  # The plan travels WITH the bytes, so the browser collects against the slots
  # this very build reserved rather than against whatever the page believed.
  test "rebuild returns the signing plan alongside the transaction" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: [spare_signer] }, as: :json
      end
    end

    body = JSON.parse(response.body)
    assert_equal 3, body["required_signatures"]
    assert_equal Solana::Config::MULTISIG_COSIGNER, body["cosigner_address"]
    assert_equal [spare_signer], body["extra_cosigners"]
  end

  # FAIL IN RAILS, NOT ON CHAIN. A build with no third slot cannot succeed, so
  # refusing it here costs nothing and names the action; letting it through
  # spends a fee to be told 6046 by a program error that names no wallet.
  test "rebuild refuses to build a raised action with no third signer named" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: [] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/needs 3 vault signatures/, JSON.parse(response.body)["error"].to_s)
  end

  test "rebuild refuses a third signer outside the vault signer set" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: ["NotAVaultSigner1111111111111111111111111111"] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/not in the vault signer set/, JSON.parse(response.body)["error"].to_s)
  end

  # THE v0.25 SHAPE IS UNCHANGED. The switch exists so the changeover is a
  # config write; that only holds if governance-off still builds on two
  # signatures and demands nothing new.
  test "governance off still rebuilds on two signatures" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    with_governance(false) do
      Solana::Vault.stub :new, vault do
        post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
      end
    end

    assert_response :success
    assert_equal [], vault.settle_calls.first[:extra_cosigners]
  end

  # --- rebuild dispatch ---

  test "rebuild dispatches cancel_contest to build_cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "Creator11111111111111111111111111111111111" }, target: @contest)
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 1, vault.cancel_calls.length
    assert_match(/FAKE_TX_cancel/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches register_currency to build_register_currency" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0, op_rev_ata: "oprev" })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.register_calls.first[:mint]
    assert_match(/FAKE_TX_register/, tx.reload.serialized_tx)
  end

  test "rebuild dispatches deactivate_currency to build_deactivate_currency" do
    log_in_as(@admin)
    tx = ptx("deactivate_currency", { currency_idx: 2 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal 2, vault.deactivate_calls.first[:currency_idx]
  end

  test "rebuild dispatches sweep_operator_revenue to build_sweep_operator_revenue" do
    log_in_as(@admin)
    tx = ptx("sweep_operator_revenue", { currency_mint: USDC, treasury_ata: "t", amount: 0 })
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post rebuild_admin_pending_transaction_path(slug: tx.slug)
    end
    assert_equal USDC, vault.sweep_calls.first[:currency_mint]
  end

  # --- confirm post-verify DB state ---

  test "confirm flips onchain_cancelled for cancel_contest" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "c" }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_cancel" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_cancelled?
    assert_not @contest.onchain_settled?
  end

  test "confirm makes no Contest DB change for register_currency (no target)" do
    log_in_as(@admin)
    tx = ptx("register_currency", { mint: USDC, kind: 0 })
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_reg" }, as: :json
        end
      end
    end

    assert_equal "confirmed", tx.reload.status
  end

  test "confirm still flips onchain_settled for settle_contest" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, tx_signature: "sig_settle" }, as: :json
        end
      end
    end

    assert @contest.reload.onchain_settled?
  end

  test "confirm of settle_contest enqueues winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(
      user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0
    )
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_enqueued_jobs 1, only: WinnerNotificationJob do
            post confirm_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, tx_signature: "sig_settle_notify" }, as: :json
          end
        end
      end
    end

    assert @contest.reload.onchain_settled?
  end

  test "confirm of cancel_contest does NOT enqueue winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(
      user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0
    )
    tx = ptx("cancel_contest", { creator: "c" }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_no_enqueued_jobs only: WinnerNotificationJob do
            post confirm_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, tx_signature: "sig_cancel_notify" }, as: :json
          end
        end
      end
    end
  end

  # ── THE PAGE AND THE SERVER MUST AGREE ───────────────────────────────────
  #
  # THE REGRESSION THIS PINS. The view first sized its second-wallet control as
  # `required_signatures - 2`. That number is governance-INDEPENDENT — three is
  # three whether or not this boot speaks v0.26 — while the server sizes
  # `needed` from `extra_cosigners_needed`, which is zero unless governance is
  # on. So on a v0.25 boot, WHICH IS WHAT IS DEPLOYED, the page rendered a
  # second-wallet select and `#rebuild` then refused the operator's choice with
  # 422. It would have taken the treasury page down before v0.26 ever landed.
  #
  # Neither half alone catches it: the view test passed, the controller test
  # passed, and they disagreed in the gap between them. So this test drives the
  # PAGE and then feeds the server exactly what the page asked for.

  # The index reads the fee payer's balance once per page, so the Vault is
  # stubbed around the GET too — unstubbed it reaches the real RPC and spends
  # ~10s per test in network timeouts for an answer no assertion here reads.
  def extras_the_page_asks_for
    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end
    assert_response :success
    response.body.include?("data-extra-cosigner") ? [spare_signer] : []
  end

  test "governance off: the page asks for nothing and the server accepts nothing" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance(false) do
      asked = extras_the_page_asks_for
      assert_equal [], asked,
                   "a v0.25 boot reserves no extra slot, so the page must not ask for a wallet"

      Solana::Vault.stub :new, FakeVault.new do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: asked }, as: :json
      end
      assert_response :success, "the server must accept exactly what the page asked for"
    end
  end

  test "governance on: the page asks for a wallet and the server accepts it" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance do
      asked = extras_the_page_asks_for
      assert_equal 1, asked.length,
                   "a v0.26 boot reserves a third slot, so the page must ask for a wallet"

      Solana::Vault.stub :new, FakeVault.new do
        post rebuild_admin_pending_transaction_path(slug: tx.slug),
             params: { extra_cosigners: asked }, as: :json
      end
      assert_response :success, "the server must accept exactly what the page asked for"
    end
  end

  # The model's two numbers answer DIFFERENT questions and must not be confused
  # again: one is what the chain demands, the other is what this build reserves.
  test "required_signatures is what the chain demands; extra_cosigners_needed is what this build reserves" do
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance(false) do
      assert_equal 3, tx.required_signatures, "the program demands three either way"
      assert_equal 0, tx.extra_cosigners_needed, "but a v0.25 build reserves no extra slot"
    end

    with_governance do
      assert_equal 3, tx.required_signatures
      assert_equal 1, tx.extra_cosigners_needed
    end
  end

  # ── THE FEE PAYER, AND THE NIL/ZERO DISTINCTION ─────────────────────────
  #
  # A throwaway console let Mr. McRitchie press Execute at 2 of 3 approvals and
  # spend a transaction on a certain refusal, and separately let him connect an
  # empty wallet and meet "Attempt to debit an account but found no record of a
  # prior credit" — Solana's way of saying the fee payer is empty, naming no
  # account. So: never render a control the current state cannot satisfy, and
  # always say why it is off.
  #
  # WHICH account is measured matters. The fee payer here is the SERVER's admin
  # key, not the operator's wallet — verified by decoding account 0 of a built
  # wire. A cosigning wallet with zero SOL is fine, and telling him to fund one
  # would send him to solve the wrong problem.

  def index_with_fee_payer(status)
    vault = FakeVault.new
    vault.fee_payer_status_result = status
    with_governance do
      Solana::Vault.stub :new, vault do
        get admin_pending_transactions_path
      end
    end
    assert_response :success
  end

  test "an EMPTY fee payer disables co-sign and names the reason" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    index_with_fee_payer(address: "FeePayer1111111111111111111111111111111111",
                         balance_sol: 0.0, minimum_sol: 0.00005, funded: false)

    assert_match(/data-cosign-blocked/, response.body,
                 "an empty fee payer must be stated, not discovered on chain")
    assert_match(/cannot pay the network fee/, response.body)
    assert_match(/disabled/, response.body,
                 "a button that can only fail must not be offered")
  end

  # NIL IS NOT ZERO, and this is the leg that matters most. A balance that could
  # not be READ is not evidence of an empty account, and blocking on it would
  # turn a transient RPC flake into a treasury outage — the operator would be
  # locked out of settling by a network hiccup.
  test "an UNREADABLE fee payer balance does not block" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    index_with_fee_payer(address: "FeePayer1111111111111111111111111111111111",
                         balance_sol: nil, minimum_sol: 0.00005, funded: nil)

    assert_no_match(/cannot pay the network fee/, response.body,
                    "an unread balance must never be reported as an empty account")
    assert_match(/data-extra-cosigner/, response.body,
                 "the flow stays available — an RPC flake is not a funding problem")
  end

  test "a funded fee payer leaves co-sign available" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    index_with_fee_payer(address: "FeePayer1111111111111111111111111111111111",
                         balance_sol: 0.5, minimum_sol: 0.00005, funded: true)

    assert_no_match(/data-cosign-blocked/, response.body)
    assert_match(/data-extra-cosigner/, response.body)
  end

  # The estimate is DERIVED from the app's own fee constants, so a priority-fee
  # bump cannot leave the floor behind — which is the direction that matters,
  # since raising the fee is exactly when an old floor stops covering it.
  test "the fee floor tracks the configured priority fee and signature count" do
    three = Solana::Vault.estimated_fee_sol(required_signatures: 3)
    two   = Solana::Vault.estimated_fee_sol(required_signatures: 2)

    assert_operator three, :>, two,
                    "base fee is charged PER SIGNATURE, so three must cost more than two"
    assert_operator three, :>, 0, "a zero floor would accept an empty account"
  end

  # ── THE ROSTER ───────────────────────────────────────────────────────────
  #
  # Mr. McRitchie's requirement, in his words: "easy to see what's done and
  # what's next". Three signatures collected across Phantom account switches is
  # more state than anyone holds between extension dialogs, and the row he reads
  # is how he knows which account to select next.
  test "the roster lists every signer in signing order with the server already done" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    index_with_fee_payer(address: Solana::CosignPlan.admin_address,
                         balance_sol: 0.5, minimum_sol: 0.00005, funded: true)

    assert_match(/data-signer-roster/, response.body)
    assert_match(/3 signatures required/, response.body)

    # One row per signer, and the ORDER is the signing order — turf-vault reads
    # the leading remaining accounts positionally, so a roster in another order
    # would tell him to switch wallets in the wrong sequence.
    rows = response.body.scan(/data-signer-row="([^"]+)"/).flatten
    assert_equal [Solana::CosignPlan.admin_address,
                  Solana::Config::MULTISIG_COSIGNER,
                  spare_signer], rows
  end

  # The server signs at BUILD time, so its row is done before he touches
  # anything. Without saying so, a three-signature action shows two rows to act
  # on and the arithmetic looks wrong at the one moment he is counting.
  test "the roster says the server signs automatically and names it the fee payer" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    index_with_fee_payer(address: Solana::CosignPlan.admin_address,
                         balance_sol: 0.5, minimum_sol: 0.00005, funded: true)

    assert_match(/data-signer-role="server"/, response.body)
    assert_match(/0\.5000 SOL/, response.body, "the fee payer's balance is the one that matters")
  end

  # ── THE AUDIT RECORD ─────────────────────────────────────────────────────
  #
  # A three-signature payout authorised by three wallets, recorded as having
  # been authorised by ONE, is a worse answer than no record at all — it reads
  # as complete. `cosigner_address` is a single column and physically cannot
  # hold the set, so `cosigner_addresses` carries the whole ordered list and
  # the old column keeps naming the first (named) cosigner for every reader
  # that predates this change.

  test "broadcast records every vault signer that signed" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    primary = Solana::Config::MULTISIG_COSIGNER
    # Resolved BEFORE the stubs: `encode_base58` is stubbed below and
    # `admin_address` derives from it, so resolving the spare inside the block
    # would pick the admin key itself.
    spare = spare_signer

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        Solana::Keypair.stub :encode_base58, ->(k) { k.is_a?(String) ? k : k.to_s } do
          Solana::TxVerifier.stub :verify!, true do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
                 params: { cosigner_address: primary, extra_cosigners: [spare],
                           signed_tx: "SIGNED_WIRE" }, as: :json
          end
        end
      end
    end

    assert_response :success
    tx.reload
    assert_equal [primary, spare], tx.cosigner_addresses,
                 "all three signers must be recoverable from the row, in slot order"
    assert_equal primary, tx.cosigner_address, "the old column keeps naming the named cosigner"
    assert_equal [primary, spare], tx.all_cosigners
  end

  # EVERY extra signer is asserted to be in a SIGNER SLOT of what landed, not
  # merely present in the transaction. That distinction is the defect: 6047
  # CosignerDidNotSign is exactly what a non-signer account in a signer slot
  # produces, and a record written without this check would name a wallet that
  # never signed.
  test "broadcast verifies each extra cosigner against the landed transaction" do
    skip "needs a spare vault signer" if spare_signer.blank?
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    primary = Solana::Config::MULTISIG_COSIGNER
    spare = spare_signer   # before the stubs; see the note above
    verified = []

    verifier = lambda do |signature:, instruction_name:, signer_pubkey: nil, writable_pubkey: nil, client: nil|
      verified << signer_pubkey
      true
    end

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        Solana::Keypair.stub :encode_base58, ->(k) { k.is_a?(String) ? k : k.to_s } do
          Solana::TxVerifier.stub :verify!, verifier do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
                 params: { cosigner_address: primary, extra_cosigners: [spare],
                           signed_tx: "SIGNED_WIRE" }, as: :json
          end
        end
      end
    end

    assert_response :success
    assert_equal [primary, spare], verified,
                 "both the named cosigner and the extra must be proven to have signed"
  end

  test "broadcast refuses a claimed signer set that cannot reach the threshold" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    primary = Solana::Config::MULTISIG_COSIGNER

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        Solana::TxVerifier.stub :verify!, true do
          post broadcast_admin_pending_transaction_path(slug: tx.slug),
               params: { cosigner_address: primary, extra_cosigners: [],
                         signed_tx: "SIGNED_WIRE" }, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    assert_equal "pending", tx.reload.status, "a refused broadcast must not flip DB state"
    refute @contest.reload.onchain_settled?
  end

  # A row confirmed before this column existed still has to answer "who signed
  # this". Returning [] for it would report a settled payout as authorised by
  # nobody — the fallback is how the two schema eras read through one method.
  test "a row predating the column still reports its signer" do
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    tx.update_columns(cosigner_address: "LegacySigner111111111111111111111111111111",
                      cosigner_addresses: [])

    assert_equal ["LegacySigner111111111111111111111111111111"], tx.reload.all_cosigners
  end

  # --- broadcast: server-side send (the cosign fix) ---
  #
  # REGRESSION. The browser used to broadcast the cosigned wire itself, which
  # failed on mainnet every time for three compounding reasons (all measured
  # 2026-09-05): Config.public_rpc_url refuses to hand a credentialed endpoint
  # to a browser, so the page fell back to the throttled public cluster RPC;
  # web3.js Connection defaults to `finalized`, so sendRawTransaction
  # preflighted a fresh blockhash against a bank ~32 slots stale and rejected a
  # VALID tx with BlockhashNotFound; and the page read the tx out of a DOM
  # attribute baked at render time, so clicking Co-sign again re-sent the SAME
  # expired bytes. That silently stranded $140 of alpha-contest payouts in June.
  # Broadcasting server-side removes all three.

  test "broadcast sends the signed wire through the server and flips settle state" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post broadcast_admin_pending_transaction_path(slug: tx.slug),
            params: { cosigner_address: cosigner, signed_tx: "SIGNED_WIRE" }, as: :json
        end
      end
    end

    assert_response :success
    assert_equal ["SIGNED_WIRE"], vault.broadcast_calls
    assert_equal "confirmed", tx.reload.status
    assert @contest.reload.onchain_settled?
  end

  test "broadcast of settle_contest enqueues winner notifications" do
    log_in_as(@admin)
    @contest.entries.create!(user: @admin, status: "complete", rank: 1, payout_cents: 4500, score: 1.0)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    cosigner = Solana::Config::MULTISIG_SIGNERS.first

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          assert_enqueued_jobs 1, only: WinnerNotificationJob do
            post broadcast_admin_pending_transaction_path(slug: tx.slug),
              params: { cosigner_address: cosigner, signed_tx: "SIGNED_WIRE" }, as: :json
          end
        end
      end
    end
  end

  test "broadcast refuses a blank signed wire" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert_equal "pending", tx.reload.status
  end

  test "broadcast refuses a cosigner outside the multisig set" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: "NotASigner1111111111111111111111111111111", signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert_equal "pending", tx.reload.status
  end

  test "broadcast refuses a transaction that is no longer pending" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    tx.update!(status: "confirmed")
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
  end

  # The whole point of moving the broadcast server-side is that the operator
  # learns WHY it failed. The old client blamed an expired blockhash for every
  # failure, including program errors that no amount of retrying would fix.
  test "broadcast surfaces the real failure instead of a blockhash guess" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)
    vault = FakeVault.new(broadcast_raises: "Pre-flight simulation failed: SettlementOverflow")

    Solana::Vault.stub :new, vault do
      post broadcast_admin_pending_transaction_path(slug: tx.slug),
        params: { cosigner_address: Solana::Config::MULTISIG_SIGNERS.first, signed_tx: "SIGNED_WIRE" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/SettlementOverflow/, JSON.parse(response.body)["error"])
    assert_no_match(/blockhash/i, JSON.parse(response.body)["error"])
    assert_equal "pending", tx.reload.status
  end

  # Rebuild is now what the CLIENT calls at click time to get a tx whose
  # ~60-90s blockhash window starts at the click, not at page render. It must
  # therefore hand the fresh wire back in the JSON body.
  test "rebuild returns the fresh serialized tx in the json body" do
    log_in_as(@admin)
    tx = ptx("cancel_contest", { creator: "Creator11111111111111111111111111111111111" }, target: @contest)

    Solana::Vault.stub :new, FakeVault.new do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    assert_match(/FAKE_TX_cancel/, JSON.parse(response.body)["serialized_tx"])
  end

  # --- the index must not ship the wire to the DOM ---
  #
  # REGRESSION for cause #2. `data-tx-serialized` used to carry the whole
  # transaction, rendered with the page. Its blockhash aged from render time,
  # so by the first click it was often already dead — and every subsequent
  # click re-sent the identical expired bytes, which is why ten retries in a
  # row all failed the same way. The button now carries only the slug, and the
  # client asks the server for a fresh transaction when it is clicked.
  test "index does not render the serialized transaction into the page" do
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    get admin_pending_transactions_path

    assert_response :success
    assert_no_match(/data-tx-serialized/, response.body)
    assert_no_match(/OLD_TX/, response.body, "the wire itself must never reach the DOM")
  end

  # The button carries the slug and the chosen signers — NEVER the wire. The
  # third argument arrived with the v0.26 threshold rise: `settle_contest` needs
  # three signatures, and the extra signer's slot is part of the message, so the
  # wallet has to be named BEFORE the server builds. What this still protects is
  # the original property — the transaction itself is fetched at click time and
  # never rendered into the page.
  test "index co-sign button passes the slug, label and chosen cosigners" do
    log_in_as(@admin)
    tx = ptx("settle_contest", { settlements: [] }, target: @contest)

    get admin_pending_transactions_path

    assert_match(/data-tx-slug="#{tx.slug}"/, response.body)
    assert_match(
      /cosignTransaction\(this\.dataset\.txSlug, this\.dataset\.txLabel, collectExtraCosigners\(this\), this\)/,
      response.body
    )
  end

  # ── THE THIRD SIGNATURE'S CONTROL ────────────────────────────────────────
  #
  # A three-signature action must OFFER a second wallet. Without the control
  # there is no way to name the extra signer, the rebuild reserves no slot, and
  # the transaction reaches the chain exactly as short as it did before this
  # change — but now silently, because nothing on the page says three were
  # needed. The select is the visible half of the fix.
  test "index offers a second cosigner control on a three-signature action" do
    log_in_as(@admin)
    ptx("settle_contest", { settlements: [] }, target: @contest)

    with_governance do
      Solana::Vault.stub :new, FakeVault.new do
        get admin_pending_transactions_path
      end
    end

    assert_response :success
    assert_match(/data-extra-cosigner/, response.body,
                 "settle_contest needs three signatures and must offer a second wallet")
    assert_match(/3 signatures required/, response.body)
  end
end
