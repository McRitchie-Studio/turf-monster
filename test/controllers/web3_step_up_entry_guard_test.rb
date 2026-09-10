require "test_helper"

# THE WEB2-SESSION HALF of ContestsController#enter's wallet guard.
#
# #enter is the WEB2 / managed server-signing path. Two shapes must never reach
# it, and until 2026-09-07 only ONE of them was refused:
#
#   web3 session          -> refused by the `onchain_session?` guard, which
#                            names prepare_entry as the path to be on.
#   web2 session, on an
#   account whose ONLY
#   wallet is self-custody -> NOT REFUSED. It fell all the way through to
#                            #resolve_web2_entry_funding!, which raised
#                            "Managed wallet missing keypair (cannot sign
#                            entry)" because there is no custodial address to
#                            sign with. The controller's own comment called that
#                            "an accident of another guard rather than a
#                            decision" and it was right.
#
# WHAT THE OPERATOR SAW (QA, 2026-09-07): fresh browser -> Enter Contest -> auth
# gate -> Google. The Google sign-in armed the web3 step-up card correctly, the
# board replayed the saved cart, and the entry raised — so a RED card titled
# "Submitting Entry" reading the raw exception text landed ON TOP of the
# step-up card that was already saying the right thing.
#
# THE GUARD IS DELIBERATELY NARROW, and both of its narrowing clauses have a
# test below that goes red if you drop them:
#   - it consults Web3StepUpPolicy rather than re-deriving the population, so
#     the entry path and the auth path cannot drift into two answers; and
#   - it fires only when there is NO custodial keypair to sign with. A COMBO
#     account (managed + linked wallet) owes an advisory step-up but can still
#     fund an entry from the wallet the server holds — #resolve_web2_entry_funding!
#     deliberately spends from the web2 address for exactly that account — and a
#     FREE contest signs nothing at all, so neither is refused.
class Web3StepUpEntryGuardTest < ActionDispatch::IntegrationTest
  # THE TAG, NOT THE ID. layouts/application also NAMES this id in the driver
  # script that reads it (getElementById), so a bare substring match is true on
  # every page whether or not the card was ever armed — which is how the
  # re-arm assertion below first passed against unguarded code.
  STEP_UP_PAYLOAD = /id="web3-step-up-data"/

  setup do
    # The paid on-chain branch of #enter reads the current season inside the
    # lock; without it today's code raises "No active season configured" and
    # this suite would be asserting against the wrong failure.
    SeasonConfig.set_current!(1)

    @wallet_user = User.create!(
      name: "Wanda Wallet",
      username: "wanda-#{SecureRandom.hex(2)}",
      email: "wanda-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current,
      web3_solana_address: "5QcbFtHfBYKWLBEcvCNsBRJMhLC8pGpXJm3PFCwqFV4A",
      web3_wallet_provider: "phantom"
    )
    assert @wallet_user.phantom_wallet?, "fixture must hold a self-custody wallet"
    assert_not @wallet_user.managed_wallet?, "fixture must have NO custodial keypair — that is the bug's precondition"
    assert_not @wallet_user.self_custodied?, "self_custodied_at marks an EXPORT; this account never did one, which is why the older guard misses it"

    @paid_contest = onchain_paid_contest
  end

  # ── The regression ────────────────────────────────────────────────────────

  test "a web2 session on a wallet-only account is routed to the step-up instead of raising" do
    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, @paid_contest)

    # NO ERROR LOG, and that is the assertion that tells a DECISION from a
    # caught exception. Solana::ErrorInterpreter also maps the raise to this
    # same blocker as a backstop, so the response body alone reads identically
    # whether the guard ran or whether the entry raised and was interpreted on
    # the way out — measured: deleting the guard left every body assertion in
    # this file green. render_entry_error writes an ErrorLog for the raise; a
    # refusal issued BEFORE the attempt writes none.
    assert_no_difference "ErrorLog.count" do
      post enter_contest_path(@paid_contest), as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_not body["success"]
    assert_equal "web3_step_up_required", body.dig("blocker", "reason"),
                 "the refusal must ROUTE — a reason code the board dispatches on, not a bare error string"
    assert_equal "web3", body.dig("blocker", "mode")
  end

  # The entry must be refused, not merely reported as refused. The cart entry
  # stays a cart entry and nothing on it was touched.
  test "the refused entry is left untouched in the cart" do
    log_in_as(@wallet_user)
    entry = cart_entry_for(@wallet_user, @paid_contest)

    post enter_contest_path(@paid_contest), as: :json

    entry.reload
    assert entry.cart?, "a refused entry must not advance"
    assert_nil entry.onchain_tx_signature
    assert_nil entry.entry_number, "no on-chain entry slot may be probed for an entry we refused to sign"
  end

  test "the raise no longer reaches the user, and neither does its wording" do
    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, @paid_contest)

    post enter_contest_path(@paid_contest), as: :json

    body = JSON.parse(response.body)
    assert_no_match(/keypair/i, body["error"].to_s,
                    "the raise message is not user copy — this is the exact string the operator was shown")
    assert_no_match(/managed wallet missing/i, body["error"].to_s)
    assert_match(/wallet/i, body["error"].to_s, "the refusal still has to say what to do")
  end

  test "the refusal carries the wallet the card will ask for" do
    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, @paid_contest)

    post enter_contest_path(@paid_contest), as: :json

    data = JSON.parse(response.body).dig("blocker", "data")
    assert_equal "phantom", data["provider"]
    assert_equal "5Qcb…FV4A", data["walletHint"],
                 "the truncated address is how the user confirms the card means THEIR wallet"
  end

  # THE GOOGLE COLLISION PATH, end to end — the credential the operator actually
  # used. An account with a verified email and a linked wallet signs in through
  # OmniAuth (silent link, OPSEC-005), which establishes a WEB2 session on a
  # self-custody account: the exact intersection Web3StepUpPolicy names.
  test "the Google collision path lands on the step-up, not the raise" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-#{SecureRandom.hex(3)}",
      info: { email: @wallet_user.email, name: @wallet_user.name }
    )

    get "/auth/google_oauth2/callback"
    assert_response :redirect, "Google sign-in must establish a session for this to be the operator's flow"

    cart_entry_for(@wallet_user, @paid_contest)
    post enter_contest_path(@paid_contest), as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "web3_step_up_required", body.dig("blocker", "reason")
    assert_no_match(/keypair/i, body["error"].to_s)
  end

  # THE ROUTE, THROUGH THE LIVE LAYOUT. The blocker tells the board to open the
  # card now; re-arming the session prompt is what makes the NEXT render open it
  # too, for a player who reloads instead of reading the modal. Asserted against
  # layouts/application — the layout a player actually gets. That mattered
  # sharply while /admin/modals/preview rendered modals under a SECOND layout: a
  # break in the real one survived any assertion that only looked at the harness.
  # The harness went on 2026-09-09 and every modal assertion in this suite reads
  # the live layout now; this note stays as the reason it must keep doing so.
  test "the refusal re-arms the step-up card and the live layout emits it" do
    log_in_as(@wallet_user)

    # DRAIN THE LOGIN'S OWN PROMPT FIRST. record_web3_step_up_state! arms the
    # same one-shot at every auth success, and consume_web3_step_up_prompt
    # deletes it on the first RENDER — a magic-link consume only redirects, so
    # the payload is still in the session when this test starts. Two renders:
    # the first spends it, the second proves it is spent. Without them the
    # assertion at the end passes on UNGUARDED code, crediting the guard for
    # something the login did.
    get contest_path(@paid_contest)
    assert_match STEP_UP_PAYLOAD, response.body, "the login arms the same one-shot"
    get contest_path(@paid_contest)
    assert_no_match STEP_UP_PAYLOAD, response.body,
                    "spent on that first render — a one-shot, deleted on read"

    cart_entry_for(@wallet_user, @paid_contest)
    post enter_contest_path(@paid_contest), as: :json
    assert_response :unprocessable_entity

    get contest_path(@paid_contest)
    assert_response :success
    assert_match STEP_UP_PAYLOAD, response.body,
                 "the one-shot payload layouts/application reads to auto-open the card"
    assert_match "5Qcb…FV4A", response.body
  end

  # The board has to have somewhere to dispatch the new reason to. Rendered
  # through the live layout for the same reason as above.
  test "the contest board dispatches the step-up blocker" do
    log_in_as(@wallet_user)
    get contest_path(@paid_contest)

    assert_response :success
    assert_match "case 'web3_step_up_required':", response.body,
                 "the blocker dispatcher must have a case for the reason the server now returns"
    assert_match "showWeb3StepUpModal(blocker)", response.body,
                 "and the handler it dispatches to has to exist in the same document"
  end

  # DEFECT 2, SECOND HALF. The on-chain card said "Submitting Entry" over a red
  # error body — in-progress wording on a finished failure — because
  # solanaModal.error() keeps whatever title is already up when it is not given
  # one. Asserted on the rendered board, through the live layout.
  test "an entry failure retitles the card instead of still claiming to be submitting" do
    log_in_as(@wallet_user)
    get contest_path(@paid_contest)

    assert_response :success
    # THE WHOLE CALL, not the title string. This same board already dispatches
    # an 'Entry Failed' TOAST further down, so a bare match on the title is true
    # with or without this fix — measured: reverting the fix left the assertion
    # green.
    assert_match "error(data.error || 'Something went wrong', 'Entry Failed')", response.body,
                 "the failure branch must pass a title; without one the card keeps saying Submitting Entry"
  end

  # ── The two narrowing clauses ─────────────────────────────────────────────

  # A guard that only ever refuses is not a guard. A COMBO account holds a
  # custodial keypair, and #resolve_web2_entry_funding! deliberately signs and
  # spends from it — so this session has a real way to enter and must keep it.
  test "a combo account still enters through its custodial keypair" do
    combo = User.create!(
      name: "Combo Cody",
      username: "combo-#{SecureRandom.hex(2)}",
      email: "combo-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current,
      web3_solana_address: "8LmTuRkQpXvZbNc3WdEyHgJf5AsPqMn7RtVxKzC2BdYw"
    )
    grant_managed_wallet!(combo)
    assert combo.managed_wallet? && combo.phantom_wallet?, "combo = both wallets"

    log_in_as(combo)
    cart_entry_for(combo, @paid_contest)
    post enter_contest_path(@paid_contest), as: :json

    body = JSON.parse(response.body) rescue {}
    assert_not_equal "web3_step_up_required", body.dig("blocker", "reason"),
                     "a combo account has a keypair to sign with — refusing it would wall off a working path"
  end

  # A FREE contest signs nothing, so there is no keypair to be missing. This is
  # not hypothetical: users(:sam) is wallet-only and the contests suite enters
  # free contests as sam on a magic-link session throughout.
  test "a free contest still admits a wallet-only account on a web2 session" do
    free = Contest.create!(
      name: "Free Plumbing Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 0,
      max_entries: 29,
      status: :open,
      starts_at: 2.weeks.from_now
    )

    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, free)
    post enter_contest_path(free), as: :json

    assert_response :success
    assert JSON.parse(response.body)["success"], "a free entry needs no signature and must not be walled off"
  end

  # AND THE SAME, ON CHAIN — the one case that exercises the FEE clause ALONE.
  # The test above is a free OFF-CHAIN contest, which `onchain?` excludes before
  # the fee clause is read. Measured in review: without this, dropping
  # `entry_fee_cents.to_i.positive?` left the whole file green.
  test "a free ON-CHAIN contest still admits a wallet-only account on web2" do
    free_onchain = Contest.create!(
      name: "Free Onchain Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 0,
      max_entries: 31,
      status: :open,
      starts_at: 2.weeks.from_now,
      onchain_contest_id: SecureRandom.hex(8)
    )
    assert free_onchain.onchain?, "this case exists to exercise the FEE clause"

    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, free_onchain)
    post enter_contest_path(free_onchain), as: :json

    assert_response :success
    assert JSON.parse(response.body)["success"], "a free entry signs nothing"
  end

  # The OTHER half still owns its half. A wallet session belongs on
  # prepare_entry, and it must not be re-labelled as owing a step-up — it has
  # already signed THIS session, which is the very thing a step-up asks for.
  test "a wallet session is still sent to prepare_entry, not the step-up" do
    log_in_as_onchain(@wallet_user)
    cart_entry_for(@wallet_user, @paid_contest)

    post enter_contest_path(@paid_contest), as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_nil body["blocker"], "the web3 refusal is not a step-up — that session already signed"
    assert_match(/prepare_entry/, body["error"].to_s)
  end

  # ── THE PRE-CHECK HALF (/tasks/funds-gate-ignores-web3-wallet) ────────────
  #
  # The guard above is correct and, for the flow a player actually walks, was
  # UNREACHABLE. #enter is not the first thing the hold-to-confirm button talks
  # to: beginFundingCheck() fires POST #check_funding the instant the hold
  # STARTS, and confirmEntry aborts into showFundsNeeded ("Get USDC") on a
  # definitive { fundable: false } without ever POSTing /enter. So the step-up
  # sat behind a door the player never got to knock on.
  #
  # WHAT THE OPERATOR SAW (qa.turfmonster.media, 2026-09-07): the navbar read
  # $31 while the entry gate opened Get USDC. Both numbers were honestly
  # produced — by two readers that resolve the wallet DIFFERENTLY:
  #
  #   navbar  User#solana_address        -> web3_solana_address || web2_...  (FALLS BACK)
  #   gate    #entry_funding_status      -> onchain_session? ? web3_... : web2_...  (NO fallback)
  #
  # On a wallet-only account whose session was never promoted (magic link,
  # email, or the Google collision) the gate resolves web2_solana_address = nil
  # and returns [false, nil] WITHOUT EVER READING A BALANCE — a money verdict
  # about an account whose money it never looked at. It is not devnet-specific
  # and reproduces on mainnet with real USDC.
  #
  # THE FIX IS NOT TO READ THE WEB3 WALLET HERE. Web2 entry SERVER-SIGNS from
  # web2_solana_address; pricing the entry off a wallet the server cannot sign
  # with would trade a false "Get USDC" for a doomed entry. The account owes a
  # SIGNATURE, not money — so the pre-check stops answering, and #enter's guard
  # (which is right, and now shares its predicate) gets to.
  test "the funding pre-check routes a wallet-only account to the step-up, not Get USDC" do
    log_in_as(@wallet_user)
    cart_entry_for(@wallet_user, @paid_contest)

    vault = FakeVault.new(tokens: [])
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@paid_contest), as: :json
    end

    assert_response :success
    precheck = JSON.parse(response.body)
    # THE SYMPTOM, stated as the thing that must not happen. confirmEntry aborts
    # the hold into showFundsNeeded on exactly this value — it IS the Get USDC.
    assert_not_equal "no_funding", precheck["reason"],
                     "a wallet-only account owes a signature, not money — no_funding is what opens Get USDC"
    assert precheck["fundable"],
           "the pre-check must not abort the hold; the refusal that belongs to this account is /enter's step-up"

    # AND THE DESTINATION IS REAL. Not-blocked is only half a fix: the hold now
    # proceeds to POST /enter, and what the player must land on is the step-up
    # card. Asserting the pre-check alone would pass for a change that merely
    # opened the gate and dropped the player somewhere worse.
    post enter_contest_path(@paid_contest), as: :json
    assert_response :unprocessable_entity
    assert_equal "web3_step_up_required", JSON.parse(response.body).dig("blocker", "reason"),
                 "the pre-check has to hand off to the refusal that knows what to ask for"
  end

  # THE MONEY HALF, ASSERTED AS MONEY. The bug produced a funding verdict from
  # no balance read at all, so a suite that only ever asserts the boolean cannot
  # tell a computed verdict from an invented one. These two pin the NUMBER and
  # the WALLET it was read from: same account, same session, same fee — only the
  # balance moves, and the verdict moves with it.
  test "a promoted session prices the entry off the web3 wallet that holds the funds" do
    log_in_as_onchain(@wallet_user)
    address = @wallet_user.reload.web3_solana_address

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 } # fee is 500 cents
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@paid_contest), as: :json
    end

    body = JSON.parse(response.body)
    assert_equal [ address ], vault.balance_calls,
                 "the verdict must be computed from the wallet that actually holds the funds"
    assert body["fundable"]
    assert_equal "usdc", body["method"]
  end

  test "the same promoted session is refused when that same wallet cannot cover the fee" do
    log_in_as_onchain(@wallet_user)
    address = @wallet_user.reload.web3_solana_address

    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 4.99, usdt: 0.0 } # one cent short of 500
    Solana::Vault.stub :new, vault do
      post check_funding_contest_path(@paid_contest), as: :json
    end

    body = JSON.parse(response.body)
    assert_equal [ address ], vault.balance_calls
    assert_not body["fundable"], "$4.99 does not cover a $5.00 entry — the number is what decides"
    assert_equal "no_funding", body["reason"]
  end

  # ── The pre-check's narrowing clauses ─────────────────────────────────────

  # A gate that stops refusing is not a fix. A managed account with a real, empty
  # custodial wallet is the population #check_funding was BUILT for (a fresh
  # wallet has no USDC ATA, reads null client-side, and slips past the sync
  # blocker) — it must still be caught, and caught on a real read.
  test "a genuinely broke managed wallet is still told to Get USDC" do
    managed = User.create!(
      name: "Manny Managed",
      username: "manny-#{SecureRandom.hex(2)}",
      email: "manny-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    grant_managed_wallet!(managed)
    assert managed.managed_wallet? && !managed.phantom_wallet?, "fixture must be custodial-only"

    log_in_as(managed)
    vault = FakeVault.new(tokens: []) # default balances all 0.0
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@paid_contest), as: :json
      end
    end

    body = JSON.parse(response.body)
    assert_not body["fundable"]
    assert_equal "no_funding", body["reason"]
    assert_equal [ managed.web2_solana_address ], vault.balance_calls,
                 "this refusal is a MONEY verdict and must still be computed from a real balance read"
  end

  # THE SECOND CLAUSE, ON THE PRE-CHECK. A COMBO account owes an advisory
  # step-up and can still enter — #resolve_web2_entry_funding! deliberately
  # signs and spends from the custodial wallet — so the short-circuit must not
  # swallow its balance read. Without the managed_wallet? clause this goes red
  # on the balance_calls assertion, not merely on the verdict.
  test "a combo account's pre-check still prices the custodial wallet it signs from" do
    combo = User.create!(
      name: "Combo Cody",
      username: "combo-#{SecureRandom.hex(2)}",
      email: "combo-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current,
      web3_solana_address: "8LmTuRkQpXvZbNc3WdEyHgJf5AsPqMn7RtVxKzC2BdYw"
    )
    grant_managed_wallet!(combo)
    assert combo.managed_wallet? && combo.phantom_wallet?, "combo = both wallets"

    log_in_as(combo)
    vault = FakeVault.new(tokens: [])
    vault.wallet_balances = { sol: 0.1, usdc: 25.0, usdt: 0.0 }
    AppFlags.stub :web2_usdc_entry?, true do
      Solana::Vault.stub :new, vault do
        post check_funding_contest_path(@paid_contest), as: :json
      end
    end

    body = JSON.parse(response.body)
    assert_equal [ combo.web2_solana_address ], vault.balance_calls,
                 "a combo account signs from the custodial wallet — the step-up short-circuit must not skip that read"
    assert body["fundable"]
    assert_equal "usdc", body["method"]
  end

  private

  def onchain_paid_contest
    Contest.create!(
      name: "Paid Onchain Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 500,
      max_entries: 100,
      status: :open,
      starts_at: 2.weeks.from_now,
      onchain_contest_id: SecureRandom.hex(8)
    )
  end

  def cart_entry_for(user, contest)
    entry = contest.entries.create!(user: user, status: :cart)
    [ :m1, :m2, :m3, :m4, :m5, :m6 ].first(contest.picks_required).each do |name|
      entry.selections.create!(slate_matchup: slate_matchups(name))
    end
    entry
  end
end
