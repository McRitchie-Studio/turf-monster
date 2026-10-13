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
  #      redeploy the program. Agents create and pre-approve its proposals by
  #      script; this page LISTS the open ones, checks an upgrade's buffer
  #      against a verified build, and casts Mr. McRitchie's approval in one
  #      Phantom prompt (#proposals, #approve_proposal). Execution and every
  #      config change stay in the Squads app.
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

    # A rotation row exists only from the click that signs it. One still
    # `pending` with no signature after this long was abandoned mid-ceremony
    # (a closed tab, a declined prompt the browser could not report), and its
    # blockhash is long dead, so #show and #console expire it before reading.
    STALE_PENDING_AFTER = 2.minutes

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
      expire_abandoned_rotations!
      # The console's draft, pre-filled from a ceremony step's link. Read by
      # the Stimulus controller from data attributes; never trusted: every
      # value goes through #plan like a typed one.
      @prefill = {
        intent: params[:intent].to_s.presence_in(Solana::SignerPlan::INTENTS),
        remove: params[:remove].to_s,
        add: params[:add].to_s
      }
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

    # THE CONSOLE'S STATE, as JSON. The Stimulus controller fetches it rather
    # than reading server-rendered data, so the page stays one document that
    # renders under a dead RPC, and the browser test can stand in for the
    # chain. Read-only; it writes nothing but the expiry of abandoned rows.
    def console
      expire_abandoned_rotations!
      planner = planner_for(params[:connected])
      rotation = live_rotation
      render json: {
        ok: true,
        rules: planner.rules,
        current: planner.current,
        # Every roster key is labelled, so a pasted roster key from another
        # cluster reads as named rather than unknown.
        labels: planner.labels(planner.current + planner.candidates + Solana::SignerRoster.default.entries.map(&:address)),
        candidates: planner.candidates,
        server_held_error: @server_held_error,
        live_rotation: rotation && { slug: rotation.slug, status: rotation.status,
                                     signature: rotation.tx_signature }
      }
    rescue Solana::SignerPlan::Refusal => e
      render json: e.to_h, status: :unprocessable_entity
    rescue StandardError => e
      log_console_failure(e)
      render json: { ok: false, code: "unreadable", message: Solana::Config.redact_message(e.message) },
             status: :service_unavailable
    end

    # PLAN A ROTATION. JSON, and NO ROW: a draft costs nothing and a refusal
    # renders inline on the same draft. Every address is checked here
    # (base58, 32 bytes, not the zero key, seated or not as the intent needs)
    # and the signers are derived, never chosen. See Solana::SignerPlan.
    def plan
      render json: planner_for(params[:connected]).plan!(**plan_params)
    rescue Solana::SignerPlan::Refusal => e
      render json: e.to_h, status: :unprocessable_entity
    rescue StandardError => e
      log_console_failure(e)
      render json: { ok: false, code: "unreadable", message: Solana::Config.redact_message(e.message) },
             status: :service_unavailable
    end

    # SIGN: re-plan against a FRESH chain read, create the row, and build the
    # bytes in the same request, so the blockhash window opens when the
    # operator acts. The browser collects the Phantom signatures and calls
    # #broadcast; on a decline it calls #cancel at once.
    def create_rotation
      if (live = live_rotation)
        return render json: { ok: false, code: "rotation_in_flight",
                              message: "Rotation #{live.slug} is #{live.status}; resolve it before starting another." },
                      status: :conflict
      end

      planned = planner_for(params[:connected]).plan!(**plan_params)
      vault_shape!
      require_reviewed_set!(planned)

      rescue_and_log do
        plan = planned.slice(:shape, :required_signatures, :max_slots, :current, :proposed, :padded,
                             :evicted, :retained, :added, :authorizers, :intent, :lead_signer,
                             :server_leads, :server_held, :prompt_count)
                      .merge(armed_at: Time.current.iso8601)
        @tx = PendingTransaction.create!(
          tx_type: TX_TYPE,
          serialized_tx: UNBUILT_WIRE,
          target: nil,
          initiator_address: Solana::CosignPlan.admin_address,
          metadata: { plan: plan }.to_json
        )
        render json: build_and_store!(plan.deep_symbolize_keys).merge(
          slug: @tx.slug,
          rebuild_url: admin_rebuild_authority_rotation_path(@tx.slug),
          broadcast_url: admin_broadcast_authority_rotation_path(@tx.slug),
          cancel_url: admin_cancel_authority_rotation_path(@tx.slug),
          sentence: planned[:sentence]
        )
      end
    rescue Solana::SignerPlan::Refusal => e
      render json: e.to_h, status: :unprocessable_entity
    rescue Solana::SignerRotation::Refusal => e
      render json: { ok: false, code: "chain_rule", chain_code: e.code, message: "Refused: #{e.message}" },
             status: :unprocessable_entity
    rescue StandardError => e
      log_console_failure(e)
      @tx&.update(status: "expired", stale: true) if @tx&.pending? && @tx.tx_signature.blank?
      render json: { ok: false, code: "build_failed", message: Solana::Config.redact_message(e.message) },
             status: :unprocessable_entity
    end

    # THE ROTATION CEREMONY for this cluster, every precondition read live.
    # Read-only. Each read degrades to "unread" rather than failing the page.
    def ceremony
      @network = Solana::Config::NETWORK
      state = read_vault_state_safely
      @server_address = Solana::CosignPlan.admin_address
      @ceremony = Solana::SignerCeremony.new(
        network: @network,
        chain_set: state&.dig(:active_signers),
        chain_governance: chain_governance?,
        config_governance: Solana::Config.governance?,
        server: @server_address,
        server_held: server_held_addresses,
        fee_payer: @server_address && vault.fee_payer_status(required_signatures: required_signatures_for_chain,
                                                             address: @server_address)
      )
      @steps = @ceremony.steps
    end

    # THE OPEN SQUADS PROPOSALS on this cluster, described and verified. JSON;
    # read-only. `connected` is the browser's Phantom account.
    def proposals
      squads = Solana::SquadsProposals.new
      render json: { ok: true, network: squads.network, squads_url: squads.squads_url,
                     vault_pda: squads.vault_pda,
                     proposals: squads.open_proposals(connected: params[:connected].to_s.strip.presence) }
    rescue StandardError => e
      log_console_failure(e)
      render json: { ok: false, message: Solana::Config.redact_message(e.message) }, status: :service_unavailable
    end

    # An UNSIGNED Squads approve for the connected member. Phantom signs and
    # sends it (the member pays); nothing here signs or broadcasts, and the
    # page reads the proposal back afterwards.
    def approve_proposal
      member = params[:member].to_s.strip
      unless Solana::SignerIsolation.valid_pubkey?(member)
        return render json: { ok: false, code: "bad_address", message: "Connect Phantom first." },
                      status: :unprocessable_entity
      end

      render json: { ok: true }.merge(Solana::SquadsProposals.new.build_approve(index: params[:index].to_i,
                                                                                member: member))
    rescue Solana::SquadsProposals::Refusal => e
      render json: { ok: false, code: e.code, message: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      log_console_failure(e)
      render json: { ok: false, code: "unreadable", message: Solana::Config.redact_message(e.message) },
             status: :service_unavailable
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

        render json: build_and_store!(armed_plan)
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
        signers = require_signer_queue!(plan)

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
        rescue Solana::Cosign::PreflightRejected
          # PROVABLY UN-SENT — the simulation refused it or could not be run, so
          # the send was never made. Rewind, naming the signature being cleared,
          # so a program refusal stays retryable.
          #
          # Only this type, and the gem's hierarchy now says so in its own name:
          # `Cosign::PreflightRejected` IS "provably never sent", while its
          # sibling `Cosign::BroadcastFailed` is "may be on chain". A failure of
          # the SEND is never a proof — Solana::Client retries the faults that
          # mean "the answer was lost" and surfaces only the last one, so a coded
          # error can follow an attempt that already forwarded the wire
          # (Solana::Vault#simulate_and_broadcast). A BroadcastFailed row KEEPS
          # its claim and its signature, and #reconcile asks the chain.
          @tx.rewind_broadcast!(signature)
          raise
        end

        verify_landed!(signature: signature, signers: signers)

        @tx.update!(status: "confirmed",
                    cosigner_address: signers[1],
                    cosigner_addresses: signers)

        # THE READ-BACK. What the chain says the signer set is NOW, not what
        # we asked it to be — the only answer worth anything on this page. It
        # is stored on the row so the record carries it after a reload.
        read_back = read_back_signers
        @tx.update!(metadata: JSON.parse(@tx.metadata).merge("read_back" => read_back).to_json)

        render json: {
          status: "confirmed",
          tx_signature: signature,
          signers: read_back,
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
        return cancel_answer("This eviction already broadcast (#{@tx.tx_signature}); it cannot be discarded.",
                             ok: false)
      end

      # A LEGACY CLAIMED ROW WHOSE ANSWER WAS LOST IS NOT A DRAFT EITHER. It
      # carries no signature, so the check above waves it through — but its wire
      # may be on the chain, and marking it `expired` would file a possible
      # rotation as one that never happened. Only rows claimed by the OLDER code
      # can be in this state; a claim now stamps its signature, so a modern
      # stranded row is caught by the `tx_signature.present?` check above and
      # cleared by #reconcile rather than by hand.
      if @tx.awaiting_reconciliation?
        return cancel_answer("This eviction was broadcast and the result was not read back, " \
                             "so it may be on chain. Read the signer set before discarding it.", ok: false)
      end

      rescue_and_log(target: @tx) do
        @tx.update!(status: "expired", stale: true)
        cancel_answer("Armed eviction discarded.", ok: true)
      end
    rescue StandardError => e
      cancel_answer(e.message, ok: false)
    end

    private

    # THE SIGNED SET MUST BE THE REVIEWED SET. The browser sends the set and
    # signers the operator READ (`reviewed_proposed`, `reviewed_authorizers`);
    # a fresh plan that differs (a pick changed after review, or the chain
    # moved) is refused before a row exists, rather than caught by the
    # read-back after it lands.
    def require_reviewed_set!(planned)
      reviewed = Array(params[:reviewed_proposed]).map { |k| k.to_s.strip }
      reviewed_signers = Array(params[:reviewed_authorizers]).map { |k| k.to_s.strip }
      return if reviewed == planned[:proposed] && reviewed_signers == planned[:authorizers]

      raise Solana::SignerPlan::Refusal.new(
        "The set or signers about to be built differ from the plan you reviewed " \
        "(reviewed #{reviewed.length} keys, built #{planned[:proposed].length}). Nothing was built; review again.",
        code: "reviewed_set_mismatch"
      )
    end

    # A failed read or build on the console is logged for triage, never
    # raised: the page answers it inline.
    def log_console_failure(error)
      ErrorLog.capture!(error)
    rescue StandardError
      nil
    end

    # The console calls #cancel with fetch the moment Phantom is declined; the
    # stranded panel still posts a form.
    def cancel_answer(message, ok:)
      if request.format.json?
        render json: { ok: ok, message: message }, status: ok ? :ok : :unprocessable_entity
      else
        redirect_to admin_authorities_path, (ok ? :notice : :alert) => message
      end
    end

    def plan_params
      {
        intent: params[:intent],
        remove: params[:remove],
        add: params[:add],
        confirm_unknown: params[:confirm_unknown]
      }
    end

    # The planner for THIS chain: a fresh read of the set and the program
    # shape. Raises (the caller answers 503) when the vault cannot be read: a
    # rotation is never planned blind.
    def planner_for(connected)
      state = vault.read_vault_state
      raise "Vault state could not be read; refusing to plan a rotation blind." if state.nil?

      governance = chain_governance!
      if governance != Solana::Config.governance?
        raise Solana::SignerPlan::Refusal.new(shape_disagreement_message(governance), code: "shape_mismatch")
      end

      Solana::SignerPlan.new(
        network: Solana::Config::NETWORK,
        governance: governance,
        current: state[:active_signers],
        required: governance ? Solana::Governance.required_signatures("update_signers") : Solana::SignerRotation::REQUIRED_V025,
        max_live_threshold: max_live_threshold,
        server: Solana::CosignPlan.admin_address,
        server_held: server_held_addresses,
        connected: connected
      )
    end

    def shape_disagreement_message(chain)
      if chain
        "The chain runs turf-vault v0.26 (GovernanceConfig exists) but this app is configured for v0.25. " \
          "Set #{Solana::Config::GOVERNANCE_ENV_VAR}=on and restart before rotating signers."
      else
        "This app is configured for turf-vault v0.26 but the GovernanceConfig PDA does not exist on " \
          "#{Solana::Config::NETWORK}. Run init_governance after the upgrade, or unset the switch."
      end
    end

    # PUBLIC addresses of SOLANA_COSIGNER_KEYS. A malformed list is reported
    # on the page (its message names public keys only) and holds no key.
    def server_held_addresses
      Solana::Keypair.cosigners.map(&:to_base58)
    rescue StandardError => e
      @server_held_error = "SOLANA_COSIGNER_KEYS could not be loaded: #{Solana::Config.redact_message(e.message)}"
      []
    end

    # The server-held keypairs the armed plan says sign on the server. A key
    # the plan counted on that this process no longer holds refuses the build
    # rather than quietly asking Phantom for it (Phantom does not hold it).
    def server_cosigner_keypairs!(plan)
      wanted = Array(plan[:server_held])
      return [] if wanted.empty?

      held = Solana::Keypair.cosigners.index_by(&:to_base58)
      missing = wanted - held.keys
      if missing.any?
        raise "This rotation was planned with #{missing.join(', ')} signing on the server, and this " \
              "process no longer holds it (SOLANA_COSIGNER_KEYS). Discard it and plan again."
      end

      wanted.map { |address| held.fetch(address) }
    end

    # Build the bytes for `plan` against a fresh read, store them on @tx with
    # a CONDITIONAL write, and answer the signing plan that travels with them.
    #
    # THE PLAN IS RE-VALIDATED AGAINST A FRESH CHAIN READ, not trusted from the
    # row: the set could have moved since the click, by another operator or by
    # the very thief this page exists to evict.
    def build_and_store!(plan)
      rotation = revalidate!(plan)
      shape    = vault_shape!

      result = vault.build_update_signers(
        new_signers: rotation.live_slots,
        lead_signer: plan[:lead_signer],
        cosigner_pubkey: plan[:authorizers][1],
        extra_cosigners: plan[:authorizers][2..] || [],
        server_cosigners: server_cosigner_keypairs!(plan)
      )

      # THE BYTES CARRY THE RECORDED SET, or nothing is written or sent.
      built_set = Array(result[:new_signers]).reject { |k| k.blank? || k == Solana::SignerRotation::EMPTY }
      if built_set != Array(plan[:proposed])
        raise "The built set (#{built_set.join(', ')}) differs from the recorded plan " \
              "(#{Array(plan[:proposed]).join(', ')}). Discard and plan again."
      end

      # The queue below and the broadcast check both assume who filled
      # account 0. If the build disagrees, nothing is written or sent.
      if result[:server_signed] != server_signs_lead?(plan)
        raise "The build #{result[:server_signed] ? 'signed' : 'left unsigned'} account 0, but " \
              "the armed plan expects it #{server_signs_lead?(plan) ? 'signed by this server' : 'left for your wallet'}. " \
              "Discard and re-arm this eviction."
      end

      # CONDITIONAL, NOT A BARE WRITE. `pending?` is a READ; a #broadcast that
      # claims the row in the interval leaves a bare write racing a wire that
      # is already going out (a bare `update!` omitted the unchanged status and
      # replaced the bytes anyway). Re-checking inside the UPDATE holds.
      rebuilt = PendingTransaction.where(id: @tx.id, status: "pending")
                                  .update_all(serialized_tx: result[:serialized_tx],
                                              updated_at: Time.current) == 1
      unless rebuilt
        raise "This eviction is no longer pending (it is now #{@tx.reload.status}) — " \
              "reconcile it against the chain rather than rebuilding it."
      end
      @tx.reload

      {
        status: "rebuilt",
        serialized_tx: result[:serialized_tx],
        # THE SIGNING PLAN TRAVELS WITH THE BYTES IT DESCRIBES.
        required_signatures: rotation.required,
        signer_queue: signer_queue_for(plan),
        cosigner_address: plan[:authorizers][1],
        extra_cosigners: plan[:authorizers][2..] || [],
        # NIL WHEN THE OPERATOR LEADS: the row is painted signed only when
        # the SERVER filled the slot at build time.
        fee_payer_address: server_signs_lead?(plan) ? plan[:lead_signer] : nil,
        # PUBLIC addresses of the keys the server signed for. Never a secret.
        server_signed: [server_signs_lead?(plan) ? plan[:lead_signer] : nil, *Array(result[:server_cosigned])].compact,
        shape: shape,
        new_signers: result[:new_signers]
      }
    end

    def expire_abandoned_rotations!
      PendingTransaction.where(tx_type: TX_TYPE, status: "pending", tx_signature: nil)
                        .where(created_at: ...STALE_PENDING_AFTER.ago)
                        .update_all(status: "expired", stale: true, updated_at: Time.current)
    end

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
        rotations.pending.where(created_at: STALE_PENDING_AFTER.ago..).order(created_at: :desc).first
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

      Solana::Governance.max_live_threshold(table[:thresholds])
    end

    # The wallets the browser collects in Phantom, in slot order. Server-led:
    # [cosigner, *extras], because the build already signed account 0.
    # Operator-led: [lead, cosigner, *extras].
    #
    # SERVER-HELD COSIGNERS ARE NEVER QUEUED: the build signed them, and
    # Phantom does not hold them. They sign only a server-led build.
    def signer_queue_for(plan)
      authorizers = Array(plan[:authorizers])
      return authorizers unless server_signs_lead?(plan)

      authorizers.drop(1) - Array(plan[:server_held])
    end

    # Whether the server signs account 0 at build time. Decided from the armed
    # plan and this process's key, never from the browser, so a request cannot
    # drop an operator's lead from the queue. `Vault#build_update_signers`
    # signs exactly when the lead is this key; `#rebuild` refuses a build that
    # disagrees.
    def server_signs_lead?(plan)
      server = Solana::CosignPlan.admin_address
      plan[:server_leads] == true && server.present? && plan[:lead_signer] == server
    end

    # What the browser CLAIMS signed, checked for count, order and membership
    # against the queue the server sent for this shape. Returns every signer
    # of the transaction, the server's lead included, for verification and the
    # record.
    def require_signer_queue!(plan)
      expected = signer_queue_for(plan)
      claimed  = Array(params[:signer_queue]).map { |a| a.to_s.strip }.reject(&:blank?)
      claimed  = Array(params[:cosigner_address]).map(&:to_s) + Array(params[:extra_cosigners]) if claimed.empty?
      claimed  = claimed.map { |a| a.to_s.strip }.reject(&:blank?)

      if claimed != expected
        raise "This broadcast names #{claimed.length} signer(s) (#{claimed.join(', ')}) but the " \
              "armed eviction reserved #{expected.length} slot(s) for #{expected.join(', ')}" \
              "#{server_signs_lead?(plan) ? ' (this server signs account 0 itself)' : ''}. " \
              "turf-vault reads those accounts positionally, so a different set is a different " \
              "transaction — re-arm rather than re-send."
      end

      Array(plan[:authorizers])
    end

    # EVERY claimed signer is asserted to be in a SIGNER SLOT of what landed —
    # not merely present in the transaction. turf-vault requires `info.is_signer`
    # on each leading remaining account, and a non-signer sitting in a cosigner
    # slot is what produces 6047 CosignerDidNotSign.
    def verify_landed!(signature:, signers:)
      vault_pda = Solana::Keypair.encode_base58(vault.vault_state_pda.first)

      signers.each_with_index do |address, i|
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
      server_leads = server_signs_lead?(plan)
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
