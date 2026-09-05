# frozen_string_literal: true

require "test_helper"

# THE ORDER OF WRITES IN ContestsController#finalize IS A MONEY INVARIANT.
#
# #finalize broadcasts `create_contest` — which moves the CREATOR's prize-pool
# USDC into the vault — and then writes the Contest row. Before this change the
# broadcast came FIRST, so every raise between the two (an RPC read-back, an S3
# upload, a NOT NULL column) landed in the rescue and told the user their
# contest had failed while their money was already in the vault. `tx_signature`
# was a local variable never persisted, so nothing outside that request knew the
# broadcast had happened, and Entries::OnchainReconciler is rooted in Contest
# rows — a funded PDA with no row is not merely unreconciled, it is UNREACHABLE.
#
# The fix inverts the failure mode: write the row FIRST (status `pending`,
# carrying the derived PDA), broadcast, then promote to `open`. A crash now
# leaves a row with no money, which is sweepable, instead of money with no row,
# which is not.
#
# THE HAZARD THIS FILE EXISTS TO PIN. Contest has an after_create callback
# (contest.rb:70) that fires the SERVER-FUNDED create path — a second
# `create_contest` broadcast paid from the HOUSE wallet. A write-ahead row saved
# carelessly would fire it, and a fix aimed at preventing one stranded payment
# would instead create a double spend. That is the first test below.
#
# Raised by Carl (primary) and Jasper (light) reviewing PR #544; designed with
# Mr. McRitchie 2026-09-05. Task: harden-finalize-write-ordering.
class ContestsFinalizeWriteOrderingTest < ActionDispatch::IntegrationTest
  # A FakeVault that photographs the contests table AT THE INSTANT the money
  # moves. Asserting on the row after the request proves only that a row exists
  # eventually; asserting on this snapshot proves the row was durable BEFORE the
  # broadcast, which is the entire invariant.
  class BroadcastSnapshotVault < FakeVault
    attr_reader :row_at_broadcast

    def cosign_and_broadcast_create_contest(signed_wire_base64)
      row = Contest.find_by(slug: @watch_slug)
      @row_at_broadcast = row && {
        persisted:          row.persisted?,
        status:             row.status,
        onchain_contest_id: row.onchain_contest_id,
        onchain_tx_signature: row.onchain_tx_signature
      }
      super
    end

    def watch_slug=(slug)
      @watch_slug = slug
    end
  end

  setup do
    @slate = slates(:one)
    # #create refuses to build an on-chain contest without an active season.
    SeasonConfig.set_current!(1)
  end

  def admin_phantom
    @admin_phantom ||= User.create!(
      name: "Order Admin", username: "order_admin", role: :admin,
      email: "order_admin@mcritchie.studio",
      web3_solana_address: "AdMiNPhantoM1111111111111111111111111111111"
    )
  end

  # Step 1 of the Phantom flow. Returns the parsed JSON carrying the params_token
  # #finalize verifies.
  def run_create(slug:, name:)
    json = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post contests_path,
        params: { contest: { name: name, slug: slug, slate_id: @slate.id, contest_type: "tiny" } },
        as: :json
      json = JSON.parse(response.body)
    end
    assert_equal true, json["success"], "create step failed: #{json.inspect}"
    json
  end

  # Step 3. `vault` is the stand-in for the whole finalize leg, so a caller can
  # inject a fault or a snapshot recorder.
  #
  # `multipart:` matters and is not a test detail. The real client builds a
  # FormData and posts the banner as a file part (contests/new.html.erb:492-502)
  # — a JSON post cannot carry one, and a `contest_image` sent as JSON arrives
  # as a String that `attach` would try to read as a signed blob id. Any test
  # about the image has to travel the wire the browser actually uses.
  def run_finalize(create_json, vault, extra_params = {}, multipart: false)
    body = {
      params_token: create_json["params_token"],
      contest_pda:  create_json["contest_pda"],
      signed_tx:    "SIGNED_CREATE_WIRE"
    }.merge(extra_params)

    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          if multipart
            post finalize_contests_path, params: body
          else
            post finalize_contests_path, params: body, as: :json
          end
        end
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ACCEPTANCE 2 — THE DOUBLE SPEND. This is the test that matters most.
  # ───────────────────────────────────────────────────────────────────────────

  # The user-visible money property, asserted through the real controller: the
  # Phantom leg broadcasts EXACTLY ONCE and the server-funded leg never runs.
  #
  # Read the sibling model test below before trusting this one on its own:
  # `skip_onchain_callback_active?` short-circuits on `Rails.env.test?`, so the
  # after_create callback is inert in this environment no matter what the
  # controller does. This test pins the count of broadcasts the CONTROLLER
  # itself makes; the model test is what pins the callback.
  test "finalize broadcasts create_contest exactly once and never server-funds" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-once", name: "Order Once")
    vault = FakeVault.new

    run_finalize(create_json, vault)

    assert_response :success
    assert_equal 1, vault.create_cosign_broadcast_calls.length,
      "the creator's prize pool must move exactly once"
    assert_empty vault.server_funded_calls,
      "the HOUSE wallet must never fund a Phantom-created contest — that is the double spend"
  end

  # THE CALLBACK ITSELF, with the test-environment short-circuit removed.
  #
  # `skip_onchain_callback_active?` is `skip_onchain_callback || onchain? ||
  # Rails.env.test?`. The third clause makes every controller test above blind to
  # this hazard, so this test stubs Rails.env to production and saves the row the
  # controller would save, built by the controller's own builder.
  #
  # WHAT MUTATION SAYS ABOUT THIS TEST, stated plainly because it is not
  # single-mutation sensitive and a reader deserves to know: the pending row is
  # protected by THREE overlapping guards — the explicit `skip_onchain_callback`
  # flag, `onchain?` (true because the row carries the derived PDA), and
  # `create_onchain!`'s own `return if onchain?`. Dropping the flag alone leaves
  # the other two, so this test stays green; the test below it is the one that
  # catches that. This test catches the realistic bad implementation — a
  # write-ahead row saved with NEITHER the flag NOR the PDA — which is exactly
  # what "just write a stub row, we'll fill in the PDA later" produces.
  test "the pending row never fires the server-funded callback, even outside the test env" do
    contest = build_pending_via_controller
    vault = FakeVault.new

    Solana::Vault.stub :new, vault do
      Rails.stub :env, ActiveSupport::StringInquirer.new("production") do
        refute Rails.env.test?, "the env short-circuit must be off or this test proves nothing"
        contest.save!
      end
    end

    assert_empty vault.server_funded_calls,
      "saving the write-ahead row fired the SERVER-FUNDED create_contest — a second " \
      "prize pool paid from the house wallet"
  end

  # The explicit half of the guard, pinned on its own so dropping
  # `skip_onchain_callback = true` reddens something. The test above cannot see
  # that drop (the PDA covers it); this one fails immediately.
  test "the write-ahead builder sets the explicit skip_onchain_callback flag" do
    assert_equal true, build_pending_via_controller.skip_onchain_callback,
      "the write-ahead row must opt out of the server-funded callback EXPLICITLY, " \
      "not merely by accident of carrying a PDA"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ACCEPTANCE 1 — THE ROW AND ITS PDA PERSIST BEFORE THE BROADCAST
  # ───────────────────────────────────────────────────────────────────────────

  test "the contest row carrying its PDA is already durable when the money moves" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-write-ahead", name: "Order Write Ahead")
    vault = BroadcastSnapshotVault.new
    vault.watch_slug = "order-write-ahead"

    run_finalize(create_json, vault)
    assert_response :success

    snap = vault.row_at_broadcast
    refute_nil snap, "no contest row existed at the moment the prize pool moved"
    assert snap[:persisted], "the row at broadcast time was not persisted"
    assert_equal "pending", snap[:status],
      "the write-ahead row must rest in `pending` until the broadcast is verified"
    assert_equal create_json["contest_pda"], snap[:onchain_contest_id],
      "the row must carry the derived PDA — it is the only key a sweeper can adopt it by"
    assert_nil snap[:onchain_tx_signature],
      "there is no signature to record until the broadcast returns one"
  end

  # THE INVERTED FAILURE MODE, which is the whole point of the change. A raise at
  # the broadcast used to leave nothing behind. It must now leave a row that
  # names the PDA, so an operator (and PR 2's sweeper) can find the money.
  test "a broadcast failure leaves a recoverable pending row naming the PDA" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-strand", name: "Order Strand")
    vault = FakeVault.new
    vault.create_cosign_broadcast_raises = "RPC blockhash not found"

    run_finalize(create_json, vault)

    assert_response :unprocessable_entity
    stranded = Contest.find_by(slug: "order-strand")
    refute_nil stranded, "the failed attempt left NO row — the money would be unreachable"
    assert_equal "pending", stranded.status
    assert_equal create_json["contest_pda"], stranded.onchain_contest_id
    assert_nil stranded.onchain_tx_signature
  end

  # The read-back is the step most likely to raise on a PERFECTLY GOOD
  # broadcast — an RPC hiccup between send and confirm. The signature is the
  # only off-chain evidence tying the request to the on-chain effect, so it is
  # stamped BEFORE the read-back rather than after it.
  test "a failed read-back still leaves the broadcast signature on the row" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-verify-fail", name: "Order Verify Fail")

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        raiser = ->(**) { raise Solana::TxVerifier::VerificationError, "RPC read-back timed out" }
        Solana::TxVerifier.stub :verify!, raiser do
          post finalize_contests_path, params: {
            params_token: create_json["params_token"],
            contest_pda:  create_json["contest_pda"],
            signed_tx:    "SIGNED_CREATE_WIRE"
          }, as: :json
        end
      end
    end

    assert_response :unprocessable_entity
    contest = Contest.find_by(slug: "order-verify-fail")
    refute_nil contest
    assert_equal "pending", contest.status,
      "an unverified broadcast must NOT be published — `open` is the verified state"
    assert_equal "fake-create-cosign-broadcast-sig", contest.onchain_tx_signature,
      "the signature must be stamped before the read-back, not after it"
  end

  # A BEHAVIOUR CHANGE WORTH STATING. The slug guard asks the DATABASE. With no
  # row it failed OPEN, so a retry sailed past it and died on chain instead
  # (Anchor `init` on an existing PDA — `custom program error: 0x0`, refused at
  # pre-flight simulation, so no second charge but no recovery either). The
  # write-ahead row makes that guard fail CLOSED and say so in words.
  #
  # This is the slug-squat cost, and it is worth being precise about who caused
  # it: the on-chain PDA already locked that slug the moment the broadcast
  # landed. The pending row does not create the lockout — it RECORDS one that
  # was previously invisible. PR 2's sweeper is what clears it.
  test "a retry after a strand is refused by the slug guard, not by the chain" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-retry", name: "Order Retry")
    failing = FakeVault.new
    failing.create_cosign_broadcast_raises = "RPC down"
    run_finalize(create_json, failing)
    assert_equal "pending", Contest.find_by(slug: "order-retry").status

    second = FakeVault.new
    run_finalize(create_json, second)

    assert_response :unprocessable_entity
    assert_match(/already exists/i, JSON.parse(response.body)["error"])
    assert_empty second.create_cosign_broadcast_calls,
      "the retry must be refused BEFORE it can broadcast against the existing PDA"
  end

  # A strand must be diagnosable, not just recoverable. capture_unlogged only
  # PERSISTS an ErrorLog when it is given a target (contests_controller.rb:1878),
  # so before the write-ahead row existed this rescue logged nothing at all.
  test "a failure after the row exists files an ErrorLog against that contest" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-logged", name: "Order Logged")
    vault = FakeVault.new
    vault.create_cosign_broadcast_raises = "RPC blockhash not found"

    assert_difference -> { ErrorLog.count }, 1 do
      run_finalize(create_json, vault)
    end

    log = ErrorLog.order(:id).last
    assert_equal "order-logged", log.target_name
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ACCEPTANCE 3 — THE IMAGE ATTACH HAPPENS AFTER THE PROMOTE
  # ───────────────────────────────────────────────────────────────────────────

  # ActiveStorage uploads to S3 on attach — a network call on a user-supplied
  # file, and the widest failure window in the method.
  #
  # THE POSITION AND THE RESCUE ARE TWO SEPARATE PROTECTIONS, and this file
  # learned the hard way to test them separately. #attach_contest_banner
  # swallows its own failure, so a test that only makes the upload FAIL cannot
  # tell where the attach sits: with the rescue in place, moving it back above
  # the promote changes nothing that test can see. (Measured — that mutation
  # survived the first version of this file.) So:
  #
  #   * the ORDER is pinned by observing the contest's status AT attach time
  #   * the RESCUE is pinned by making the upload fail and checking the request
  #
  # There is no mocha in this suite, so both are driven by one prepend that is
  # inert unless a thread-local asks for it. `record` is the attachment's owner
  # (ActiveStorage::Attached#record), which is the contest being finalized.
  module AttachSpy
    def attach(*args)
      if (probe = Thread.current[:tm_attach_probe])
        probe << record.status
        raise "S3 upload failed" if Thread.current[:tm_raise_on_attach]
      end

      super
    end
  end
  ActiveStorage::Attached::One.prepend(AttachSpy)

  def with_attach_probe(raising: false)
    Thread.current[:tm_attach_probe] = []
    Thread.current[:tm_raise_on_attach] = raising
    yield
    Thread.current[:tm_attach_probe]
  ensure
    Thread.current[:tm_attach_probe] = nil
    Thread.current[:tm_raise_on_attach] = false
  end

  # ACCEPTANCE 3, asserted on the ordering itself rather than on a consequence
  # of it. If the attach runs before the promote it sees `pending`.
  test "the banner is attached only after the contest has been promoted to open" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-image-ok", name: "Order Image Ok")

    statuses = with_attach_probe do
      run_finalize(create_json, FakeVault.new, { contest_image: uploaded_banner }, multipart: true)
    end

    assert_response :success
    assert_equal ["open"], statuses,
      "the banner was attached while the contest was still `pending` — an S3 " \
      "upload sitting between the broadcast and the promote can strand a FUNDED " \
      "contest at `pending`, which is the whole reason it moved"

    contest = Contest.find_by(slug: "order-image-ok")
    assert_equal "open", contest.status
    assert contest.contest_image.attached?
  end

  # The rescue: a banner is cosmetic and must not be able to fail a request that
  # has already moved the creator's money.
  test "a failed image upload cannot fail an otherwise successful finalize" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-image", name: "Order Image")

    with_attach_probe(raising: true) do
      run_finalize(create_json, FakeVault.new, { contest_image: uploaded_banner }, multipart: true)
    end

    assert_response :success,
      "a failed banner upload told the user their contest failed — it exists and is funded"
    contest = Contest.find_by(slug: "order-image")
    assert_equal "open", contest.status
    assert_equal "fake-create-cosign-broadcast-sig", contest.onchain_tx_signature
    refute contest.contest_image.attached?, "the control: the upload really did fail"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # THE PROMOTE
  # ───────────────────────────────────────────────────────────────────────────

  test "a verified broadcast promotes the row to open and records the signature" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-promote", name: "Order Promote")

    run_finalize(create_json, FakeVault.new)

    assert_response :success
    contest = Contest.find_by(slug: "order-promote")
    assert_equal "open", contest.status
    assert_equal create_json["contest_pda"], contest.onchain_contest_id
    assert_equal "fake-create-cosign-broadcast-sig", contest.onchain_tx_signature
    assert_equal admin_phantom.id, contest.user_id
    assert_equal true, contest.accepts_usdt
  end

  # A `pending` contest must stay out of the listings while it is unverified.
  # ContestsController#index filters status: [:open, :settled], so this holds by
  # construction — pinned here so a future widening of that filter has to argue
  # with a test rather than silently publish half-created contests.
  test "a pending contest is invisible on the contests index" do
    log_in_as(admin_phantom)
    create_json = run_create(slug: "order-hidden", name: "Order Hidden")
    vault = FakeVault.new
    vault.create_cosign_broadcast_raises = "RPC down"
    run_finalize(create_json, vault)
    assert_equal "pending", Contest.find_by(slug: "order-hidden").status

    get contests_path
    assert_response :success
    assert_no_match(/Order Hidden/, response.body)
  end

  private

  # Builds the row #finalize writes ahead of the broadcast, through the
  # controller's own private builder, so this file cannot drift from the
  # controller by re-describing what it does.
  def build_pending_via_controller
    controller = ContestsController.new
    user = admin_phantom
    controller.define_singleton_method(:current_user) { user }
    controller.send(:build_pending_contest, pending_payload, "PdA1111111111111111111111111111111111111")
  end

  def pending_payload
    {
      slug: "order-builder-contest",
      name: "Order Builder Contest",
      slate_id: @slate.id,
      contest_type: "tiny",
      starts_at: 30.days.from_now.iso8601,
      locks_at_date_selected: nil,
      locks_at_time_selected: nil,
      locks_at_timezone_selected: nil,
      entry_fee_cents: 500,
      max_entries: 10,
      season_id: 0,
      coming_soon: false,
      user_id: admin_phantom.id,
      creator_pubkey: "FakePubkey11111111111111111111111111111111"
    }.with_indifferent_access
  end

  def uploaded_banner
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/banner.png"),
      "image/png"
    )
  end
end
