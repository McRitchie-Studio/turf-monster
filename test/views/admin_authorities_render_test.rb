require "test_helper"

# [component] /admin/authorities as MARKUP.
#
# WHAT THIS TIER CAN AND CANNOT SEE. It cannot watch a signature arrive or a
# roster row turn green — that is e2e/authority_signer_eviction.spec.js. What it
# CAN see is the structure those behaviours depend on, and every piece below is
# something a well-meaning edit removes with nothing else in the suite noticing:
#
#   · the co-sign button's endpoints. cosign.js DEFAULTS to the treasury's
#     /admin/pending_transactions/<slug>/rebuild when no override is passed, so
#     dropping these two data-attributes does not break the page — it silently
#     points an eviction at the wrong controller, which 404s on a slug that
#     exists in a different scope. Nothing raises in Ruby.
#   · the [data-cosign-controls] wrapper. cosign.js scopes its roster painting
#     and its extra-cosigner read to that container; without it every
#     `paintSigner` call is a no-op and the operator watches an inert roster
#     while three Phantom dialogs come and go.
#   · [data-desktop-only-action]. The shared gate disables exactly that marker.
#     A button added later without it stays live on a phone.
#   · the roster's render-time state. Every indicator must ship `pending`,
#     INCLUDING a lead row the server has not signed.
#
# And one copy contract, because it is the defect this whole page exists to end:
# THE WORD "MULTISIG" IS NEVER UNQUALIFIED.
class AdminAuthoritiesRenderTest < ActionDispatch::IntegrationTest
  SYSTEM = "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd".freeze
  ALEX   = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze
  MASON  = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze
  ALEX2  = "3Qj4v9qjhXgkru6zCRCErRVhy8Q6qU3NrNpvpXLTZboA".freeze
  EMPTY  = Solana::SignerRotation::EMPTY

  class RenderVault
    def initialize(signers: [SYSTEM, ALEX, MASON])
      @signers = signers
    end

    def read_vault_state(**)
      slots = @signers.first(5) + Array.new([5 - @signers.length, 0].max, EMPTY)
      {
        pda: "VaultPda1111111111111111111111111111111111",
        signers: @signers.first(3), signers_ext: slots[3, 2],
        signer_slots: slots, active_signers: @signers,
        active_signer_count: @signers.length,
        threshold: 2, bump: 254, paused: false,
        payout_mint: "Mint", treasury_authority: "Treasury",
        accepted_currencies: [], registered_currencies: []
      }
    end

    def read_governance(**) = nil
    def governance_pda = [Solana::Keypair.decode_base58(ALEX2), 255]
    def vault_state_pda = [Solana::Keypair.decode_base58(ALEX), 254]
    def fee_payer_status(**) = { address: ALEX, balance_sol: 1.0, minimum_sol: 0.01, funded: true }
    def build_update_signers(**) = { serialized_tx: "WIRE", new_signers: [], server_signed: false }
  end

  SQUAD = {
    address: "7nRuVw3VZFC6z85tYVDitPnaUHZCkqLpJRSTBNtPmtZB",
    create_key: "HCQWKXq5wPeY8YeFyzzfzW7yXyBctNjz77rXuNPAFqi5",
    config_authority: EMPTY, threshold: 3, time_lock: 0, bump: 254, rent_collector: nil,
    members: [
      { address: ALEX,  mask: 7, can_initiate: true, can_vote: true, can_execute: true },
      { address: MASON, mask: 7, can_initiate: true, can_vote: true, can_execute: true },
      { address: ALEX2, mask: 1, can_initiate: true, can_vote: false, can_execute: false }
    ],
    voting_members: [ALEX, MASON],
    vault_pda: "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC"
  }.freeze

  setup { log_in_as(users(:alex)) }

  # Whatever key THIS process signs as. Read rather than hardcoded so the
  # in-set branch is exercised on any machine's configuration.
  def server_key
    Solana::CosignPlan.admin_address
  end

  def render_page(vault: RenderVault.new, squads: SQUAD)
    Solana::Vault.stub :new, vault do
      Solana::Squads.stub :read, squads do
        get admin_authorities_path
      end
    end
    assert_response :success
  end

  def arm_a_rotation
    vault = RenderVault.new
    Solana::Vault.stub :new, vault do
      post admin_arm_authority_rotation_path,
           params: { signers: [ALEX, MASON, ALEX2], authorizers: [ALEX, MASON] }
    end
    assert_equal 1, PendingTransaction.where(tx_type: "update_signers").count,
                 "the fixture rotation must arm, or the assertions below test an empty page"
    vault
  end

  # ── THE COPY CONTRACT ────────────────────────────────────────────────────

  # THE DETECTOR, shared by the page assertion and the controls below.
  #
  # ── WHY IT LOOKS AT THE ADJACENT WORDS AND NOT AT A WINDOW ────────────────
  #
  # The first cut took 280 characters around each hit and passed if the window
  # contained squads|upgrade|vault. On a page saturated with all three that
  # passes almost unconditionally: measured, it survived stripping "Squads" from
  # the very heading this file's header orders it to protect. A guard that
  # cannot fail is worse than no guard, because the task's recorded check then
  # claims an enforcement nobody has.
  #
  # The real rule is ADJACENCY. "Squads multisig" and "VaultState's in-program
  # multisig" are precise; "the multisig", three paragraphs after someone
  # mentioned Squads, is exactly the ambiguity that produced the wrong claims
  # this page replaces. So the qualifier has to be within the three words before
  # the noun — which is where English actually puts it.
  QUALIFIERS = /\A(squads|vault|vaultstate|in-program|upgrade|program-upgrade)\z/i

  # Code identifiers are exempt and must be: `validate_multisig` is the
  # program's own function name and naming it precisely is the opposite of the
  # ambiguity this guard is about. A hit glued to `_` is skipped.
  MULTISIG = /(?<![A-Za-z0-9_])multisig(?![A-Za-z0-9_])/i

  # Visible text only. Tags and attributes carry class names and hrefs that
  # would supply a qualifier no reader ever sees.
  def self.visible_text(html)
    html.gsub(/<script\b.*?<\/script>/m, " ").gsub(/<[^>]+>/m, " ").gsub(/&[a-z]+;/, " ")
  end

  # An INDEX walk rather than `Regexp.last_match` inside an enumerator block:
  # `$~` is frame-local, so it is not reliably visible from a block that
  # `Enumerator#each` yields into — it happened to read on one input and came
  # back nil on the next, which is exactly the kind of guard that reports clean
  # for the wrong reason.
  def self.unqualified_multisig(html)
    text = visible_text(html)
    offenders = []
    pos = 0
    while (at = text.index(MULTISIG, pos))
      recent = text[0...at].scan(/[A-Za-z][A-Za-z'-]*/).last(3)
      unless recent.any? { |w| w =~ QUALIFIERS }
        offenders << text[[at - 70, 0].max, 110].gsub(/\s+/, " ").strip
      end
      pos = at + 1
    end
    offenders
  end

  test "the word multisig is never used unqualified" do
    # THE DEFECT THIS ENDS. `Solana::Config`'s own comment orders: "NEVER write
    # 'the multisig' unqualified in this file — say Squads or VaultState; the
    # unqualified form is what produced the claims this comment replaces." The
    # same rule has to hold on the page, where the reader is an operator
    # mid-incident rather than someone reading a comment.
    render_page

    assert_empty self.class.unqualified_multisig(response.body),
                 "found an unqualified \"multisig\" on the page"
  end

  test "the guard BITES — it catches the mutations it exists to catch" do
    # A CONTROL, because a detector that never fires is indistinguishable from a
    # page that never offends, and the first version of this guard was the
    # former while claiming to be the latter. Each string below is a realistic
    # edit someone could make to this page.
    offending = {
      "the reviewer's own mutation: Squads stripped from the heading" =>
        "<h2>Program authority (multisig)</h2><p>It can redeploy the program.</p>",
      "the bare form the config comment forbids" =>
        "<p>A holder of stolen keys cannot execute here. The multisig needs 3 approvals.</p>",
      "a qualifier that is present but too far away to qualify anything" =>
        "<p>The Squads account is a different thing entirely from the signer set " \
        "above, and each cluster has its own. Changing the multisig is a separate act.</p>"
    }
    offending.each do |why, html|
      assert_not_empty self.class.unqualified_multisig(html),
                       "the guard must catch #{why}"
    end

    # And the other half: the correct forms must NOT trip it, or the guard would
    # be unsatisfiable and someone would delete it.
    passing = {
      "adjacent qualifier" => "<p>The Squads multisig holds the upgrade authority.</p>",
      "possessive qualifier" => "<p>VaultState's in-program multisig signs vault actions.</p>",
      "code identifier" => "<p>It calls <code>validate_multisig</code> with two signers.</p>",
      "constant" => "<p>Read <code>MULTISIG_SIGNERS</code> for the fallback list.</p>"
    }
    passing.each do |why, html|
      assert_empty self.class.unqualified_multisig(html),
                   "the guard must not trip on #{why}"
    end
  end

  test "the three authorities are labelled as three, not as one" do
    render_page

    assert_select "h2", text: /Vault signer set/
    assert_select "h2", text: /Program upgrade authority \(Squads multisig\)/
    assert_select "h2", text: /Server signing identity/
    # And the page says out loud that they are different accounts, because the
    # recurring failure is a reader assuming two views of one thing.
    assert_match(/a <strong>different account entirely<\/strong> from the vault signer set/i,
                 response.body)
  end

  # ── THE VAULT PANEL ──────────────────────────────────────────────────────

  test "all five slots render, empties included" do
    # An empty slot is a fact worth seeing: it is headroom on a five-slot
    # program and it is what a reduced set leaves behind. A panel that rendered
    # only the live keys would hide both.
    render_page(vault: RenderVault.new(signers: [SYSTEM, ALEX, MASON]))

    assert_equal 5, response.body.scan(/class="mt-0\.5 w-8 shrink-0/).length,
                 "every slot gets a row, occupied or not"
    assert_equal 2, response.body.scan(/>\s*Empty/).length
  end

  test "the slots beyond the deployed program's width are marked unreachable" do
    # On the DEPLOYED v0.25 binary there are only three slots. Rendering five
    # without saying so would invite an operator to plan a rotation the live
    # program cannot execute.
    render_page

    assert_match(/unreachable on the deployed program, which has only 3 slots/, response.body)
  end

  test "the legacy threshold field is labelled as decorative" do
    # `VaultState.threshold` is written once by `initialize` and read by nothing
    # in the authorization path. A page that presented it as THE threshold would
    # be repeating the claim every doc in the repo made for the program's whole
    # life.
    render_page
    assert_match(/legacy, and nothing reads it for authorization/, response.body)
  end

  # ── THE SQUADS PANEL ─────────────────────────────────────────────────────

  test "Squads membership renders per-member permissions, not a uniform claim" do
    render_page

    assert_match(/Threshold 3 of 3/, response.body)
    assert_match(/2 members may vote/, response.body)
    assert_match(/initiate · vote · execute/, response.body)
    # The member with vote stripped must render as such, or the threshold
    # arithmetic on the page is decoration.
    assert_match(/mask 1\s*\(initiate\)/, response.body)
  end

  test "the derived vault PDA is shown beside the address the app expects" do
    # Deriving it is what lets the page PROVE the match. Comparing the program's
    # Authority line against the MULTISIG address never matches and reads as
    # "the authority is wrong" — a mistake made twice in this ecosystem.
    render_page
    assert_match(/Vault PDA index 0 \(derived\)/, response.body)
    assert_match(/BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC/, response.body)
    assert_match(/matches the derived PDA/, response.body)
  end

  test "the Squads link says which cluster it serves and why the host is not cluster-flavoured" do
    render_page

    assert_select "a[href=?]", Solana::Config.squads_app_url
    assert_match(/devnet\.squads\.so<\/code> is decommissioned/, response.body)
    assert_match(/the cluster is\s+carried by the ADDRESS/i, response.body)
  end

  test "the page records WHY Squads is out of scope rather than leaving it implicit" do
    render_page
    assert_match(/Deliberately out of scope for this console/i, response.body)
    assert_match(/create and\s+vote on proposals and never carry one out/i, response.body)
  end

  test "an unreadable VAULT refuses to offer an eviction rather than guessing" do
    # The degraded state, pinned HERE rather than in e2e, because here the
    # failure can be stubbed instead of waited for. CI's playwright server
    # black-holes the RPC and a developer's stack usually does not, so an e2e
    # keyed on this copy would pass in one place and fail in the other.
    #
    # An authority page is opened during an incident — exactly when a provider
    # is most likely to be throttling. It must degrade to "I could not read
    # this" and never to a number from config.
    blind = RenderVault.new
    blind.define_singleton_method(:read_vault_state) { |**| nil }

    render_page(vault: blind)

    assert_match(/The VaultState account could not be read/, response.body)
    assert_match(/Refusing to guess/i, response.body)
    assert_select "form[action=?]", admin_arm_authority_rotation_path, false,
                  "nothing may offer to act on a signer set nobody could read"
  end

  test "the page renders when EVERY chain read raises" do
    # THE EXACT CONDITION CI RUNS UNDER, and the one this page must survive.
    # The playwright job pins SOLANA_RPC_URL to a black-hole loopback port
    # (test/lib/ci_playwright_hermetic_test.rb), so every server-side chain read
    # fails on every render.
    #
    # THE FIRST CUT 500'd HERE, and no local run could have seen it: the
    # governance probe raised, `#show` called it once inside a rescue (so the
    # memo was never written, the raise happening before the assignment) and
    # once outside. A developer's stack reaches devnet and renders fine.
    #
    # An authority page is opened during an incident, which is exactly when a
    # provider is most likely to be down. A 500 there is the whole feature lost
    # at the only moment it exists for.
    dead = RenderVault.new
    dead.define_singleton_method(:read_vault_state) { |**| raise Solana::Client::RpcError, "connect refused" }
    dead.define_singleton_method(:read_governance)  { |**| raise Solana::Client::RpcError, "connect refused" }
    dead.define_singleton_method(:fee_payer_status) { |**| raise Solana::Client::RpcError, "connect refused" }

    Solana::Vault.stub :new, dead do
      # Stub the RAISING reader, not `read` — `read` is where the rescue lives,
      # and replacing it would test the stub instead of the guard.
      Solana::Squads.stub :read!, ->(**) { raise "connect refused" } do
        get admin_authorities_path
      end
    end

    assert_response :success
    assert_select "h1", text: "Authorities"
    assert_select "h2", text: /Vault signer set/
    assert_select "h2", text: /Program upgrade authority/
    assert_select "h2", text: /Server signing identity/

    # ── AND THE PANEL BODIES, WHICH IS WHERE THE REAL FAILURE LIVED ────────
    #
    # Asserting the headings alone let a self-contradicting page pass: one panel
    # said the vault account could not be read while the panel below it stated
    # the server is "NOT in the vault signer set" and told the operator to act on
    # that. A definite negative FACT plus an INSTRUCTION, from a read that never
    # happened. Headings cannot see that; bodies can.
    assert_match(/cannot say whether\s+this key is in it/i, response.body)
    assert_no_match(/<strong>Not<\/strong> in the vault signer set/, response.body)
    assert_no_match(/An eviction must be led by a wallet that is/, response.body)
  end

  test "an unread vault never renders the server as a NON-signer" do
    # The three states, asserted apart. `if @vault && …include?` collapsed the
    # first two, and the collapse is reachable today — it is what CI renders on
    # every run, because the playwright job black-holes the RPC.
    blind = RenderVault.new
    blind.define_singleton_method(:read_vault_state) { |**| nil }
    render_page(vault: blind)
    assert_match(/cannot say whether\s+this key is in it/i, response.body)
    assert_no_match(/<strong>Not<\/strong> in the vault signer set/, response.body)

    # IN the set — the server key is slot 1 of the default fixture.
    render_page(vault: RenderVault.new(signers: [server_key, ALEX, MASON]))
    assert_match(/In the vault signer set/, response.body)
    assert_no_match(/cannot say whether/, response.body)

    # NOT in the set — a real, proven negative, which must still be said plainly.
    render_page(vault: RenderVault.new(signers: [ALEX, MASON, ALEX2]))
    assert_match(/<strong>Not<\/strong> in the vault signer set/, response.body)
    assert_match(/An eviction must be led by a wallet that is/, response.body)
    assert_no_match(/cannot say whether/, response.body)
  end

  test "an UNREAD GovernanceConfig is never reported as an ABSENT one" do
    # Two different facts, and merging them puts a confident claim about the
    # deployed program version in front of an operator who has no evidence for
    # it. "The account does not exist, so the program is pre-v0.26" is only true
    # when the account was actually looked at.
    unread = RenderVault.new
    unread.define_singleton_method(:read_governance) { |**| raise Solana::Client::RpcError, "connect refused" }

    Solana::Vault.stub :new, unread do
      Solana::Squads.stub :read, SQUAD do
        get admin_authorities_path
      end
    end

    assert_response :success
    assert_match(/could not be read on/, response.body)
    assert_no_match(/the deployed program is pre-v0\.26/, response.body)
    assert_match(/an unread\s+account is not an absent one/i, response.body)
    # And the per-row provenance says "unread" rather than "not on chain".
    assert_match(/>unread</, response.body)
  end

  # ── THE OVERLAP IS COMPUTED, NEVER CONCLUDED ─────────────────────────────

  test "an overlap BELOW the threshold says a thief can vote but not execute" do
    render_page # SQUAD: threshold 3, overlap with the vault set is 2

    assert_match(/below the threshold of\s+3/, response.body)
    assert_match(/can create and vote on proposals and never carry one out/i, response.body)
    assert_no_match(/could <em>execute<\/em> a program upgrade/, response.body)
  end

  test "an overlap AT OR ABOVE the threshold says so, and does not reassure" do
    # THE SENTENCE THIS REPLACES asserted "but it is still below the threshold"
    # with no comparison to `squads[:threshold]`. True of the number in front of
    # it the day it was written, and it INVERTS on the documented target: both
    # Squads are 3-of-5 and the intended five-member vault signer set IS the
    # mainnet Squad's membership, so the overlap reaches 5 against 3.
    #
    # The page would then have reassured an operator that a holder of those keys
    # "cannot execute here" while they could execute a PROGRAM UPGRADE — a
    # strictly larger power than anything the vault signer set grants.
    # Understating blast radius, on the panel whose whole job is computing it.
    breaching = SQUAD.merge(
      members: SQUAD[:members].map { |m| m.merge(mask: 7, can_vote: true, can_execute: true) },
      threshold: 2
    )
    render_page(vault: RenderVault.new(signers: [ALEX, MASON, ALEX2]), squads: breaching)

    assert_match(/at or above the threshold of\s+2/, response.body)
    assert_match(/could <em>execute<\/em> a program upgrade/, response.body)
    assert_match(/Evicting them from the vault does not touch that/i, response.body)
    # And it must NOT still be telling him this is safely out of scope.
    assert_no_match(/never carry one out/, response.body)
    assert_match(/right now that is a gap/i, response.body)
  end

  test "an unreadable VAULT makes no claim about the overlap at all" do
    blind = RenderVault.new
    blind.define_singleton_method(:read_vault_state) { |**| nil }

    render_page(vault: blind)

    assert_match(/cannot say how\s+many seats the two authorities share/i, response.body)
    assert_no_match(/below the threshold of/, response.body)
    assert_no_match(/at or above the threshold of/, response.body)
  end

  test "no overlap is stated as no overlap, not as a threshold comparison" do
    render_page(vault: RenderVault.new(signers: %w[
      8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd
    ]))

    assert_match(/No seat here is also in the vault signer set/i, response.body)
  end

  test "an unreadable Squad says so instead of quoting a number" do
    render_page(squads: nil)
    assert_match(/could not be read on/, response.body)
    assert_match(/do not substitute a number from a doc/i, response.body)
    assert_no_match(/Threshold 3 of/, response.body)
  end

  # ── THE EVICTION CONSOLE ─────────────────────────────────────────────────

  test "the planner ships before anything is armed, and arms nothing by itself" do
    render_page

    assert_select "form[action=?]", admin_arm_authority_rotation_path
    # The slot rows live inside an Alpine <template>, so the markup IS in the
    # response but inert until Alpine clones it. Asserting the CONTAINER rather
    # than the input is what separates "the planner shipped" from "a row was
    # server-rendered", which would be a different and wrong page.
    assert_select "template input[name=?]", "signers[]"
    assert_select "template select[name=?]", "authorizers[]"
    assert_match(/Arming records the proposed set and builds nothing/i, response.body)
  end

  test "the armed panel carries the co-sign wiring cosign.js depends on" do
    vault = arm_a_rotation
    render_page(vault: vault)

    # THE SCOPE. Without it every paintSigner call silently no-ops.
    assert_select "[data-cosign-controls]", 1

    # THE ENDPOINTS. cosign.js defaults to the TREASURY's routes when these are
    # absent, so losing them misroutes rather than breaks.
    row = PendingTransaction.where(tx_type: "update_signers").last
    assert_select "button[data-rebuild-url=?]", admin_rebuild_authority_rotation_path(row.slug)
    assert_select "button[data-broadcast-url=?]", admin_broadcast_authority_rotation_path(row.slug)

    # THE MOBILE GATE.
    assert_select "button[data-desktop-only-action]"
  end

  test "the roster ships with every indicator PENDING, including the lead row" do
    # A green check standing for a signature that does not exist is the same lie
    # as an Execute button at 2 of 3. On THIS page the lead is usually one of
    # the operator's own wallets — nothing is pre-signed at all.
    vault = arm_a_rotation
    render_page(vault: vault)

    assert_select "[data-signer-roster]", 1
    states = response.body.scan(/data-signer-state\s+data-state="(\w+)"/).flatten
    assert_equal 2, states.length, "one indicator per reserved slot"
    assert_equal %w[pending pending], states
    assert_no_match(/Auto<\/span>/, response.body,
                    "the operator leads here, so no row may claim it signs automatically")
  end

  test "the armed panel shows the exact new set, both sides, before signing" do
    vault = arm_a_rotation
    render_page(vault: vault)

    assert_match(/Signer set now/, response.body)
    assert_match(/Signer set after/, response.body)
    assert_match(/Armed — nothing has been signed/, response.body)
    # The evicted key is struck through in the BEFORE column, so the diff is
    # readable without comparing two lists by eye.
    assert_match(/line-through[^>]*>\s*#{SYSTEM}/m, response.body)
  end

  test "the armed panel states the rule that decides who may lead" do
    # Counter-intuitive and load-bearing: continuity means a wallet that signs
    # cannot be evicted by the transaction it signs, which is why the server
    # cannot always be the one to sign.
    vault = arm_a_rotation
    render_page(vault: vault)

    assert_match(/a wallet that signs this transaction cannot be evicted by it/i, response.body)
  end

  test "the blockhash window is explained rather than hidden" do
    vault = arm_a_rotation
    render_page(vault: vault)

    assert_match(/built when you click, not now/i, response.body)
    assert_match(/60-90 second/, response.body)
    assert_match(/click again/i, response.body)
  end
end
