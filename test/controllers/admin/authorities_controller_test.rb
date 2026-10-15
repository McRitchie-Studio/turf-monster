require "test_helper"
require "minitest/mock"

# /admin/authorities — the read-only authority overview, and the eviction.
#
# ── WHAT THIS FILE IS ACTUALLY DEFENDING ─────────────────────────────────────
#
# Three properties, each of which has a known way of going wrong elsewhere in
# this app:
#
#   1. REFUSALS ARE TESTED, NOT JUST THE HAPPY PATH. A console that will
#      cheerfully arm a rotation the chain refuses spends a ceremony and three
#      Phantom dialogs to learn `0x17a4`.
#   2. THE COUNT OF CLAIMED SIGNERS IS CHECKED, not merely each one's
#      membership. A three-signature action recorded on one proven signature is
#      a third of the claim written down as the whole of it.
#      `Admin::VaultStateController#confirm` had exactly that gap and now runs
#      the same count through `CosignPlan#validate_extras!`.
#   3. THE SIGNATURE IS STAMPED BEFORE VERIFICATION, and the row is CLAIMED
#      before the wire goes out. The treasury path stamped it after
#      (/tasks/broadcast-records-signature-late), so a landed transaction whose
#      verify flaked stayed `pending` and re-broadcastable; both paths now share
#      one rule on the model. On THIS surface a second attempt would be
#      authorized by keys the first one just evicted — it fails `Unauthorized`
#      and reads to the operator like his eviction did not work, mid-incident,
#      on the one control he has.
class Admin::AuthoritiesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  SYSTEM = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  ALEX   = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON  = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  ALEX2  = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  ALEX3  = "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf".freeze
  EMPTY  = Solana::SignerRotation::EMPTY

  # A REAL wire, because #broadcast compares the signed message with the one
  # the row stored. One unsigned slot is enough; nothing here verifies it.
  WIRE = begin
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
    tx.add_signer(Solana::Keypair.generate)
    tx.add_instruction(program_id: Solana::Keypair.generate.public_key_bytes, accounts: [], data: "\x01".b)
    tx.serialize_base64
  end.freeze

  # A Solana::Vault stand-in. `governance:` drives which PROGRAM SHAPE the chain
  # is reporting — absent GovernanceConfig is v0.25, which is what both clusters
  # actually run today.
  class StubVault
    attr_reader :build_calls, :broadcast_calls
    attr_accessor :signers

    # `on_build:` runs INSIDE #build_update_signers, which is the only way to
    # model the interleaving #rebuild's guard actually has to survive: a
    # concurrent #broadcast claiming the row AFTER this action read `pending?`
    # and BEFORE it writes. Claiming the row before the request instead is a
    # different test — it trips the guard at the top of the action and never
    # reaches the UPDATE that carried the defect.
    def initialize(signers: [SYSTEM, ALEX, MASON], governance: nil, broadcast_raises: nil,
                   read_back: nil, signature_statuses: {}, on_build: nil, account_infos: {})
      @signers = signers
      @governance = governance
      @broadcast_raises = broadcast_raises
      @read_back = read_back
      @signature_statuses = signature_statuses
      @on_build = on_build
      @account_infos = account_infos
      @build_calls = []
      @broadcast_calls = []
    end

    def read_vault_state(**)
      {
        pda: "VAULTPDA", signers: @signers.first(3),
        signers_ext: [EMPTY, EMPTY],
        signer_slots: @signers.first(5) + Array.new([5 - @signers.length, 0].max, EMPTY),
        active_signers: @read_back || @signers,
        active_signer_count: (@read_back || @signers).length,
        threshold: 2, bump: 254, paused: false,
        payout_mint: "MINT", treasury_authority: "TREASURY",
        accepted_currencies: [], registered_currencies: []
      }
    end

    def read_governance(**) = @governance

    # REAL 32-byte pubkey bytes, so `Keypair.encode_base58` can run for real in
    # the render path. Stubbing the encoder instead broke `Keypair.admin.to_base58`
    # — which calls it — and the page rendered a raw binary key into UTF-8 HTML.
    def governance_pda = [Solana::Keypair.decode_base58(ALEX3), 255]
    def vault_state_pda = [Solana::Keypair.decode_base58(ALEX2), 254]

    def fee_payer_status(required_signatures: 3, address: nil)
      { address: address, balance_sol: 1.0, minimum_sol: 0.01, funded: true }
    end

    def build_update_signers(new_signers:, cosigner_pubkey:, lead_signer: nil, extra_cosigners: [],
                             server_cosigners: [], durable_nonce: nil)
      @build_calls << { new_signers: new_signers, cosigner: cosigner_pubkey,
                        lead: lead_signer, extras: extra_cosigners,
                        server_cosigners: server_cosigners.map(&:to_base58), durable_nonce: durable_nonce }
      @on_build&.call
      # The real builder signs account 0 itself exactly when the lead is the
      # server's own key; the stub answers the same way.
      { serialized_tx: WIRE, vault_pda: "VAULTPDA", new_signers: new_signers,
        slot_width: 3, lead_signer: lead_signer,
        server_signed: lead_signer.present? && lead_signer == Solana::CosignPlan.admin_address,
        server_cosigned: server_cosigners.map(&:to_base58),
        durable_nonce: durable_nonce && durable_nonce.merge(value: @nonce_value_at_build) }
    end

    attr_accessor :nonce_value_at_build

    # A seeded STRING models a PRE-FLIGHT refusal, which the real method raises
    # as `Solana::Vault::PreflightRejected` — the type that proves nothing left
    # the server and is therefore the only fault that releases a broadcast
    # claim. Seed an exception instance to model an AMBIGUOUS failure after the
    # send, where the wire may already be on chain.
    def simulate_and_broadcast(wire)
      @broadcast_calls << wire
      if @broadcast_raises
        raise(@broadcast_raises.is_a?(String) ? Solana::Vault::PreflightRejected.new(@broadcast_raises)
                                              : @broadcast_raises)
      end

      signature_for_wire(wire)
    end

    # The signature is a fact about the BYTES, derived before the send — which
    # is what lets the claim record it and a failed broadcast stay recoverable.
    # It agrees with `#simulate_and_broadcast` above so the real method's
    # decoder self-check is modelled rather than side-stepped.
    def signature_for_wire(_wire) = "LANDED_SIGNATURE"

    def client = @client ||= FakeSolanaClient.new(@signature_statuses || {}, account_infos: @account_infos)
  end

  setup do
    @admin = users(:alex)
    log_in_as(@admin)
  end

  def with_vault(vault, &block)
    Solana::Vault.stub(:new, vault, &block)
  end

  # A rotation row in the shape #create_rotation records, before its build:
  # the member endpoints (rebuild, broadcast, cancel, reconcile) read exactly
  # this. Seeded directly, because the form that armed one is gone and the
  # console creates rows only at the click that signs them.
  def arm(vault, signers:, authorizers:, server_held: [])
    rotation = Solana::SignerRotation.for_chain(current_signers: vault.signers, proposed: signers,
                                                authorizers: authorizers, governance: false).validate!
    lead = rotation.authorizers.first
    plan = rotation.to_plan.merge(lead_signer: lead, server_leads: lead == Solana::CosignPlan.admin_address,
                                  server_held: server_held, armed_at: Time.current.iso8601)
    PendingTransaction.create!(tx_type: "update_signers", serialized_tx: Admin::AuthoritiesController::UNBUILT_WIRE,
                               target: nil, initiator_address: Solana::CosignPlan.admin_address,
                               metadata: { plan: plan }.to_json)
  end

  def plan_json(vault, **params)
    with_vault(vault) { post admin_plan_authority_rotation_path, params: params, as: :json }
    JSON.parse(response.body)
  end

  # ── THE OVERVIEW ─────────────────────────────────────────────────────────

  test "the page renders and names all three authorities distinctly" do
    with_vault(StubVault.new) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path
      end
    end

    assert_response :success
    assert_match(/Vault signer set/, response.body)
    assert_match(/Program upgrade authority/, response.body)
    assert_match(/Server signing identity/, response.body)
  end

  test "the page says plainly that pause is not a remedy" do
    # The single most important sentence on this surface. An operator who
    # believes pausing contains a key compromise will pause, feel safe, and
    # leave the thief minting entry tokens.
    with_vault(StubVault.new) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path
      end
    end

    assert_match(/pausing is not a remedy/i, response.body)
    assert_match(/still mints entry tokens/i, response.body)
    assert_match(/Eviction is the only real answer/i, response.body)
  end

  test "an absent GovernanceConfig is reported as pre-v0.26, not as an empty table" do
    with_vault(StubVault.new(governance: nil)) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path
      end
    end

    assert_match(/the deployed program is pre-v0\.26/i, response.body)
    assert_match(/structurally two/i, response.body)
    assert_match(/not on chain/, response.body)
  end

  test "a signed-in non-admin cannot reach the page" do
    # The page names every key that can move money on this platform, so the
    # gate is asserted rather than assumed from the before_action's presence.
    log_in_as(users(:jordan))
    get admin_authorities_path
    assert_response :redirect
    assert_no_match(/Vault signer set/, response.body)
  end

  test "a signed-in non-admin can neither plan nor sign" do
    log_in_as(users(:jordan))
    assert_no_difference -> { PendingTransaction.count } do
      post admin_plan_authority_rotation_path, params: { intent: "replace", remove: [MASON], add: [ALEX2] }, as: :json
      post admin_authority_rotations_path, params: { intent: "replace", remove: [MASON], add: [ALEX2] }, as: :json
    end
    assert_response :redirect
  end

  # ── PLAN: JSON, NO ROW, EVERY REFUSAL NAMED ───────────────────────────────
  #
  # In the test env this process's admin key is not seated in the stub set
  # [SYSTEM, ALEX, MASON], so a plan is operator-led; the test network is
  # devnet, where that is allowed. The derivation matrix itself is
  # test/services/solana/signer_plan_test.rb.

  def server = Solana::CosignPlan.admin_address

  test "plan derives the set, the signers and the prompt count, and writes no row" do
    vault = StubVault.new(signers: [server, ALEX, MASON])
    body = nil
    assert_no_difference -> { PendingTransaction.count } do
      body = plan_json(vault, intent: "replace", remove: [MASON], add: [ALEX2])
    end

    assert_response :success
    assert body["ok"]
    assert_equal [server, ALEX, ALEX2], body["proposed"]
    assert_equal [server, ALEX], body["authorizers"]
    assert_equal [ALEX], body["phantom_queue"]
    assert_equal 1, body["prompt_count"]
    assert body["server_leads"]
    assert_match(/You sign once in Phantom as 7ZDJ…9Tcr/, body["sentence"])
    assert_empty vault.build_calls, "planning builds nothing"
  end

  {
    "bad_address" => { add: ["#{ALEX2}."] },
    "zero_key" => { add: [EMPTY] },
    "already_seated" => { add: [ALEX] },
    "not_seated" => { remove: [ALEX3] }
  }.each do |code, extra|
    test "plan refuses with #{code} and writes nothing" do
      params = { intent: "replace", remove: [MASON], add: [ALEX2] }.merge(extra)
      body = nil
      assert_no_difference -> { PendingTransaction.count } do
        body = plan_json(StubVault.new(signers: [server, ALEX, MASON]), **params)
      end
      assert_response :unprocessable_entity
      assert_equal code, body["code"]
      assert_equal false, body["ok"]
    end
  end

  test "plan does not echo a value long enough to be a secret" do
    secret_shaped = ALEX * 2
    body = plan_json(StubVault.new(signers: [server, ALEX, MASON]), intent: "replace", remove: [MASON], add: [secret_shaped])
    assert_equal "bad_address", body["code"]
    assert_match(/88-character value/, body["message"])
    assert_no_match(/#{secret_shaped}/, response.body)
  end

  test "plan refuses an intent the deployed program cannot express, and says why" do
    body = plan_json(StubVault.new(signers: [server, ALEX, MASON]), intent: "add", add: [ALEX2])
    assert_equal "intent_not_allowed", body["code"]
    assert_match(/no empty slot/, body["message"])
  end

  test "plan names the chain rule and its code when the set breaks one" do
    vault = StubVault.new(signers: [server, ALEX, MASON, ALEX2, ALEX3], governance: { thresholds: Array.new(32, 0) })
    body = Solana::Config.stub(:governance?, true) do
      Solana::Governance.stub(:max_live_threshold, 4) do
        plan_json(vault, intent: "remove", remove: [MASON, ALEX3])
      end
    end
    assert_equal "chain_rule", body["code"]
    assert_equal 6052, body["chain_code"]
  end

  test "plan refuses when the app switch and the chain disagree about the program" do
    body = Solana::Config.stub(:governance?, true) do
      plan_json(StubVault.new(signers: [server, ALEX, MASON], governance: nil),
                intent: "replace", remove: [MASON], add: [ALEX2])
    end
    assert_equal "shape_mismatch", body["code"]
    assert_match(/init_governance/, body["message"])
  end

  test "plan refuses to plan blind when the vault state cannot be read" do
    blind = StubVault.new
    blind.define_singleton_method(:read_vault_state) { |**| nil }
    body = plan_json(blind, intent: "replace", remove: [MASON], add: [ALEX2])
    assert_response :service_unavailable
    assert_match(/refusing to plan a rotation blind/i, body["message"])
  end

  # ── SIGN: ROW AND BYTES IN ONE REQUEST ────────────────────────────────────

  # What the console sends: the reviewed draft, and the set and signers it
  # was reviewed as.
  def reviewed(proposed:, authorizers:, **draft)
    { intent: "replace", remove: [MASON], add: [ALEX2] }.merge(draft)
      .merge(reviewed_proposed: proposed, reviewed_authorizers: authorizers)
  end

  test "rotations creates the row and builds it at once, returning the queue and the urls" do
    vault = StubVault.new(signers: [server, ALEX, MASON])
    assert_difference -> { PendingTransaction.count }, 1 do
      with_vault(vault) do
        post admin_authority_rotations_path,
             params: reviewed(proposed: [server, ALEX, ALEX2], authorizers: [server, ALEX]), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    row = PendingTransaction.last
    assert_equal WIRE, body["serialized_tx"]
    assert_equal WIRE, row.serialized_tx
    assert_equal [ALEX], body["signer_queue"]
    assert_equal [server], body["server_signed"]
    assert_equal row.slug, body["slug"]
    assert_equal admin_broadcast_authority_rotation_path(row.slug), body["broadcast_url"]
    assert_equal admin_cancel_authority_rotation_path(row.slug), body["cancel_url"]
    plan = JSON.parse(row.metadata)["plan"]
    assert_equal [server, ALEX], plan["authorizers"]
    assert_equal server, vault.build_calls.first[:lead]
  end

  test "rotations refuses, building nothing, unless the fresh plan equals the reviewed set and signers" do
    vault = StubVault.new(signers: [server, ALEX, MASON])
    assert_no_difference -> { PendingTransaction.count } do
      with_vault(vault) do
        # A pick changed after review: the operator reviewed ALEX2 joining,
        # the live draft now adds ALEX3.
        post admin_authority_rotations_path,
             params: reviewed(proposed: [server, ALEX, ALEX2], authorizers: [server, ALEX], add: [ALEX3]), as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_equal "reviewed_set_mismatch", JSON.parse(response.body)["code"]
    assert_empty vault.build_calls

    with_vault(vault) do
      post admin_authority_rotations_path,
           params: reviewed(proposed: [server, ALEX, ALEX2], authorizers: [ALEX, server]), as: :json
    end
    assert_equal "reviewed_set_mismatch", JSON.parse(response.body)["code"], "signer order is part of the review"

    with_vault(vault) { post admin_authority_rotations_path, params: { intent: "replace", remove: [MASON], add: [ALEX2] }, as: :json }
    assert_equal "reviewed_set_mismatch", JSON.parse(response.body)["code"], "no reviewed set, no build"
  end

  test "a build whose bytes carry a different set than the recorded plan writes and returns nothing" do
    vault = StubVault.new(signers: [ALEX, MASON, SYSTEM])
    row = arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    vault.define_singleton_method(:build_update_signers) do |**|
      { serialized_tx: "WRONG_SET_WIRE", new_signers: [ALEX, MASON, ALEX3], server_signed: false, server_cosigned: [] }
    end
    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }
    assert_response :unprocessable_entity
    assert_match(/differs from the recorded plan/, JSON.parse(response.body)["error"])
    assert_equal Admin::AuthoritiesController::UNBUILT_WIRE, row.reload.serialized_tx
  end

  test "rotations refuses while another rotation is in flight" do
    vault = StubVault.new(signers: [server, ALEX, MASON])
    arm(vault, signers: [server, ALEX, ALEX2], authorizers: [server, ALEX])
    assert_no_difference -> { PendingTransaction.count } do
      with_vault(vault) do
        post admin_authority_rotations_path, params: { intent: "replace", remove: [MASON], add: [ALEX2] }, as: :json
      end
    end
    assert_response :conflict
    assert_equal "rotation_in_flight", JSON.parse(response.body)["code"]
  end

  test "a refused plan creates no row on the sign path either" do
    assert_no_difference -> { PendingTransaction.count } do
      with_vault(StubVault.new(signers: [server, ALEX, MASON])) do
        post admin_authority_rotations_path, params: { intent: "replace", remove: [MASON], add: ["#{ALEX2}."] }, as: :json
      end
    end
    assert_equal "bad_address", JSON.parse(response.body)["code"]
  end

  # ── SERVER-HELD COSIGNERS ─────────────────────────────────────────────────

  test "a server-held cosigner signs on the server and is never queued, echoed or logged" do
    held = Solana::Keypair.generate
    secret = Solana::Keypair.encode_base58(held.to_bytes)
    vault = StubVault.new(signers: [server, ALEX, held.to_base58, MASON, ALEX3],
                          governance: { thresholds: Array.new(32, 0) })
    log = StringIO.new
    Rails.logger.broadcast_to(logger = ActiveSupport::Logger.new(log))
    begin
      Solana::Keypair.stub(:cosigners, [held]) do
        Solana::Config.stub(:governance?, true) do
          with_vault(vault) do
            post admin_authority_rotations_path,
                 params: reviewed(proposed: [server, ALEX, held.to_base58, ALEX2, ALEX3],
                                  authorizers: [server, held.to_base58, ALEX]), as: :json
          end
        end
      end
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ALEX], body["signer_queue"], "Phantom is asked only for Alex"
    assert_includes body["server_signed"], held.to_base58
    assert_equal [held.to_base58], vault.build_calls.first[:server_cosigners]
    refute_includes response.body, secret
    refute_includes log.string, secret
    refute_includes PendingTransaction.last.metadata, secret
  end

  test "a build whose planned window cosigner is no longer held refuses" do
    gone = Solana::Keypair.generate.to_base58
    vault = StubVault.new(signers: [server, ALEX, gone])
    row = arm(vault, signers: [server, ALEX, gone], authorizers: [server, gone])
    row.update!(metadata: JSON.parse(row.metadata).tap { |m| m["plan"]["server_held"] = [gone] }.to_json)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }
    assert_response :unprocessable_entity
    assert_match(/no longer holds it/, JSON.parse(response.body)["error"])
    assert_empty vault.build_calls
  end

  # ── THE CONSOLE STATE AND THE DEAD STATES ─────────────────────────────────

  test "console answers the rules, the set and the labels, unknown keys included" do
    unknown = Solana::Keypair.generate.to_base58
    with_vault(StubVault.new(signers: [server, ALEX, unknown])) do
      get admin_authority_console_path(connected: ALEX), as: :json
    end
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "v0.25", body["rules"]["shape"]
    assert_equal 3, body["rules"]["max_slots"]
    assert body["labels"][unknown]["unknown"]
    assert body["labels"][ALEX]["connected"]
    assert_equal "Alex, Phantom account 1", body["labels"][ALEX]["name"]
  end

  test "an abandoned pending rotation is expired before the page reads; a submitted one never is" do
    vault = StubVault.new
    old = arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    old.update_columns(created_at: 3.minutes.ago)
    stranded = arm(vault, signers: [ALEX, MASON, ALEX3], authorizers: [ALEX, MASON])
    stranded.update_columns(created_at: 3.minutes.ago, status: "submitted", tx_signature: "SIG")

    with_vault(vault) { get admin_authority_console_path, as: :json }

    assert_equal "expired", old.reload.status
    assert_equal "submitted", stranded.reload.status
    assert_equal stranded.slug, JSON.parse(response.body).dig("live_rotation", "slug")
  end

  test "cancel answers JSON for the console's decline path" do
    row = arm(StubVault.new, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    post admin_cancel_authority_rotation_path(row.slug), as: :json
    assert_response :success
    assert JSON.parse(response.body)["ok"]
    assert_equal "expired", row.reload.status
  end

  test "the page pre-fills the console from a ceremony link and ships its CTA disabled" do
    with_vault(StubVault.new) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path(intent: "add", add: "#{ALEX2},#{ALEX3}")
      end
    end
    assert_select "[data-controller='signer-console'][data-signer-console-intent-value='add']"
    assert_select "[data-signer-console-add-value='#{ALEX2},#{ALEX3}']"
    assert_select "button[data-signer-console-target='cta'][disabled]"
    assert_select "[data-controller='signer-console'] script", false, "no inline script in the console"
    assert_select "[data-controller='signer-console'] [x-data], [data-controller='signer-console'] [x-show]", false
  end

  # ── THE CEREMONY CHECKLIST ────────────────────────────────────────────────

  test "the ceremony page renders this cluster's steps with their verdicts" do
    steps = [{ "id" => "add", "kind" => "console", "title" => "ADD a key", "who" => "Alex",
               "start" => [server, ALEX, MASON], "end" => [server, ALEX, MASON, ALEX2],
               "server" => server, "window_cosigners" => [], "intent" => "replace",
               "remove" => [MASON], "add" => [ALEX2] },
             { "id" => "flip", "kind" => "runbook", "title" => "Flip", "who" => "Steffon",
               "runbook" => "the flip", "done_when" => { "server" => server } }]
    real = Solana::SignerCeremony.method(:new)
    with_vault(StubVault.new(signers: [server, ALEX, MASON])) do
      Solana::SignerCeremony.stub(:new, ->(**kw) { real.call(**kw, steps: steps) }) do
        get admin_authority_ceremony_path
      end
    end

    assert_response :success
    assert_select "[data-ceremony-step='add'][data-status='ready']"
    assert_select "a[data-ceremony-link='add'][href=?]", "/admin/authorities?add=#{ALEX2}&intent=replace&remove=#{MASON}"
    assert_select "[data-ceremony-step='flip'][data-status='done']"
    assert_select "[data-check='chain_set'][data-ok='true']"
  end

  test "a red hard check disables the step's console link" do
    steps = [{ "id" => "add", "kind" => "console", "title" => "ADD", "who" => "Alex",
               "start" => [server, ALEX, MASON], "end" => [server, ALEX, MASON, ALEX2],
               "server" => server, "window_cosigners" => [ALEX3], "intent" => "add", "add" => [ALEX2] }]
    real = Solana::SignerCeremony.method(:new)
    with_vault(StubVault.new(signers: [server, ALEX, MASON])) do
      Solana::SignerCeremony.stub(:new, ->(**kw) { real.call(**kw, steps: steps) }) do
        get admin_authority_ceremony_path
      end
    end
    assert_select "[data-ceremony-step='add'][data-status='blocked']"
    assert_select "a[data-ceremony-link]", false
    assert_select "[data-ceremony-link-disabled='add']"
    assert_select "[data-check='window_cosigners'][data-ok='false']"
  end

  test "the committed mainnet checklist parses into console and runbook steps" do
    steps = YAML.safe_load_file(Solana::SignerCeremony::PATH)
    assert_equal %w[add flip evict unset], steps["mainnet-beta"].map { |s| s["id"] }
    roster = Solana::SignerRoster.default
    keys = steps.values.flatten.flat_map { |st| Array(st["start"]) + Array(st["end"]) + Array(st["add"]) }.uniq
    keys.reject { |key| Solana::SignerCeremony.unminted?(key) }.each do |key|
      assert roster.include?(key), "#{key} is in the checklist but not the roster"
    end
  end

  # ── SQUADS PROPOSALS ──────────────────────────────────────────────────────

  test "proposals answers the open list as JSON, and approve refuses a malformed member" do
    fake = Object.new
    fake.define_singleton_method(:network) { "devnet" }
    fake.define_singleton_method(:squads_url) { "https://app.squads.so/squads/VAULT/transactions" }
    fake.define_singleton_method(:vault_pda) { "VAULT" }
    fake.define_singleton_method(:open_proposals) { |connected:| [{ index: 9, connected: connected }] }
    Solana::SquadsProposals.stub(:new, fake) do
      get admin_authority_proposals_path(connected: ALEX), as: :json
    end
    body = JSON.parse(response.body)
    assert_equal [{ "index" => 9, "connected" => ALEX }], body["proposals"]

    post admin_approve_authority_proposal_path(index: 9), params: { member: "#{ALEX}." }, as: :json
    assert_response :unprocessable_entity
    assert_equal "bad_address", JSON.parse(response.body)["code"]
  end

  test "approve answers the unsigned vote, or the page's refusal by code" do
    fake = Object.new
    fake.define_singleton_method(:build_approve) do |index:, member:|
      raise Solana::SquadsProposals::Refusal.new("no", code: "not_approvable") if index == 2

      { serialized_tx: "UNSIGNED", index: index, member: member }
    end
    Solana::SquadsProposals.stub(:new, fake) do
      post admin_approve_authority_proposal_path(index: 1), params: { member: ALEX }, as: :json
      assert_equal "UNSIGNED", JSON.parse(response.body)["serialized_tx"]
      post admin_approve_authority_proposal_path(index: 2), params: { member: ALEX }, as: :json
      assert_equal "not_approvable", JSON.parse(response.body)["code"]
    end
  end

  # ── REBUILD ──────────────────────────────────────────────────────────────

  test "rebuild mints fresh bytes and sends the signing plan with them" do
    vault = StubVault.new
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    row = PendingTransaction.last

    with_vault(vault) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal WIRE, body["serialized_tx"]
    assert_equal [ALEX, MASON], body["signer_queue"]
    assert_equal 2, body["required_signatures"]
    # NIL when the operator leads — cosign.js paints this row as already signed,
    # and it is only true when the SERVER filled the slot at build time.
    assert_nil body["fee_payer_address"]
    assert_equal [ALEX, MASON, ALEX2], vault.build_calls.first[:new_signers]
    assert_equal ALEX, vault.build_calls.first[:lead]
  end

  test "rebuild re-validates against a FRESH chain read, not the armed plan" do
    # The signer set can move between arming and clicking — by another operator,
    # or by the very thief this page exists to evict. A rotation validated
    # against a stale set could break continuity and brick governance.
    vault = StubVault.new
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    row = PendingTransaction.last

    vault.signers = [SYSTEM, ALEX, ALEX3] # MASON is gone; he can no longer authorize

    with_vault(vault) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/Unauthorized, 6000/, JSON.parse(response.body)["error"])
    assert_empty vault.build_calls, "nothing may be built against a stale set"
  end

  test "rebuild refuses when this app and the chain disagree about the program version" do
    # Every builder routes its shape through Config.governance?. When that
    # disagrees with the chain, the account list and the argument describe a
    # program that is not there, and the failure arrives as an opaque
    # deserialization error after a fee.
    vault = StubVault.new(governance: nil)
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    row = PendingTransaction.last

    Solana::Config.stub(:governance?, true) do
      with_vault(vault) do
        post admin_rebuild_authority_rotation_path(row.slug), as: :json
      end
    end

    assert_response :unprocessable_entity
    error = JSON.parse(response.body)["error"]
    assert_match(/does not exist on/, error)
    assert_match(/init_governance/, error)
    assert_empty vault.build_calls
  end

  test "rebuild refuses a row that is no longer pending" do
    vault = StubVault.new
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    row = PendingTransaction.last
    row.update!(status: "confirmed")

    with_vault(vault) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/is confirmed, not pending/, JSON.parse(response.body)["error"])
  end

  # ── BROADCAST ────────────────────────────────────────────────────────────

  def armed_row(vault)
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    PendingTransaction.last.tap { |row| row.update!(serialized_tx: WIRE) }
  end

  # The broadcast POST, with verification stubbed green — used by the tests that
  # are about what happens to the ROW when the send itself fails.
  def broadcast_row(row)
    Solana::TxVerifier.stub :verify!, true do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [ALEX, MASON] }, as: :json
    end
  end

  test "broadcast records the landed signature, confirms, and reads the set back" do
    vault = StubVault.new(read_back: [ALEX, MASON, ALEX2])
    row = armed_row(StubVault.new)

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, true do
        post admin_broadcast_authority_rotation_path(row.slug),
             params: { signed_tx: WIRE, signer_queue: [ALEX, MASON] }, as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "LANDED_SIGNATURE", body["tx_signature"]
    assert_equal [ALEX, MASON, ALEX2], body["signers"], "the read-back is from chain, not the plan"

    row.reload
    assert_equal "confirmed", row.status
    assert_equal "LANDED_SIGNATURE", row.tx_signature
    assert_equal [ALEX, MASON], row.cosigner_addresses
  end

  test "THE SIGNATURE IS STAMPED BEFORE VERIFICATION, so a flaked verify cannot lose it" do
    # The property this endpoint exists to hold, and the one the treasury path
    # does not. Verification raises AFTER a successful broadcast; the row must
    # still carry the signature and must not be re-broadcastable.
    vault = StubVault.new
    row = armed_row(StubVault.new)

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, ->(**) { raise Solana::TxVerifier::VerificationError, "rpc lagged" } do
        post admin_broadcast_authority_rotation_path(row.slug),
             params: { signed_tx: WIRE, signer_queue: [ALEX, MASON] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    row.reload
    assert_equal "LANDED_SIGNATURE", row.tx_signature,
                 "a landed transaction must be recorded even when verification fails"
    assert_equal "submitted", row.status
    assert_not row.pending?, "and the row must not be re-broadcastable"
    assert_match(/recorded on this row/, JSON.parse(response.body)["error"])
  end

  test "a re-broadcast of an already-submitted row is refused" do
    vault = StubVault.new
    row = armed_row(StubVault.new)
    row.update!(status: "submitted", tx_signature: "EARLIER")

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [ALEX, MASON] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls, "nothing may reach the chain twice"
  end

  test "broadcast refuses a signer queue SHORTER than the slots it reserved" do
    # One proven signature must never be recorded as authorization for a
    # two-signature act. `Admin::VaultStateController#confirm` omitted this
    # check and now runs the same one through `CosignPlan#validate_extras!`.
    vault = StubVault.new
    row = armed_row(StubVault.new)

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, true do
        post admin_broadcast_authority_rotation_path(row.slug),
             params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/names 1 signer\(s\).*reserved 2 slot\(s\)/m, JSON.parse(response.body)["error"])
    assert_empty vault.broadcast_calls
    assert_nil row.reload.tx_signature
  end

  test "broadcast refuses a signer queue in a DIFFERENT ORDER than reserved" do
    # turf-vault reads the leading remaining accounts positionally, so a
    # reordered set is a different transaction.
    vault = StubVault.new
    row = armed_row(StubVault.new)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [MASON, ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/positionally/, JSON.parse(response.body)["error"])
    assert_empty vault.broadcast_calls
  end

  test "a failed simulation never reaches the chain and leaves no signature" do
    vault = StubVault.new(broadcast_raises: "Pre-flight simulation failed: custom program error: 0x17a4")
    row = armed_row(StubVault.new)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [ALEX, MASON] }, as: :json
    end

    assert_response :unprocessable_entity
    # The PROGRAM's own message, verbatim — never a blanket "blockhash may have
    # expired", which is what hid a real cause for three months on the treasury.
    assert_match(/0x17a4/, JSON.parse(response.body)["error"])
    row.reload
    assert_nil row.tx_signature
    assert row.pending?, "a transaction that never landed stays retryable"
  end

  # ── SERVER-LED: THE BROWSER COLLECTS ONLY WHAT PHANTOM HOLDS ─────────────
  #
  # When the server's own key leads, the build signs account 0 here and the
  # browser owes the rest. The queue once carried the lead too, so cosign.js
  # asked Phantom to switch to the server's key, which no operator holds.

  def server = Solana::CosignPlan.admin_address

  def server_led_vault(**opts)
    StubVault.new(signers: [server, ALEX, MASON], **opts)
  end

  def server_led_row(vault)
    arm(vault, signers: [server, ALEX, ALEX2], authorizers: [server, ALEX])
    PendingTransaction.last.tap { |row| row.update!(serialized_tx: WIRE) }
  end

  test "server-led rebuild queues only the cosigner, and paints the lead signed" do
    vault = server_led_vault
    row = server_led_row(vault)
    assert JSON.parse(row.metadata)["plan"]["server_leads"], "fixture: the server leads"

    with_vault(vault) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ALEX], body["signer_queue"], "the server's lead is not Phantom's to sign"
    assert_equal server, body["fee_payer_address"]
    assert_equal server, vault.build_calls.first[:lead]
  end

  test "server-led broadcast accepts the cosigner-only queue and verifies every signer" do
    vault = server_led_vault(read_back: [server, ALEX, ALEX2])
    row = server_led_row(server_led_vault)
    verified = []

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, ->(**kw) { verified << kw[:signer_pubkey] } do
        post admin_broadcast_authority_rotation_path(row.slug),
             params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
      end
    end

    assert_response :success
    # The lead is still asserted to be a signer of what landed.
    assert_equal [server, ALEX], verified
    row.reload
    assert_equal "confirmed", row.status
    assert_equal [server, ALEX], row.cosigner_addresses
    assert_equal ALEX, row.cosigner_address
  end

  test "server-led broadcast refuses a queue that claims the server's slot" do
    vault = server_led_vault
    row = server_led_row(server_led_vault)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [server, ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
  end

  test "operator-led broadcast refuses a queue that drops the lead" do
    # The lead is an operator wallet here, so it must be collected. A browser
    # that sends only the cosigner is claiming a signature nobody gave.
    vault = StubVault.new
    row = armed_row(StubVault.new)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, signer_queue: [MASON] }, as: :json
    end
    assert_response :unprocessable_entity

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: WIRE, cosigner_address: MASON }, as: :json
    end
    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
  end

  test "rebuild refuses when the build and the plan disagree on who signed account 0" do
    vault = StubVault.new
    vault.define_singleton_method(:build_update_signers) do |**kw|
      { serialized_tx: WIRE, new_signers: kw[:new_signers], server_signed: true }
    end
    # Armed but never built, so a refused build must leave the sentinel.
    row = arm(StubVault.new, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])

    with_vault(vault) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/account 0/, JSON.parse(response.body)["error"])
    assert_equal Admin::AuthoritiesController::UNBUILT_WIRE, row.reload.serialized_tx
  end

  # ── CANCEL ───────────────────────────────────────────────────────────────

  test "an armed eviction can be discarded" do
    row = armed_row(StubVault.new)
    post admin_cancel_authority_rotation_path(row.slug)

    assert_redirected_to admin_authorities_path
    assert_equal "expired", row.reload.status
    assert row.stale
  end

  # A LEGACY CLAIMED ROW WHOSE ANSWER WAS LOST IS NOT A DRAFT EITHER. It carries
  # no signature, so the signature guard waves it through — but its wire may be
  # on chain, and filing a possible rotation as one that never happened is the
  # worst answer this page can give mid-incident. Only the OLDER code could
  # produce this state; a claim now stamps its signature.
  test "an eviction whose broadcast answer was lost cannot be discarded" do
    row = armed_row(StubVault.new)
    row.update_columns(status: "submitted", tx_signature: nil)
    assert row.awaiting_reconciliation?

    delete_or_cancel = -> { post admin_cancel_authority_rotation_path(row.slug) }
    with_vault(StubVault.new) { delete_or_cancel.call }

    assert_equal "submitted", row.reload.status, "it may be on chain — it must not be expired"
    assert_not row.stale?
  end

  # ── THE MODERN STRANDED ROW, AND ITS WAY OUT ───────────────────────────────
  #
  # A claim now always records the signature, so an eviction whose broadcast
  # failed is caught by the signature guard rather than the legacy one. That
  # guard refuses it FOREVER unless something can settle it — which is the
  # brick this task exists to remove, so the page owes it a Reconcile.
  test "an eviction the node refused is freed by reconcile once its blockhash lapsed" do
    refused = Solana::Client::RpcError.new("Blockhash not found", code: -32002)
    row = armed_row(StubVault.new)
    with_vault(StubVault.new(broadcast_raises: refused)) { broadcast_row(row) }

    row.reload
    assert_equal "submitted", row.status, "a coded refusal is not a proof, so the claim is kept"
    assert_equal "LANDED_SIGNATURE", row.tx_signature

    post admin_cancel_authority_rotation_path(row.slug)
    assert_equal "submitted", row.reload.status, "cancel cannot discard something that may be on chain"

    row.update_columns(broadcast_at: (OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute).ago)
    with_vault(StubVault.new) { post admin_reconcile_authority_rotation_path(row.slug) }

    row.reload
    assert row.pending?, "verified-dead on chain, so the eviction is armed again"
    assert_nil row.tx_signature
  end

  test "reconcile leaves an eviction alone while it can still land" do
    row = armed_row(StubVault.new)
    with_vault(StubVault.new(broadcast_raises: RuntimeError.new("connection reset"))) { broadcast_row(row) }

    with_vault(StubVault.new) { post admin_reconcile_authority_rotation_path(row.slug) }

    row.reload
    assert_equal "submitted", row.status, "an unresolved rotation must not become re-broadcastable"
    assert_equal "LANDED_SIGNATURE", row.tx_signature
  end

  test "a broadcast eviction cannot be discarded" do
    row = armed_row(StubVault.new)
    row.update!(tx_signature: "LANDED")

    # AND IT RAISES NO ALARM. This refusal is the button working. Routing it
    # through `rescue_and_log` wrote an ErrorLog row and fanned it out to
    # Sentry — a page, mid-incident, for an operator clicking a control that
    # told him what it would do.
    before = ErrorLog.count
    post admin_cancel_authority_rotation_path(row.slug)

    assert_match(/already broadcast/, flash[:alert].to_s)
    assert_equal "pending", row.reload.status
    assert_equal before, ErrorLog.count,
                 "an expected refusal must not be logged as an application error"
  end

  # ── THE STRANDED ROW, AND THE DOOR OUT OF IT ─────────────────────────────
  #
  # /tasks/stranded-eviction-has-no-door. A broadcast whose answer is lost
  # leaves the row `submitted` and claimed — deliberately, because that claim is
  # what stops a landed rotation being sent a second time. #show was scoped
  # `.pending`, so the row then VANISHED from the page and the planner rendered
  # in its place. The remedy left was a Rails console, which resolves an
  # incident by deleting its evidence; and the console offered to arm a SECOND
  # eviction while the first one might still be landing.

  # The fixture every test below stands on: a broadcast that raised AFTER the
  # send. Not a proof of anything, so the claim is kept and the signature stays.
  def stranded_row
    row = armed_row(StubVault.new)
    with_vault(StubVault.new(broadcast_raises: RuntimeError.new("connection reset"))) { broadcast_row(row) }
    row.reload
    assert row.awaiting_broadcast_verdict?, "fixture must actually be stranded"
    row
  end

  def render_page(vault = StubVault.new)
    with_vault(vault) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path
      end
    end
  end

  test "a stranded eviction stays ON the page instead of vanishing from it" do
    row = stranded_row

    render_page

    assert_response :success
    assert_match(/LANDED_SIGNATURE/, response.body,
                 "the signature is the handle the chain is asked with — it must be on the page")
    assert_match(admin_reconcile_authority_rotation_path(row.slug), response.body,
                 "the door out of a stranded row is the Reconcile control, not a Rails console")
  end

  test "a stranded eviction offers NOTHING that would send a second rotation" do
    row = stranded_row

    render_page

    # THE ANCHOR FIRST. Every assertion below is a NEGATIVE, and a page that
    # dropped the stranded panel altogether would satisfy all of them — which
    # is precisely the bug being fixed, passing as a green test.
    assert_match(admin_reconcile_authority_rotation_path(row.slug), response.body,
                 "the stranded panel must actually be on the page for the refusals below to mean anything")

    assert_no_match(/Collect \d+ signatures/, response.body,
                    "a claimed row must never re-offer the co-sign ceremony")
    assert_no_match(/#{Regexp.escape(admin_broadcast_authority_rotation_path(row.slug))}/, response.body)
    assert_no_match(/#{Regexp.escape(admin_rebuild_authority_rotation_path(row.slug))}/, response.body)
    assert_no_match(/#{Regexp.escape(admin_cancel_authority_rotation_path(row.slug))}/, response.body,
                    "Discard refuses this row anyway; offering the button teaches the wrong remedy")
  end

  test "a stranded eviction outranks an eviction armed after it" do
    # #arm does not refuse a second row, so a console ordered purely by
    # created_at would hide the stranded row again the moment anyone armed
    # after it — this exact bug through a different door.
    stranded = stranded_row
    arm(StubVault.new, signers: [ALEX, MASON, ALEX3], authorizers: [ALEX, MASON])
    newer = PendingTransaction.where(tx_type: "update_signers").order(:id).last
    assert_not_equal stranded.id, newer.id, "fixture must have armed a SECOND row"

    render_page

    assert_match(admin_reconcile_authority_rotation_path(stranded.slug), response.body,
                 "the row with an unresolved chain question is the one the operator must deal with first")
    assert_no_match(/#{Regexp.escape(admin_broadcast_authority_rotation_path(newer.slug))}/, response.body)
  end

  test "a stranded eviction surfaces even when the vault read FAILS" do
    # THE INCIDENT SHAPE. The RPC that lost the broadcast's answer is the same
    # RPC that feeds this page, so the two failures arrive together. Surfacing a
    # stranded row needs no chain read — it is a database fact — and the
    # `vault.nil?` refusal exists to stop a rotation being PLANNED blind, which
    # is a different act. CI's playwright lane renders exactly this state.
    row = stranded_row

    render_page(StubVault.new(signers: nil))

    assert_response :success
    assert_match(admin_reconcile_authority_rotation_path(row.slug), response.body,
                 "an unreadable vault must not take the only remedy off the page with it")
  end

  # ── #rebuild MAY NOT TOUCH A ROW A BROADCAST HAS CLAIMED ─────────────────
  #
  # Measured before the fix: it did NOT un-claim (Rails omits an unchanged
  # `status` from the UPDATE, and the in-memory row still said pending) but it
  # DID overwrite `serialized_tx` and answer 200 — handing a second caller
  # fresh bytes to sign while the claimed wire was already going out. Its
  # treasury sibling re-checks `pending` inside the UPDATE; this one did not.
  test "rebuild refuses a row claimed between its own guard read and its write" do
    row = armed_row(StubVault.new)
    wire_before = row.reload.serialized_tx

    claim = -> { PendingTransaction.find(row.id).claim_for_broadcast!("SIG_ALREADY_GOING_OUT") }
    with_vault(StubVault.new(on_build: claim)) do
      post admin_rebuild_authority_rotation_path(row.slug), as: :json
    end

    assert_response :unprocessable_entity
    row.reload
    assert_equal "submitted", row.status, "the claim must survive a rebuild that raced it"
    assert_equal "SIG_ALREADY_GOING_OUT", row.tx_signature
    assert_equal wire_before, row.serialized_tx,
                 "a claimed row's wire must never be replaced — the claimed one is on its way out"
  end

  # ── THE INVARIANT THE WHOLE PAGE RESTS ON ────────────────────────────────
  #
  # A claim is released on exactly two things: PreflightRejected (the simulation
  # refused, so nothing left this server) or a verdict FROM THE CHAIN. Never on
  # an exception raised at or after send_transaction. Asserted over the fault
  # SHAPES rather than one of them, because the defect this guards is a new
  # rescue clause someone adds later for a fault that looks harmless.
  test "no failure at or after send_transaction can release the claim" do
    post_send_faults = [
      RuntimeError.new("connection reset"),
      Solana::Client::RpcError.new("Blockhash not found", code: -32002),
      Timeout::Error.new("read timeout"),
      Solana::TxVerifier::VerificationError.new("commitment has not caught up")
    ]

    post_send_faults.each do |fault|
      row = armed_row(StubVault.new)
      with_vault(StubVault.new(broadcast_raises: fault)) { broadcast_row(row) }

      row.reload
      assert_equal "submitted", row.status,
                   "#{fault.class} is not a proof that nothing was sent — the claim must be kept"
      assert_equal "LANDED_SIGNATURE", row.tx_signature,
                   "#{fault.class} must leave the row naming its transaction so #reconcile can ask"

      # RETIRE IT BEFORE THE NEXT FAULT. `tx_signature` is uniquely indexed and
      # the stub derives one constant signature from its one constant wire, so
      # a second claim in the same test would collide. The collision is itself
      # correct behaviour (see PendingTransaction#claim_for_broadcast!) — it is
      # just not what this test is about.
      row.update_columns(status: "expired", tx_signature: nil, stale: true)
    end
  end

  test "a PREFLIGHT refusal is the one fault that gives the claim back" do
    row = armed_row(StubVault.new)

    # A seeded STRING models a pre-flight refusal: the simulation rejected the
    # wire, so send_transaction was never reached and nothing left this server.
    with_vault(StubVault.new(broadcast_raises: "insufficient funds for fee")) { broadcast_row(row) }

    row.reload
    assert row.pending?, "provably un-sent, so the eviction stays retryable"
    assert_nil row.tx_signature
  end

  # ── THE CONSOLE NONCE: NO SIGNING CLOCK ────────────────────────────────────
  #
  # ptx-432 and ptx-433 (2026-10-14) died "Blockhash not found" while the
  # operator switched Phantom accounts between two prompts. A server-led build
  # now waits on Solana::ConsoleNonce instead, so these pin: the build takes it,
  # the row is not expired at two minutes, a broadcast is checked against the
  # nonce and the stored bytes, and reconcile never calls a nonce wire dead
  # while its nonce could still carry it.

  def nonce_account(value, authority: Solana::CosignPlan.admin_address)
    data = [1, 1].pack("VV") + Solana::Keypair.decode_base58(authority) +
           Solana::Keypair.decode_base58(value) + [5000].pack("Q<")
    { "value" => { "owner" => Solana::ConsoleNonce::SYSTEM_PROGRAM_B58,
                   "data" => [Base64.strict_encode64(data), "base64"] } }
  end

  def derived_nonce = Solana::ConsoleNonce.address_for(server)

  # A server-led vault whose console nonce holds `value` (a lambda reads it
  # live, so a test can move it).
  def nonce_vault(value_ref, **opts)
    vault = server_led_vault(account_infos: { derived_nonce => ->(_c) { nonce_account(value_ref.call) } }, **opts)
    vault.nonce_value_at_build = value_ref.call
    vault
  end

  def nonce_row(value, created_at: Time.current, built_at: created_at)
    row = server_led_row(server_led_vault)
    meta = JSON.parse(row.metadata).merge(
      "console_nonce" => { "pubkey" => derived_nonce, "authority" => server, "value" => value },
      "built_at" => built_at.iso8601(6)
    )
    row.update_columns(metadata: meta.to_json, created_at: created_at)
    row
  end

  test "a server-led build anchors on the ready console nonce and records it on the row" do
    value = Solana::Keypair.generate.to_base58
    vault = nonce_vault(-> { value })
    row = server_led_row(vault)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["nonce_anchored"], "the browser is told there is no clock"
    assert_equal({ pubkey: derived_nonce, authority: server }, vault.build_calls.sole[:durable_nonce])
    assert_equal value, row.reload.parsed_metadata.dig("console_nonce", "value")
  end

  test "an operator-led build never takes the nonce, even when it is ready" do
    value = Solana::Keypair.generate.to_base58
    vault = StubVault.new(account_infos: { derived_nonce => ->(_c) { nonce_account(value) } })
    row = armed_row(vault)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :success
    assert_nil vault.build_calls.sole[:durable_nonce]
    refute JSON.parse(response.body)["nonce_anchored"]
  end

  test "with no ready nonce a server-led build falls back to a fresh blockhash" do
    vault = server_led_vault
    row = server_led_row(vault)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :success
    assert_nil vault.build_calls.sole[:durable_nonce]
    assert_nil row.reload.parsed_metadata["console_nonce"]
  end

  test "the console reports whether the nonce is ready, and where to prepare it" do
    value = Solana::Keypair.generate.to_base58
    vault = StubVault.new(signers: [server, ALEX, ALEX2],
                          account_infos: { derived_nonce => ->(_c) { nonce_account(value) } })

    with_vault(vault) { get admin_authority_console_path, as: :json }
    nonce = JSON.parse(response.body)["console_nonce"]
    assert_equal "ready", nonce["state"]
    assert_equal derived_nonce, nonce["pubkey"]
    assert_equal admin_authority_console_nonce_path, nonce["prepare_url"]

    with_vault(StubVault.new(signers: [server, ALEX, ALEX2])) { get admin_authority_console_path, as: :json }
    assert_equal "missing", JSON.parse(response.body).dig("console_nonce", "state")
  end

  test "a nonce row outlives the two-minute expiry, and is expired after half an hour" do
    value = Solana::Keypair.generate.to_base58
    fresh = nonce_row(value, created_at: 10.minutes.ago)
    blockhash_row = arm(StubVault.new, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    blockhash_row.update_columns(created_at: 3.minutes.ago)

    with_vault(StubVault.new) { get admin_authority_console_path, as: :json }

    assert fresh.reload.pending?, "the operator may still be switching accounts; the bytes are good"
    assert_equal "expired", blockhash_row.reload.status
    assert_equal fresh.slug, JSON.parse(response.body).dig("live_rotation", "slug")

    meta = fresh.parsed_metadata.merge("built_at" => 31.minutes.ago.iso8601(6))
    fresh.update_columns(created_at: 31.minutes.ago, metadata: meta.to_json)
    with_vault(StubVault.new) { get admin_authority_console_path, as: :json }
    assert_equal "expired", fresh.reload.status
  end

  test "broadcast refuses signed bytes that are not the bytes this row built" do
    vault = server_led_vault
    row = server_led_row(vault)
    other = Solana::Transaction.new.tap do |tx|
      tx.set_recent_blockhash(Solana::Keypair.generate.to_base58)
      tx.add_signer(Solana::Keypair.generate)
      tx.add_instruction(program_id: Solana::Keypair.generate.public_key_bytes, accounts: [], data: "\x02".b)
    end.serialize_base64

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: other, signer_queue: [ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/not the one this rotation built/, JSON.parse(response.body)["error"])
    assert_empty vault.broadcast_calls
    assert row.reload.pending?
    assert_nil row.tx_signature
  end

  test "broadcast refuses a nonce wire whose nonce has moved on, before any claim" do
    built = Solana::Keypair.generate.to_base58
    moved = Solana::Keypair.generate.to_base58
    vault = nonce_vault(-> { moved })
    row = nonce_row(built)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/has moved on/, JSON.parse(response.body)["error"])
    assert_empty vault.broadcast_calls
    assert_nil row.reload.tx_signature
  end

  test "broadcast sends a nonce wire whose nonce still holds its value" do
    value = Solana::Keypair.generate.to_base58
    vault = nonce_vault(-> { value }, read_back: [server, ALEX, ALEX2])
    row = nonce_row(value, created_at: 20.minutes.ago)

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, true do
        post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
      end
    end

    assert_response :success
    assert_equal "confirmed", row.reload.status
  end

  # A submitted nonce row whose broadcast answer was lost, past the lapse.
  def stranded_nonce_row(value)
    row = nonce_row(value)
    row.update_columns(status: "submitted", tx_signature: "LANDED_SIGNATURE",
                       broadcast_at: (OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute).ago)
    row
  end

  def teach_send(vault, &on_send)
    vault.client.define_singleton_method(:get_latest_blockhash) { |**| "11111111111111111111111111111112" }
    vault.client.define_singleton_method(:send_and_confirm) { |wire, **| on_send.call(wire); "ADVANCED" }
  end

  test "reconcile ADVANCES an unspent nonce before it calls a lapsed nonce wire dead" do
    value = Solana::Keypair.generate.to_base58
    current = value
    vault = nonce_vault(-> { current })
    sent = []
    teach_send(vault) { |wire| sent << wire; current = Solana::Keypair.generate.to_base58 }
    row = stranded_nonce_row(value)

    with_vault(vault) { post admin_reconcile_authority_rotation_path(row.slug) }

    assert_equal 1, sent.length, "the server voided the old bytes by advancing its own nonce"
    advance = Solana::WireMessage.parse_base64(sent.sole).instructions.sole
    assert_equal 4, advance[:data].unpack1("V")
    row.reload
    assert row.pending?, "dead on chain now, so the rotation is armed again"
    assert_nil row.tx_signature
  end

  test "reconcile holds a nonce wire whose nonce would not move: it can still land" do
    value = Solana::Keypair.generate.to_base58
    vault = nonce_vault(-> { value })
    teach_send(vault) { |_wire| nil }
    row = stranded_nonce_row(value)

    with_vault(vault) { post admin_reconcile_authority_rotation_path(row.slug) }

    assert_equal "submitted", row.reload.status
    assert_equal "LANDED_SIGNATURE", row.tx_signature
    assert_match(/may still land/, flash[:notice])
  end

  test "reconcile reports a nonce wire that LANDED rather than voiding it" do
    value = Solana::Keypair.generate.to_base58
    vault = nonce_vault(-> { value }, signature_statuses: {
      "LANDED_SIGNATURE" => { "err" => nil, "confirmationStatus" => "finalized" }
    })
    sent = []
    teach_send(vault) { |wire| sent << wire }
    row = stranded_nonce_row(value)

    with_vault(vault) { post admin_reconcile_authority_rotation_path(row.slug) }

    assert_empty sent, "a landed rotation is never followed by an advance"
    assert_match(/LANDED/, flash[:notice])
  end

  test "prepare creates the console nonce with one server-signed wire, and refuses a second" do
    current = nil
    vault = server_led_vault(account_infos: { derived_nonce => ->(_c) { current && nonce_account(current) } })
    vault.client.define_singleton_method(:get_minimum_balance_for_rent_exemption) { |_n| 1_447_680 }
    sent = []
    teach_send(vault) { |wire| sent << wire; current = Solana::Keypair.generate.to_base58 }

    with_vault(vault) { post admin_authority_console_nonce_path, as: :json }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ready", body.dig("console_nonce", "state")
    assert_equal 1, sent.length
    assert_equal server, Solana::Keypair.encode_base58(Solana::WireMessage.parse_base64(sent.sole).account_keys.first)

    with_vault(vault) { post admin_authority_console_nonce_path, as: :json }
    assert_response :unprocessable_entity
    assert_equal 1, sent.length, "a ready nonce is never created twice"
  end

  test "a non-admin cannot prepare the console nonce" do
    log_in_as(users(:jordan))
    vault = server_led_vault
    sent = []
    teach_send(vault) { |wire| sent << wire }
    with_vault(vault) { post admin_authority_console_nonce_path, as: :json }
    assert_empty sent
  end

  # ── EVERY ENDING KILLS THE WIRE ────────────────────────────────────────────
  #
  # turf-vault's update_signers pins nothing about the set it replaces, so a
  # signed nonce rotation that ended without landing would re-apply its old set
  # whenever someone sent it. Advancing the nonce is its only death; each way a
  # nonce row can end is pinned here to enqueue Solana::VoidConsoleNonceJob,
  # and the job (run under the stub vault) to send the advance.

  # A server-led vault whose console nonce moves when the server advances it.
  # Returns [vault, sent_wires, value_ref].
  def moving_nonce_vault(value, authority: nil, **opts)
    current = value
    vault = server_led_vault(account_infos: {
      derived_nonce => ->(_c) { nonce_account(current, **(authority ? { authority: authority } : {})) }
    }, **opts)
    vault.nonce_value_at_build = value
    sent = []
    teach_send(vault) { |wire| sent << wire; current = Solana::Keypair.generate.to_base58 }
    [vault, sent, -> { current }]
  end

  def advances(sent)
    sent.count { |wire| Solana::WireMessage.parse_base64(wire).instructions.sole[:data].unpack1("V") == 4 }
  end

  def assert_voids(row, vault, sent)
    assert_enqueued_with(job: Solana::VoidConsoleNonceJob, args: [row.id])
    with_vault(vault) { perform_enqueued_jobs }
    assert_equal 1, advances(sent), "the server advanced the nonce, so the signed bytes can never land"
  end

  test "CANCEL loses to a broadcast that claimed the row after it was loaded: no expiry, no void" do
    value = Solana::Keypair.generate.to_base58
    vault, = moving_nonce_vault(value)
    row = nonce_row(value)
    stale = PendingTransaction.find(row.id) # what cancel loaded before the claim
    assert row.claim_for_broadcast!("sig-in-flight")
    PendingTransaction.stub(:find_by, stale) do
      with_vault(vault) { post admin_cancel_authority_rotation_path(row.slug), as: :json }
    end
    assert_equal ["submitted", "sig-in-flight"], [row.reload.status, row.tx_signature]
    assert_no_enqueued_jobs only: Solana::VoidConsoleNonceJob
  end

  test "CANCEL of a nonce row voids its nonce" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value)

    with_vault(vault) { post admin_cancel_authority_rotation_path(row.slug), as: :json }

    assert_equal "expired", row.reload.status
    assert_voids(row, vault, sent)
  end

  test "the 30-minute EXPIRY voids an expired nonce row's nonce" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value, created_at: 31.minutes.ago)

    # The PAGE (not the console JSON, which also re-queues outstanding wires),
    # so this pins the expiry's own enqueue.
    with_vault(vault) { Solana::Squads.stub(:read, nil) { get admin_authorities_path } }

    assert_equal "expired", row.reload.status
    assert_voids(row, vault, sent)
  end

  test "a REJECTED simulation ends a nonce row and voids its nonce" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value, broadcast_raises: "custom program error: 0x1770")
    row = nonce_row(value)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    row.reload
    assert_equal "expired", row.status, "signed bytes the chain rejected today could pass tomorrow"
    assert_nil row.tx_signature
    assert_voids(row, vault, sent)
  end

  test "a broadcast REFUSED after the signatures (the chain moved) ends the row and voids its nonce" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value)
    vault.signers = [server, MASON, ALEX3] # ALEX was unseated since the build: revalidate! refuses

    assert_no_difference -> { ErrorLog.count }, "an expected refusal is answered, not paged" do
      with_vault(vault) do
        post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
      end
    end
    assert_match(/Refused/, JSON.parse(response.body)["error"])

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert_equal "expired", row.reload.status
    assert_voids(row, vault, sent)
  end

  test "a broadcast refused for a wrong signer queue ends the row and voids its nonce" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [MASON] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "expired", row.reload.status
    assert_voids(row, vault, sent)
  end

  test "a broadcast refused on an UNREADABLE nonce ends the row, and the void job retries until it can read" do
    value = Solana::Keypair.generate.to_base58
    vault = server_led_vault(account_infos: { derived_nonce => ->(_c) { raise Solana::Client::RpcError, "down" } })
    row = nonce_row(value)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/unreadable/, JSON.parse(response.body)["error"])
    assert_equal "expired", row.reload.status
    assert_enqueued_with(job: Solana::VoidConsoleNonceJob, args: [row.id])
    with_vault(vault) { perform_enqueued_jobs(only: Solana::VoidConsoleNonceJob) rescue nil }
    assert_enqueued_jobs 1, only: Solana::VoidConsoleNonceJob # re-enqueued by retry_on StillLandable
  end

  test "a broadcast to an EXPIRED nonce row is refused and re-queues the void" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value)
    row.update_columns(status: "expired", stale: true)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
    end

    assert_response :unprocessable_entity
    assert_voids(row, vault, sent)
  end

  test "a refused broadcast never touches a row another request has claimed" do
    value = Solana::Keypair.generate.to_base58
    vault, _sent, = moving_nonce_vault(value)
    row = nonce_row(value)
    row.update_columns(status: "submitted", tx_signature: "LANDED_SIGNATURE", broadcast_at: Time.current)

    with_vault(vault) do
      post admin_broadcast_authority_rotation_path(row.slug), params: { signed_tx: WIRE, signer_queue: [ALEX] }, as: :json
    end

    assert_equal "submitted", row.reload.status
    assert_no_enqueued_jobs only: Solana::VoidConsoleNonceJob
  end

  # THE BACKSTOP: a build never reuses a value an ended row was signed on.
  test "a build on a value an expired row still holds advances the nonce FIRST" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    old = nonce_row(value)
    old.update_columns(status: "expired", stale: true)
    row = server_led_row(vault)
    order = []
    vault.define_singleton_method(:build_update_signers) do |**kw|
      order << [:build, sent.length]
      { serialized_tx: WIRE, new_signers: kw[:new_signers], server_signed: true, server_cosigned: [],
        durable_nonce: kw[:durable_nonce]&.merge(value: "NEW") }
    end

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :success
    assert_equal 1, advances(sent)
    assert_equal [[:build, 1]], order, "the advance went out before the bytes were built"
  end

  test "a REBUILD of a nonce row advances past its own earlier bytes" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    row = nonce_row(value)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :success
    assert_equal 1, advances(sent), "the first build's bytes (maybe signed) die before new ones exist"
  end

  test "a build refuses while a broadcast on the same value awaits its verdict" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    stranded_nonce_row(value)
    row = server_led_row(vault)

    with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }

    assert_response :unprocessable_entity
    assert_match(/reconcile it first/, JSON.parse(response.body)["error"])
    assert_empty sent
  end

  # THE WINDOW RUNS FROM THE BUILD, not from arm time.
  test "a nonce row rebuilt recently is live even though it was armed long ago" do
    row = nonce_row(Solana::Keypair.generate.to_base58, created_at: 45.minutes.ago, built_at: 5.minutes.ago)

    with_vault(StubVault.new) { get admin_authority_console_path, as: :json }

    assert row.reload.pending?
    assert_equal row.slug, JSON.parse(response.body).dig("live_rotation", "slug")
  end

  test "a successful build stamps built_at" do
    value = Solana::Keypair.generate.to_base58
    vault, = moving_nonce_vault(value)
    row = server_led_row(vault)

    freeze_time do
      with_vault(vault) { post admin_rebuild_authority_rotation_path(row.slug), as: :json }
      assert_equal Time.current.iso8601(6), row.reload.parsed_metadata["built_at"]
    end
  end

  # THE SERVER-KEY CHANGE: the old key's nonce cannot be advanced by the new
  # one. The job says so loudly and sends nothing; the console and the ceremony
  # show the wire as a hard stop, so a key is never switched over one.
  test "a wire stranded on another key's nonce is reported, never 'voided', and blocks the ceremony" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value, authority: ALEX3)
    row = nonce_row(value)
    row.update_columns(status: "expired", stale: true)

    assert_difference -> { ErrorLog.count }, 1 do
      with_vault(vault) { Solana::VoidConsoleNonceJob.perform_now(row.id) }
    end
    assert_empty sent

    with_vault(vault) { get admin_authority_console_path, as: :json }
    wires = JSON.parse(response.body)["outstanding_wires"]
    assert_equal [{ "slug" => row.slug, "nonce" => derived_nonce, "voidable" => false }], wires

    steps = [{ "id" => "flip-guard", "kind" => "console", "title" => "Next step", "who" => "Alex",
               "start" => [server, ALEX, MASON], "end" => [server, ALEX, MASON, ALEX2],
               "server" => server, "window_cosigners" => [], "intent" => "add", "add" => [ALEX2] }]
    real = Solana::SignerCeremony.method(:new)
    with_vault(vault) do
      Solana::SignerCeremony.stub(:new, ->(**kw) { real.call(**kw, steps: steps) }) do
        get admin_authority_ceremony_path
      end
    end
    assert_select "[data-check='no_outstanding_wires'][data-ok='false']"
    assert_select "[data-ceremony-step='flip-guard'][data-status='blocked']"
  end

  # Carl's follow-up (1) on signer-console-durable-nonce: retry_on gave up
  # silently. When the last attempt still cannot read or advance the nonce, the
  # wire may still land, and an operator has to hear about it on the row.
  test "a void job that exhausts its retries on an unreadable nonce records an ErrorLog on the row" do
    vault = server_led_vault(account_infos: { derived_nonce => ->(_c) { raise Solana::Client::RpcError, "down" } })
    row = nonce_row(Solana::Keypair.generate.to_base58)
    row.update_columns(status: "expired", stale: true)
    job = Solana::VoidConsoleNonceJob.new(row.id)
    # retry_on counts per handler (ActiveJob's exception_executions, keyed by
    # the handled classes); seven spent means this run is the eighth and last.
    job.exception_executions = { [Solana::VoidConsoleNonceJob::StillLandable].to_s => 7 }

    assert_difference -> { ErrorLog.count }, 1 do
      with_vault(vault) { job.perform_now }
    end
    log = ErrorLog.order(:id).last
    assert_equal row, log.target
    assert_match(/still holds its built value/, log.message)
    assert_no_enqueued_jobs only: Solana::VoidConsoleNonceJob
  end

  # Carl's follow-up (3): the list took the 25 newest expired rows BEFORE it
  # kept the nonce-anchored ones, so a burst of blockhash rows pushed an old
  # unvoided nonce row off the outstanding list.
  test "ended_nonce_rows keeps an old nonce row behind 25 newer blockhash rows" do
    old = nonce_row(Solana::Keypair.generate.to_base58)
    old.update_columns(status: "expired", updated_at: 2.days.ago)
    25.times do
      blockhash_row = server_led_row(server_led_vault)
      blockhash_row.update_columns(status: "expired", updated_at: 1.hour.ago)
    end

    assert_includes Admin::AuthoritiesController.ended_nonce_rows.map(&:id), old.id
  end

  test "the void job leaves live and landed rows alone" do
    value = Solana::Keypair.generate.to_base58
    vault, sent, = moving_nonce_vault(value)
    pending_row = nonce_row(value)

    with_vault(vault) { Solana::VoidConsoleNonceJob.perform_now(pending_row.id) }
    pending_row.update_columns(status: "confirmed")
    with_vault(vault) { Solana::VoidConsoleNonceJob.perform_now(pending_row.id) }

    assert_empty sent
  end
end
