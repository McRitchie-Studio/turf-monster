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
  SYSTEM = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  ALEX   = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON  = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  ALEX2  = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  ALEX3  = "9gACbzsCLmkYF9Yx1EBGmwMvvyfuTquJ6qs8QsoQvHXf".freeze
  EMPTY  = Solana::SignerRotation::EMPTY

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
                   read_back: nil, signature_statuses: {}, on_build: nil)
      @signers = signers
      @governance = governance
      @broadcast_raises = broadcast_raises
      @read_back = read_back
      @signature_statuses = signature_statuses
      @on_build = on_build
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

    def build_update_signers(new_signers:, cosigner_pubkey:, lead_signer: nil, extra_cosigners: [])
      @build_calls << { new_signers: new_signers, cosigner: cosigner_pubkey,
                        lead: lead_signer, extras: extra_cosigners }
      @on_build&.call
      { serialized_tx: "FAKE_WIRE", vault_pda: "VAULTPDA", new_signers: new_signers,
        slot_width: 3, lead_signer: lead_signer, server_signed: false }
    end

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

    def client = @client ||= FakeSolanaClient.new(@signature_statuses || {})
  end

  setup do
    @admin = users(:alex)
    log_in_as(@admin)
  end

  def with_vault(vault, &block)
    Solana::Vault.stub(:new, vault, &block)
  end

  def arm(vault, signers:, authorizers:)
    with_vault(vault) do
      post admin_arm_authority_rotation_path, params: { signers: signers, authorizers: authorizers }
    end
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

  test "a signed-in non-admin cannot arm an eviction" do
    log_in_as(users(:jordan))
    assert_no_difference -> { PendingTransaction.count } do
      post admin_arm_authority_rotation_path,
           params: { signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON] }
    end
    assert_response :redirect
  end

  # ── ARMING: THE REFUSALS ─────────────────────────────────────────────────

  test "arming refuses a set below the threshold, naming the program error" do
    vault = StubVault.new(signers: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                          governance: { thresholds: Array.new(32, 0) })

    assert_no_difference -> { PendingTransaction.count } do
      Solana::Config.stub(:governance?, true) do
        arm(vault, signers: [ALEX, ALEX2], authorizers: [ALEX, ALEX2, ALEX3])
      end
    end

    follow_redirect!
    assert_match(/SignerSetTooSmall, 6052/, flash[:alert].to_s + response.body)
  end

  test "arming refuses a set with a gap" do
    vault = StubVault.new(signers: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                          governance: { thresholds: Array.new(32, 0) })

    assert_no_difference -> { PendingTransaction.count } do
      Solana::Config.stub(:governance?, true) do
        arm(vault, signers: [ALEX, "", ALEX2, ALEX3], authorizers: [ALEX, ALEX2, ALEX3])
      end
    end

    assert_match(/earlier slot is empty/, flash[:alert].to_s)
  end

  test "arming refuses a rotation that does not retain its own authorizers" do
    vault = StubVault.new(signers: [SYSTEM, ALEX, MASON, ALEX2, ALEX3],
                          governance: { thresholds: Array.new(32, 0) })

    assert_no_difference -> { PendingTransaction.count } do
      Solana::Config.stub(:governance?, true) do
        arm(vault, signers: [ALEX, ALEX2, MASON], authorizers: [ALEX, ALEX2, ALEX3])
      end
    end

    assert_match(/SignerContinuityRequired, 6017/, flash[:alert].to_s)
    assert_match(/#{ALEX3}/, flash[:alert].to_s)
  end

  test "arming refuses an authorizer that is not in the on-chain set" do
    assert_no_difference -> { PendingTransaction.count } do
      arm(StubVault.new, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, ALEX3])
    end

    assert_match(/Unauthorized, 6000/, flash[:alert].to_s)
  end

  test "arming refuses to plan blind when the vault state cannot be read" do
    blind = StubVault.new
    blind.define_singleton_method(:read_vault_state) { |**| nil }

    assert_no_difference -> { PendingTransaction.count } do
      arm(blind, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    end

    assert_match(/refusing to plan a rotation blind/i, flash[:alert].to_s)
  end

  # ── ARMING: THE RECORD ───────────────────────────────────────────────────

  test "arming records the exact new set and builds NOTHING" do
    # The bytes are minted at click time, not now: a transaction built here
    # would carry a blockhash dead within ~90 seconds of the operator starting
    # to read it.
    vault = StubVault.new

    assert_difference -> { PendingTransaction.count }, 1 do
      arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])
    end

    assert_empty vault.build_calls, "arming must not build a transaction"

    row = PendingTransaction.last
    plan = JSON.parse(row.metadata)["plan"]

    assert_equal "update_signers", row.tx_type
    assert_equal "pending", row.status
    assert_equal Admin::AuthoritiesController::UNBUILT_WIRE, row.serialized_tx,
                 "the column must say there is no wire yet, not carry a dead one"
    assert_equal [ALEX, MASON, ALEX2], plan["proposed"]
    assert_equal [SYSTEM], plan["evicted"]
    assert_equal [ALEX2], plan["added"]
    assert_equal [ALEX, MASON], plan["authorizers"]
    assert_equal ALEX, plan["lead_signer"]
    assert_equal "v0.25", plan["shape"]
    assert_equal 2, plan["required_signatures"]
  end

  test "the armed page shows the exact new signer set before anything is signed" do
    vault = StubVault.new
    arm(vault, signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON])

    with_vault(vault) do
      Solana::Squads.stub :read, nil do
        get admin_authorities_path
      end
    end

    assert_match(/Armed — nothing has been signed/, response.body)
    assert_match(/Signer set after/, response.body)
    assert_match(/Evicting 1 key/, response.body)
    assert_match(/#{SYSTEM}/, response.body)
    assert_match(/#{ALEX2}/, response.body)
    # And the rule that decides who may lead, stated where it bites.
    assert_match(/a wallet that signs this transaction cannot be evicted by it/i, response.body)
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
    assert_equal "FAKE_WIRE", body["serialized_tx"]
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
    PendingTransaction.last
  end

  # The broadcast POST, with verification stubbed green — used by the tests that
  # are about what happens to the ROW when the send itself fails.
  def broadcast_row(row)
    Solana::TxVerifier.stub :verify!, true do
      post admin_broadcast_authority_rotation_path(row.slug),
           params: { signed_tx: "SIGNED", signer_queue: [ALEX, MASON] }, as: :json
    end
  end

  test "broadcast records the landed signature, confirms, and reads the set back" do
    vault = StubVault.new(read_back: [ALEX, MASON, ALEX2])
    row = armed_row(StubVault.new)

    with_vault(vault) do
      Solana::TxVerifier.stub :verify!, true do
        post admin_broadcast_authority_rotation_path(row.slug),
             params: { signed_tx: "SIGNED", signer_queue: [ALEX, MASON] }, as: :json
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
             params: { signed_tx: "SIGNED", signer_queue: [ALEX, MASON] }, as: :json
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
           params: { signed_tx: "SIGNED", signer_queue: [ALEX, MASON] }, as: :json
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
             params: { signed_tx: "SIGNED", signer_queue: [ALEX] }, as: :json
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
           params: { signed_tx: "SIGNED", signer_queue: [MASON, ALEX] }, as: :json
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
           params: { signed_tx: "SIGNED", signer_queue: [ALEX, MASON] }, as: :json
    end

    assert_response :unprocessable_entity
    # The PROGRAM's own message, verbatim — never a blanket "blockhash may have
    # expired", which is what hid a real cause for three months on the treasury.
    assert_match(/0x17a4/, JSON.parse(response.body)["error"])
    row.reload
    assert_nil row.tx_signature
    assert row.pending?, "a transaction that never landed stays retryable"
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
end
