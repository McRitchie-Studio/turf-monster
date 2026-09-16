module Admin
  # /admin/authorities — WHO CAN DO WHAT TO THIS PLATFORM, read off the chain,
  # and the one place an operator can evict a compromised vault signer.
  #
  # ── THE THREAT MODEL THIS SERVES ─────────────────────────────────────────
  #
  # An external group holds the SYSTEM and ADMIN keys. The Rails app, the deploy
  # pipeline and the operator's own machine are trustworthy; only the keys are
  # not. Under that model an IN-APP page is exactly right, because the server is
  # the part you can still believe. (The different scenario — the system itself
  # captured — is served by a standalone offline console, deliberately NOT this.)
  #
  # ── PAUSE IS NOT A REMEDY, AND THIS PAGE MUST NEVER IMPLY IT IS ──────────
  #
  # Verified across all 23 instruction sources on turf-vault `accepted`
  # (2026-09-15): exactly TWO instructions read `vault.paused` as a gate —
  # `enter_contest` and `enter_contest_with_token`. `mint_entry_token`,
  # `grant_seeds`, `create_contest` and the username instructions do not mention
  # the flag at all. So a paused vault still MINTS ENTRY TOKENS and GRANTS
  # SEEDS: the value-creating paths a key thief would actually use. Pausing
  # stops paying customers from entering and does not inconvenience the thief.
  # EVICTION IS THE ONLY REAL ANSWER, which is what this controller builds.
  #
  # ── THREE AUTHORITIES, NEVER CALLED "THE MULTISIG" ───────────────────────
  #
  # The page shows all three even though it ACTS on one, because conflating them
  # is this codebase's most durable defect (see the three-way note on
  # `Solana::Config::MULTISIG_SIGNERS`):
  #
  #   1. VAULT SIGNER SET (`VaultState.signers` ++ `signers_ext`) — signs vault
  #      actions. Changed by `update_signers`. THE ONLY ONE THIS PAGE WRITES.
  #   2. PROGRAM UPGRADE AUTHORITY (a Squads V4 multisig, per cluster) — can
  #      redeploy the program. Changed through Squads' own web UI; this page
  #      LINKS OUT and does not reimplement it.
  #   3. SERVER SIGNING IDENTITY (`Solana::Keypair.admin`) — which key THIS
  #      process signs as. Named explicitly so it stops being mistaken for (1).
  #
  # ── WHY SQUADS IS OUT OF SCOPE FOR THE ACTION, STATED ON THE PAGE ────────
  #
  # Because a thief cannot execute there. Both Squads read THRESHOLD 3 OF 5
  # (measured 2026-09-15, and re-read live by `Solana::Squads` rather than
  # quoted), so a holder of two member keys can create and vote on proposals and
  # never execute one. The page computes that intersection from the live read
  # instead of asserting a number — which matters, because the number in
  # circulation was wrong: the mainnet Squad DOES include the system key
  # `7auwTL…`, so a system+admin holder reaches 2 of 5 there, not 1 of 4.
  class AuthoritiesController < ApplicationController
    before_action :require_admin
    before_action :set_pending_rotation, only: [:rebuild, :broadcast, :cancel, :reconcile]

    TX_TYPE = "update_signers".freeze

    # WHAT `serialized_tx` HOLDS BETWEEN ARM AND FIRST CLICK.
    #
    # Nothing, and it has to SAY nothing. The column is NOT NULL and validated
    # present, so "no wire yet" cannot be spelled as nil without a migration on
    # a table five other flows share. A real wire here would be worse than a
    # sentinel: its blockhash dies within ~90 seconds while the operator is
    # still reading the set, and the page would then be offering him dead bytes.
    # `#rebuild` overwrites this at click time and `#broadcast` reads the signed
    # wire from the request, never from the column — so the sentinel cannot be
    # broadcast even by accident.
    UNBUILT_WIRE = "unbuilt".freeze

    def show
      @network   = Solana::Config::NETWORK
      @rpc_url   = Solana::Config.public_rpc_url
      @program_id = Solana::Config::PROGRAM_ID

      # (1) THE VAULT SIGNER SET — all five slots, from chain.
      @vault = read_vault_state_safely
      @vault_error = @vault.nil?

      # (2) THE PER-ACTION THRESHOLD TABLE. Nil is a REAL and expected state,
      # not a failure: between a Squads upgrade to v0.26 and `init_governance`
      # the PDA does not exist, and today it does not exist on either cluster.
      # The view says which of those two it is rather than rendering an empty
      # table that reads like "no thresholds".
      @governance = read_governance_safely
      # ABSENT AND UNREAD ARE DIFFERENT FACTS AND THE PAGE MUST NOT MERGE THEM.
      # "The account does not exist, so the program is pre-v0.26" is a CLAIM;
      # under an unreachable RPC it is one this page cannot make. Rendering the
      # same panel for both would put a confident, unverified sentence about the
      # program's version in front of an operator mid-incident.
      @governance_readable = @governance_read_ok
      @governance_pda = Solana::Keypair.encode_base58(vault.governance_pda.first)
      @config_governance = Solana::Config.governance?

      # (3) THE SQUADS UPGRADE MULTISIG. Never blocks the page.
      @squads = Solana::Squads.read
      @squads_address = Solana::Config.squads_multisig
      @squads_app_url = Solana::Config.squads_app_url
      @configured_upgrade_authority = Solana::Config.squads_vault_pda

      # (4) THE SERVER'S OWN SIGNING IDENTITY.
      @server_address = Solana::CosignPlan.admin_address

      @threshold_table = threshold_table
      @chain_governance_known = !chain_governance?.nil?
      @eligible_signers = @vault ? @vault[:active_signers] : Solana::Config::MULTISIG_SIGNERS
      @required_signatures = required_signatures_for_chain
      @max_slots = chain_governance? ? Solana::Vault::MAX_SIGNERS : Solana::SignerRotation::MAX_SLOTS_V025

      @rotation = live_rotation
      @rotation_stranded = @rotation&.submitted?
      @rotation_plan = @rotation && JSON.parse(@rotation.metadata)["plan"]&.deep_symbolize_keys
      # NEITHER IS BUILT FOR A STRANDED ROW. Both are signing-ceremony furniture
      # — who has yet to sign, and whether the lead wallet can pay the fee — and
      # a claimed row is past signing. Rendering them would dress the one state
      # this page must refuse to act on as one it is ready to act on. Skipping
      # `fee_payer_status_for` also skips a chain read, on the page most likely
      # to be opened while the chain is unreachable.
      #
      # ORDER MATTERS: the roster renders the fee payer's balance, so the read
      # has to happen first or the lead row claims "could not be read" on a page
      # that did read it.
      signing_plan = @rotation_stranded ? nil : @rotation_plan
      @fee_payer = signing_plan && fee_payer_status_for(signing_plan)
      @roster = signing_plan && roster_for(signing_plan)

      # WHO HOLDS EACH WALLET. Resolved LAST, because it takes the addresses the
      # reads above actually produced rather than a list assembled by hand — a
      # second list is a second thing to keep in step, and the one that drifts is
      # always the one nobody renders.
      @identities = identities_for(
        Array(@vault && @vault[:signer_slots]) +
        Array(@vault && @vault[:active_signers]) +
        Array(@eligible_signers) +
        Array(@squads && @squads[:members].map { |member| member[:address] }) +
        Array(@rotation_plan && @rotation_plan[:current]) +
        Array(@rotation_plan && @rotation_plan[:proposed]) +
        Array(@rotation_plan && @rotation_plan[:authorizers]) +
        [@server_address]
      )
    end

    # ARM AN EVICTION. Validates the proposed set against turf-vault's own
    # guards, in turf-vault's own order, and records a durable row — WITHOUT
    # building or signing anything. The operator reads the exact new signer set
    # here, before a wallet is opened.
    #
    # NOTHING IS BUILT YET ON PURPOSE. A transaction built now would carry a
    # blockhash that expires in ~60-90 seconds, and the whole point of this step
    # is to give him unhurried time to check the set. The bytes are minted at
    # CLICK time by #rebuild.
    def arm
      rescue_and_log do
        rotation = build_rotation(
          proposed: params[:signers],
          authorizers: params[:authorizers]
        )
        rotation.validate!

        plan = rotation.to_plan.merge(
          lead_signer: rotation.authorizers.first,
          server_leads: rotation.authorizers.first == Solana::CosignPlan.admin_address,
          armed_at: Time.current.iso8601
        )

        # The row is created with the UNBUILT sentinel, not a built wire — see
        # the constant for why a real one here would be worse than none.
        record = PendingTransaction.create!(
          tx_type: TX_TYPE,
          serialized_tx: UNBUILT_WIRE,
          target: nil,
          initiator_address: Solana::CosignPlan.admin_address,
          metadata: { plan: plan }.to_json
        )

        redirect_to admin_authorities_path,
                    notice: "Eviction armed. Review the new signer set, then collect " \
                            "#{plan[:required_signatures]} signatures. (#{record.slug})"
      end
    rescue Solana::SignerRotation::Refusal => e
      redirect_to admin_authorities_path, alert: "Refused: #{e.message}"
    rescue StandardError => e
      redirect_to admin_authorities_path, alert: "Could not arm the eviction: #{e.message}"
    end

    # Mint the bytes, NOW. Called by cosign.js at click time so the blockhash
    # window opens when the operator acts rather than when the page rendered.
    #
    # THE PLAN IS RE-VALIDATED AGAINST A FRESH CHAIN READ, not trusted from the
    # armed row. The signer set could have moved between arming and clicking —
    # by another operator, or by the very thief this page exists to evict — and
    # a rotation validated against a stale set could break continuity and brick
    # governance. Re-reading is the only way that is caught before the fee.
    def rebuild
      rescue_and_log(target: @tx) do
        raise "This eviction is #{@tx.status}, not pending" unless @tx.pending?

        plan     = armed_plan
        rotation = revalidate!(plan)
        shape    = vault_shape!

        result = vault.build_update_signers(
          new_signers: rotation.live_slots,
          lead_signer: plan[:lead_signer],
          cosigner_pubkey: plan[:authorizers][1],
          extra_cosigners: plan[:authorizers][2..] || []
        )

        # CONDITIONAL, NOT A BARE WRITE — the same shape the treasury sibling
        # takes, for the same reason. `pending?` at the top of this action is a
        # READ; a #broadcast that claims the row in the interval leaves this
        # write racing a wire that is already going out.
        #
        # What the bare `update!` did, measured: it did NOT un-claim — `status`
        # was already "pending" in memory, so Rails omitted it from the UPDATE —
        # but it DID replace `serialized_tx` and answer 200, handing a second
        # caller fresh bytes to sign against a row whose claimed transaction may
        # be landing. Re-checking the state inside the UPDATE is what makes the
        # guard hold, rather than the accident of an unchanged attribute.
        rebuilt = PendingTransaction.where(id: @tx.id, status: "pending")
                                    .update_all(serialized_tx: result[:serialized_tx],
                                                updated_at: Time.current) == 1
        unless rebuilt
          raise "This eviction is no longer pending (it is now #{@tx.reload.status}) — " \
                "reconcile it against the chain rather than rebuilding it."
        end
        @tx.reload

        render json: {
          status: "rebuilt",
          serialized_tx: result[:serialized_tx],
          # THE SIGNING PLAN TRAVELS WITH THE BYTES IT DESCRIBES, so the browser
          # collects against the slots THIS build reserved rather than against
          # whatever the page was rendered believing.
          required_signatures: rotation.required,
          signer_queue: signer_queue_for(plan),
          cosigner_address: plan[:authorizers][1],
          extra_cosigners: plan[:authorizers][2..] || [],
          # NIL WHEN THE OPERATOR LEADS. cosign.js paints this row as already
          # signed, and it is only true when the SERVER filled the slot at build
          # time. A green check standing for a signature nobody has produced is
          # the same lie as an Execute button at 2 of 3.
          fee_payer_address: result[:server_signed] ? plan[:lead_signer] : nil,
          shape: shape,
          new_signers: result[:new_signers]
        }
      end
    rescue Solana::SignerRotation::Refusal => e
      render json: { error: "Refused: #{e.message}" }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # RECORD WHAT IS ABOUT TO GO OUT, simulate, broadcast, verify, read back.
    #
    # ── THE SIGNATURE IS STAMPED BEFORE THE BROADCAST, NOT AFTER IT ─────────
    #
    # It never comes from the RPC: a transaction's signature is the first 64
    # bytes of its own signed wire, so `Solana::Vault#signature_for_wire` reads
    # it here and `PendingTransaction#claim_for_broadcast!` writes it in the
    # same conditional UPDATE that takes the claim. A broadcast whose answer is
    # lost therefore leaves a row that still names its transaction, and
    # #reconcile can ask the chain what became of it.
    #
    # The treasury path stamped it AFTER `TxVerifier.verify!`, so a transaction
    # that LANDED but whose verification flaked — a slow RPC, a commitment that
    # has not caught up — was left `pending` with no signature, and therefore
    # re-broadcastable. That was /tasks/broadcast-records-signature-late, and it
    # is now FIXED: `Admin::PendingTransactionsController#broadcast` takes the
    # claim the same way, because the rule lives on the model
    # (`PendingTransaction#claim_for_broadcast!` / `#rewind_broadcast!`) rather
    # than in either controller, so the two cannot drift on what decides whether
    # money moves twice. Their `#rebuild` siblings now agree too — both re-check
    # `pending` INSIDE the UPDATE, so neither can write to a row a broadcast has
    # claimed (/tasks/stranded-eviction-has-no-door; this one used to).
    #
    # The consequence here is worse than a double payout: a second rotation
    # attempt after the first landed is authorized by keys the first one just
    # evicted, so it fails `Unauthorized` and reads to the operator like his
    # eviction did not work — mid-incident, on the one control he has.
    #
    # A row left `submitted` is therefore the SAFE failure: the signature is on
    # the record, the claim refuses a re-broadcast, and the read-back below
    # tells him what actually happened on chain regardless.
    def broadcast
      rescue_and_log(target: @tx) do
        raise "This eviction is #{@tx.status}, not pending" unless @tx.pending?

        plan     = armed_plan
        rotation = revalidate!(plan)
        signed_tx = params[:signed_tx].to_s
        raise "Signed transaction required" if signed_tx.blank?

        # THE COUNT IS CHECKED, not merely each address's membership — one
        # proven signature must never be recorded as authorization for a
        # multi-signature act. `Admin::VaultStateController#confirm` omitted this
        # half and now runs the same check through `CosignPlan#validate_extras!`.
        claimed = require_signer_queue!(plan)

        # THE SIGNATURE IS A FACT ABOUT THE BYTES, read before the claim so a
        # malformed wire is refused without stranding one. `vault` is already
        # warmed by `revalidate!` above, so its constructor cannot raise inside
        # the claimed window.
        signature = vault.signature_for_wire(signed_tx)

        # CLAIM THE ROW BEFORE THE WIRE GOES OUT, recording what is about to go
        # out in the same statement. `pending?` above is a READ; two concurrent
        # requests both pass it and both broadcast. See
        # PendingTransaction#claim_for_broadcast!.
        unless @tx.claim_for_broadcast!(signature)
          raise "This eviction is already being broadcast (it is now #{@tx.status}) — " \
                "read the signer set back rather than sending a second rotation."
        end

        begin
          vault.simulate_and_broadcast(signed_tx)
        rescue Solana::Vault::PreflightRejected
          # PROVABLY UN-SENT — the simulation refused it or could not be run, so
          # the send was never made. Rewind, naming the signature being cleared,
          # so a program refusal stays retryable.
          #
          # Only this type. A failure of the SEND is never a proof: Solana::Client
          # retries the faults that mean "the answer was lost" and surfaces only
          # the last one, so a coded error can follow an attempt that already
          # forwarded the wire (Solana::Vault#simulate_and_broadcast). Such a row
          # keeps its claim and its signature, and #reconcile asks the chain.
          @tx.rewind_broadcast!(signature)
          raise
        end

        verify_landed!(signature: signature, claimed: claimed)

        @tx.update!(status: "confirmed",
                    cosigner_address: claimed[1],
                    cosigner_addresses: claimed)

        render json: {
          status: "confirmed",
          tx_signature: signature,
          # THE READ-BACK. What the chain says the signer set is NOW, not what
          # we asked it to be — the only answer worth anything on this page.
          signers: read_back_signers,
          expected: rotation.live_slots
        }
      end
    rescue Solana::TxVerifier::VerificationError => e
      render json: {
        error: "Broadcast landed but verification failed: #{e.message}. The signature is " \
               "recorded on this row and it will not be re-broadcast — read the signer set back " \
               "before acting again.",
        tx_signature: @tx.reload.tx_signature
      }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Discard an armed eviction. Refuses once a signature exists — a row that
    # has broadcast is a historical fact, not a draft.
    # THE DOOR OUT OF AN EVICTION WHOSE BROADCAST ANSWER WE NEVER GOT.
    #
    # The sibling of Admin::PendingTransactionsController#reconcile and the same
    # model call, because a stranded rotation is the same failure as a stranded
    # settle. Without it #cancel would refuse the row forever — it refuses to
    # discard anything carrying a signature, and a claim now always records one.
    #
    # A :landed row is left alone: on this page the authoritative answer is the
    # signer set read back off the chain, not a status flag, so the operator is
    # sent to re-read it rather than having state flipped here.
    def reconcile
      rescue_and_log(target: @tx) do
        unless @tx.awaiting_broadcast_verdict?
          raise "This eviction is #{@tx.status} with no recorded signature — nothing to reconcile."
        end

        signature = @tx.tx_signature
        status = vault.client.confirm_transaction(signature).dig("value", 0)

        notice =
          case @tx.reconcile_broadcast!(status)
          when :landed
            "This rotation LANDED on chain (#{signature}). Read the signer set back to see " \
            "what the vault holds now; it will not be re-broadcast."
          when :failed
            "This rotation landed and FAILED on chain (#{signature}), so the signer set did " \
            "not change. The eviction is armed again and can be rebuilt."
          when :never_landed
            "This rotation never landed and its blockhash window has lapsed, so it can never " \
            "land. The eviction is armed again and can be rebuilt."
          else
            "Still unresolved — the rotation may yet land, so it stays claimed. Do not " \
            "re-send it; reconcile again shortly."
          end

        redirect_to admin_authorities_path, notice: notice
      end
    rescue StandardError => e
      redirect_to admin_authorities_path, alert: "Reconciliation failed: #{e.message}"
    end

    def cancel
      # THE GUARD IS NOT AN ERROR. Raising it inside `rescue_and_log` sends an
      # EXPECTED operator refusal through `ErrorLog.capture!`, which writes a
      # triage row and fans out to Sentry — "the paging layer", per the engine's
      # own comment. On an incident console that is a false alarm raised by a
      # button doing exactly what it says. The guard returns; only the WRITE is
      # wrapped, which is what the discipline actually asks for.
      if @tx.tx_signature.present?
        return redirect_to admin_authorities_path,
                           alert: "This eviction already broadcast (#{@tx.tx_signature}); " \
                                  "it cannot be discarded."
      end

      # A LEGACY CLAIMED ROW WHOSE ANSWER WAS LOST IS NOT A DRAFT EITHER. It
      # carries no signature, so the check above waves it through — but its wire
      # may be on the chain, and marking it `expired` would file a possible
      # rotation as one that never happened. Only rows claimed by the OLDER code
      # can be in this state; a claim now stamps its signature, so a modern
      # stranded row is caught by the `tx_signature.present?` check above and
      # cleared by #reconcile rather than by hand.
      if @tx.awaiting_reconciliation?
        return redirect_to admin_authorities_path,
                           alert: "This eviction was broadcast and the result was not read back, " \
                                  "so it may be on chain. Read the signer set before discarding it."
      end

      rescue_and_log(target: @tx) do
        @tx.update!(status: "expired", stale: true)
        redirect_to admin_authorities_path, notice: "Armed eviction discarded."
      end
    rescue StandardError => e
      redirect_to admin_authorities_path, alert: e.message
    end

    private

    # ── WHO HOLDS EACH WALLET, AND THE ONE THING THIS MUST NEVER DO ──────────
    #
    # BOTH WALLET COLUMNS ARE SEARCHED, because this app stores one user's
    # wallet in either of two places: `User#solana_address` is
    # `web3_solana_address || web2_solana_address`, the first being a linked
    # Phantom and the second a managed wallet. A lookup against `web3` alone —
    # which is what `User.from_solana_wallet` does, and why it is not used here —
    # silently misses every managed account, and a page that misses a user
    # renders that wallet as unheld.
    #
    # AND MOST ADDRESSES HERE MAY HAVE NO USER AT ALL. The signer set is agent
    # and operator wallets; nothing guarantees any of them is an app account.
    # So this returns ONLY what it found, the view renders a miss as visibly
    # unresolved, and the full address renders on every row either way. On a
    # page whose whole job is deciding WHICH KEY TO REMOVE, a wrong name is
    # worse than no name — the identity is an ADDITION to the address and never
    # a replacement for it.
    #
    # THE EMPTY SLOT SENTINEL IS DROPPED BEFORE THE QUERY. It is a real base58
    # string (the all-ones system program id), so it would otherwise be asked
    # about on every render of a vault that has headroom.
    def identities_for(addresses)
      wanted = Array(addresses).map(&:to_s).reject(&:blank?).uniq
      wanted -= [Solana::SignerRotation::EMPTY]
      return {} if wanted.empty?

      found = User.where(web3_solana_address: wanted)
                  .or(User.where(web2_solana_address: wanted))

      found.each_with_object({}) do |user, by_address|
        # `wanted.include?` guards BOTH assignments: an `.or` across two columns
        # matches a combo account on one of them, and writing the other column
        # unconditionally would key this hash by an address nobody on the page
        # asked about.
        by_address[user.web3_solana_address] ||= user if wanted.include?(user.web3_solana_address)
        by_address[user.web2_solana_address] ||= user if wanted.include?(user.web2_solana_address)
      end
    end

    def vault
      @vault_service ||= Solana::Vault.new
    end

    # THE ROTATION THIS PAGE IS ABOUT — and why it is not `.pending`.
    #
    # It was `.pending`, and that is /tasks/stranded-eviction-has-no-door. A
    # broadcast whose answer is lost leaves the row `submitted` and CLAIMED,
    # deliberately: the claim is what stops a landed rotation being sent twice,
    # and on this surface a second attempt is authorized by keys the first one
    # just evicted, so it fails `Unauthorized` and reads to the operator like
    # his eviction did not work. Scoped to `.pending` the page then dropped that
    # row and rendered the PLANNER in its place — the evidence gone, and an
    # invitation to arm a second eviction while the first might still be
    # landing. The only remedy left was a Rails console, which resolves the
    # incident by deleting the record of it.
    #
    # A CLAIMED ROW OUTRANKS A NEWER ARMED ONE, rather than the newest winning.
    # `#arm` does not refuse a second row, so ordering purely by `created_at`
    # would hide the stranded row again the moment anybody armed after it — the
    # same bug through a different door. The row carrying an unresolved question
    # to the chain is always the one to deal with first, whatever came after it.
    #
    # BOTH KINDS OF CLAIMED ROW ARE TAKEN, on `status` alone rather than on the
    # signature. A modern row names its transaction and #reconcile can ask the
    # chain about it; a legacy one does not and cannot (see
    # `PendingTransaction#awaiting_reconciliation?`). They need different copy,
    # which the view gives them — but a row that cannot be reconciled here is
    # exactly the row that must not be silently dropped.
    def live_rotation
      rotations = PendingTransaction.where(tx_type: TX_TYPE)
      rotations.submitted.order(created_at: :desc).first ||
        rotations.pending.order(created_at: :desc).first
    end

    def set_pending_rotation
      @tx = PendingTransaction.find_by(slug: params[:slug], tx_type: TX_TYPE)
      return if @tx

      respond_to do |format|
        format.json { render json: { error: "Eviction not found" }, status: :not_found }
        format.html { redirect_to admin_authorities_path, alert: "Eviction not found" }
      end
    end

    def armed_plan
      JSON.parse(@tx.metadata).fetch("plan").deep_symbolize_keys
    end

    # Build a SignerRotation from a fresh chain read. Everything about the shape
    # — slot count, threshold, the guard ORDER — follows what is deployed, never
    # what this boot's env var prefers.
    def build_rotation(proposed:, authorizers:)
      state = vault.read_vault_state
      raise "Vault state could not be read; refusing to plan a rotation blind." if state.nil?

      Solana::SignerRotation.for_chain(
        current_signers: state[:active_signers],
        proposed: Array(proposed),
        authorizers: Array(authorizers).map { |a| a.to_s.strip }.reject(&:blank?),
        # THE RAISING READER. A rotation planned against a guessed program
        # shape is worse than one refused: the guess reaches the chain as an
        # opaque deserialization error, after a fee and three Phantom dialogs.
        governance: chain_governance!,
        max_live_threshold: max_live_threshold
      )
    end

    def revalidate!(plan)
      build_rotation(proposed: plan[:proposed], authorizers: plan[:authorizers]).validate!
    end

    # IS THE CHAIN RUNNING v0.26? Answered by whether the GovernanceConfig PDA
    # EXISTS, which is the only fact that decides which instruction shape the
    # deployed binary can decode.
    #
    # ── TWO READERS, BECAUSE THE TWO CALLERS WANT OPPOSITE THINGS ────────────
    #
    # `read_governance` raises on an RPC failure and returns nil only for a
    # genuinely absent account. A BUILD must never fold those together — a
    # network blip read as "pre-v0.26" builds a three-slot argument against a
    # five-slot program — so `chain_governance!` propagates the failure and the
    # build refuses. But the READ-ONLY page must still render: it is opened
    # during an incident, which is exactly when a provider is most likely to be
    # down, and an authority page that 500s on a dead RPC is useless at the one
    # moment it exists for.
    #
    # The first cut had only the raising form, and `#show` called it twice: the
    # first call sat inside a `rescue` (so `@chain_governance` was never
    # assigned, the raise happening before the assignment) and the second went
    # uncaught. Every render 500'd under an unreachable RPC — invisible on a
    # developer's stack and caught by CI's deliberately black-holed endpoint.
    # Hence the memo below covers the FAILURE too, not just the answer.

    # THE ONE READ of the GovernanceConfig account. Raises when the chain cannot
    # be read; nil ONLY when the account genuinely does not exist. Memoized
    # including the nil, so a caller cannot trigger a second read that fails
    # differently from the first.
    def governance_account
      return @governance_account if defined?(@governance_account)

      @governance_account = vault.read_governance
    end

    # Raises when the chain cannot be read. For anything that builds bytes.
    def chain_governance!
      return @chain_governance if defined?(@chain_governance)

      @chain_governance = governance_account.present?
    end

    # nil when the chain could not be read. For the page.
    def chain_governance?
      return @chain_governance_soft if defined?(@chain_governance_soft)

      @chain_governance_soft = begin
        chain_governance!
      rescue StandardError => e
        Rails.logger.warn("[solana] governance probe failed: #{Solana::Config.redact_message(e.message)}")
        nil
      end
    end

    # REFUSE WHEN THE ENV SWITCH AND THE CHAIN DISAGREE.
    #
    # The builders route their shape through `Config.governance?` (one switch,
    # seventeen builders — see `Vault#governance_metas`), and that switch is an
    # env var. When it disagrees with the chain, every build is the wrong shape
    # and the failure arrives as an opaque deserialization error after a fee.
    # This names it first, in both directions, and says which lever to move.
    def vault_shape!
      chain = chain_governance!
      config = Solana::Config.governance?
      return chain ? "v0.26" : "v0.25" if chain == config

      if config && !chain
        raise "This app is configured for turf-vault v0.26 (#{Solana::Config::GOVERNANCE_ENV_VAR}) " \
              "but the GovernanceConfig PDA #{Solana::Keypair.encode_base58(vault.governance_pda.first)} " \
              "does not exist on #{Solana::Config::NETWORK}. Run init_governance after the upgrade, " \
              "or unset the switch — do not sign a v0.26-shaped transaction against a v0.25 program."
      end

      raise "The chain is running turf-vault v0.26 (GovernanceConfig exists) but this app is " \
            "configured for v0.25. Set #{Solana::Config::GOVERNANCE_ENV_VAR}=on and restart before " \
            "rotating signers — a three-slot argument cannot express the deployed set."
    end

    # WHAT THE PAGE SHOWS WHEN THE PROBE CAME BACK NIL. The DEPLOYED shape, not
    # the newer one: both clusters run v0.25 today, and a page that guessed high
    # would tell the operator he needs three signatures to evict when the chain
    # will take two — which is a worse error than the reverse, because he would
    # go looking for a third wallet he does not need mid-incident.
    def required_signatures_for_chain
      chain_governance? ? Solana::Governance.required_signatures("update_signers")
                        : Solana::SignerRotation::REQUIRED_V025
    end

    # Every governance action with the number of signatures it ACTUALLY needs,
    # and where that number came from.
    #
    # THE `source` COLUMN IS THE POINT. A reader must be able to tell a value
    # the CHAIN stores from one this app is assuming, because on a pre-v0.26
    # cluster the whole table is an assumption — the GovernanceConfig PDA does
    # not exist and the deployed binary enforces a structural two through
    # `validate_multisig`, which never reads a threshold at all. A table that
    # rendered identically in both cases would be the exact conflation this
    # page was built to end.
    #
    # `floor` is applied on READ by the program itself, so a stored value below
    # a floor is raised here too — otherwise this page would report a number
    # turf-vault would refuse to honour.
    def threshold_table
      stored = Array(@governance && @governance[:thresholds])
      on_chain = @governance.present?

      Solana::Governance::ACTION_IDS.map do |name, id|
        raw     = stored[id].to_i
        floor   = Solana::Governance::THRESHOLD_FLOORS.fetch(name, 1)
        default = Solana::Governance::DEFAULT_THRESHOLDS.fetch(name, 1)
        value   = raw.zero? ? default : raw

        {
          action: name,
          id: id,
          effective: [value, floor].max,
          floor: floor,
          floored: floor > value,
          source: if @governance_read_ok == false
                    # NOT "not on chain" — that is a claim about the CHAIN, and
                    # a failed read supports no claim about the chain at all.
                    "unread"
                  elsif !on_chain
                    "not on chain"
                  elsif raw.zero?
                    "program default"
                  else
                    "stored"
                  end
        }
      end.sort_by { |row| [-row[:effective], row[:action]] }
    end

    # The highest threshold ANY live action requires. `update_signers` refuses a
    # set smaller than this, because rotating below it would brick that action
    # with no way back except another rotation.
    # ONE READ, REUSED — not a second one behind a bare `rescue nil`.
    #
    # The bare rescue was the one place this controller's own rule slipped: it
    # folded UNREAD into ABSENT, and nil here means "no ceiling to satisfy", so a
    # flaked read would have silently dropped the `count >= max_live` guard from
    # a rotation — the guard that stops a set too small for some OTHER action
    # bricking it with no way back.
    #
    # The fix is not a better rescue, it is not reading twice. `chain_governance!`
    # has already read this account and memoized it by the time any caller
    # reaches here, so the ceiling comes from THAT read. It cannot fail
    # separately, and it cannot disagree with the shape decision made from it.
    def max_live_threshold
      table = governance_account
      return nil if table.nil?

      stored = Array(table[:thresholds])
      Solana::Governance::ACTION_IDS.filter_map do |name, id|
        value = stored[id].to_i
        value = Solana::Governance::DEFAULT_THRESHOLDS.fetch(name, 1) if value.zero?
        [value, Solana::Governance::THRESHOLD_FLOORS.fetch(name, 1)].max
      end.max
    end

    # [lead, cosigner, *extras] — the order the slots were reserved in, which is
    # the order turf-vault reads them positionally.
    def signer_queue_for(plan)
      Array(plan[:authorizers])
    end

    # What the browser CLAIMS signed, checked for count, order and membership
    # against the armed plan before a word of it is written to the record.
    def require_signer_queue!(plan)
      expected = Array(plan[:authorizers])
      claimed  = Array(params[:signer_queue]).map { |a| a.to_s.strip }.reject(&:blank?)
      claimed  = Array(params[:cosigner_address]).map(&:to_s) + Array(params[:extra_cosigners]) if claimed.empty?
      claimed  = claimed.map { |a| a.to_s.strip }.reject(&:blank?)

      if claimed != expected
        raise "This broadcast names #{claimed.length} signer(s) (#{claimed.join(', ')}) but the " \
              "armed eviction reserved #{expected.length} slot(s) for #{expected.join(', ')}. " \
              "turf-vault reads those accounts positionally, so a different set is a different " \
              "transaction — re-arm rather than re-send."
      end

      claimed
    end

    # EVERY claimed signer is asserted to be in a SIGNER SLOT of what landed —
    # not merely present in the transaction. turf-vault requires `info.is_signer`
    # on each leading remaining account, and a non-signer sitting in a cosigner
    # slot is what produces 6047 CosignerDidNotSign.
    def verify_landed!(signature:, claimed:)
      vault_pda = Solana::Keypair.encode_base58(vault.vault_state_pda.first)

      claimed.each_with_index do |address, i|
        Solana::TxVerifier.verify!(
          signature: signature,
          instruction_name: TX_TYPE,
          signer_pubkey: address,
          # The VaultState PDA is the account this instruction mutates. Asserted
          # once, on the first signer, because the assertion is about the
          # transaction rather than about the signer.
          writable_pubkey: i.zero? ? vault_pda : nil
        )
      end
    end

    # Bust every cached read this rotation invalidates, then re-read. Without
    # the bust the page would show the OLD signer set for up to a minute after
    # an eviction — on the one screen where a stale answer is dangerous.
    def read_back_signers
      Rails.cache.delete(Solana::Vault::VAULT_STATE_CACHE_KEY)
      Rails.cache.delete(Solana::Vault::GOVERNANCE_CACHE_KEY)
      Current.vault_state_fetched = false
      Current.vault_state = nil
      Solana::Vault.new.read_vault_state&.dig(:active_signers)
    rescue StandardError => e
      Rails.logger.warn("[solana] signer read-back failed: #{Solana::Config.redact_message(e.message)}")
      nil
    end

    # Roster rows in the shape admin/pending_transactions/_signer_roster expects.
    #
    # THE LEAD ROW IS ONLY "Auto" WHEN THE SERVER ACTUALLY FILLS IT. When the
    # operator leads — which is the case whenever the SERVER'S OWN KEY is being
    # evicted — nothing is pre-signed and every row is his to act on.
    def roster_for(plan)
      server_leads = plan[:server_leads]
      fee_payer = @fee_payer

      Array(plan[:authorizers]).each_with_index.map do |address, i|
        is_lead = i.zero?
        {
          address: address,
          role: is_lead ? "lead" : (i == 1 ? "cosigner" : "extra"),
          label: if is_lead
                   server_leads ? "Server (fee payer)" : "Your wallet (fee payer)"
                 elsif i == 1
                   "Cosigner"
                 else
                   "Wallet #{i + 1}"
                 end,
          fee_payer: is_lead,
          signs_automatically: is_lead && server_leads,
          balance_sol: is_lead && fee_payer ? fee_payer[:balance_sol] : nil,
          funded: is_lead && fee_payer ? fee_payer[:funded] : nil,
          minimum_sol: is_lead && fee_payer ? fee_payer[:minimum_sol] : nil
        }
      end
    end

    # The fee payer is whoever LEADS, which on THIS page is often one of the
    # operator's own wallets rather than the server — see the lead-signer note
    # on `Solana::Vault#build_update_signers`. Read once for the page, and the
    # address is passed explicitly so a server-funded reading can never stand in
    # for an operator wallet that is actually empty.
    def fee_payer_status_for(plan)
      vault.fee_payer_status(
        required_signatures: plan[:required_signatures].to_i,
        address: plan[:lead_signer]
      )
    end

    def read_vault_state_safely
      vault.read_vault_state
    rescue StandardError => e
      Rails.logger.warn("[solana] vault state read failed: #{Solana::Config.redact_message(e.message)}")
      nil
    end

    # Sets `@governance_read_ok` so the caller can tell ABSENT from UNREAD —
    # two states a nil return cannot distinguish on its own.
    def read_governance_safely
      result = governance_account
      @governance_read_ok = true
      result
    rescue StandardError => e
      Rails.logger.warn("[solana] governance read failed: #{Solana::Config.redact_message(e.message)}")
      @governance_read_ok = false
      nil
    end
  end
end
