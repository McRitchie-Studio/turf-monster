# frozen_string_literal: true

module TurfMonster
  module QaRehearsal
    # Enters one cast member into one contest, over HTTP, exactly as a browser
    # would — cart, picks, prepare, sign, confirm.
    #
    # Deliberately the SLOW path. `Solana::Vault#enter_contest` could put an
    # entry on-chain in one server-side call, but it would skip everything this
    # rehearsal exists to exercise: assert_enterable!, the lock-time check, the
    # exactly-picks_required rule, the per-user limit, the duplicate-combo rule,
    # and the sybil check. A rehearsal that avoided the gates would certify a
    # pipeline nobody actually runs.
    #
    # The signature seam is the only place this differs from a real player: the
    # wire that comes back from #prepare_entry is FULLY unsigned (the admin is
    # reserved as fee-payer but does not sign until confirm time), so the driver
    # fills only the player's slot and leaves the admin's empty — which is why
    # it passes `require_complete: false`. The server cosigns, simulates,
    # broadcasts and verifies, precisely as it does for Phantom.
    class EntryFlow
      class EntryError < StandardError; end

      attr_reader :session, :contest_slug, :picks

      # @param session [WalletSession] already signed in
      # @param contest_slug [String]
      # @param matchup_ids [Array<Integer>] candidate matchups, in board order
      # @param picks_required [Integer]
      def initialize(session:, contest_slug:, matchup_ids:, picks_required:)
        if matchup_ids.size < picks_required
          raise ArgumentError,
                "need at least #{picks_required} matchups, got #{matchup_ids.size}"
        end

        @session = session
        @contest_slug = contest_slug
        @picks = matchup_ids.first(picks_required)
      end

      def call
        session.verify_age!
        clear_cart
        build_cart
        prepared = prepare
        confirm(prepared)
      end

      private

      def path(action)
        "/contests/#{contest_slug}/#{action}"
      end

      # START FROM A KNOWN-EMPTY CART.
      #
      # This step used to skip clear_picks deliberately, because clear_picks
      # abandoned the cart entry while LEAVING its entry_number set, and the
      # allocator would then hand the same number back into a partial unique
      # index that still counted the abandoned row. Calling it was the one move
      # that made this step permanently un-rerunnable.
      #
      # That app bug is fixed — Entry releases the slot on abandon, except when
      # the row carries an on-chain signature (see Entry#release_slot_if_abandoned).
      # So the workaround is retired, and retiring it FIXES a defect of its own:
      # toggle_selection TOGGLES, so a re-run over a partial cart turned the
      # existing picks OFF and errored, and a third run oscillated. Clearing
      # first is what makes this step re-runnable, which is the whole reason an
      # operator can watch it fail and simply run it again.
      # CHECK THE ANSWER. WalletSession#post_json returns whatever the server
      # said — it does not raise on a 4xx — so a refused clear comes back as
      # `{ "success" => false, "error" => ... }` from a 422 and reads exactly
      # like a success to anyone who discards it. This call used to, and was
      # the only one in the flow that did; the flow then built picks onto a
      # cart it had not cleared and ran to completion, which is precisely the
      # oscillation the clear exists to prevent.
      #
      # Presence of `error`, not truthiness of `success`, mirroring build_cart:
      # clear_picks answers `{ success: true }` even when there was no cart to
      # clear, and parse_json answers `{}` for an empty body — so an
      # error-presence check cannot refuse a clear that actually succeeded.
      def clear_cart
        response = session.post_json(path("clear_picks"))
        return if response["error"].blank?

        raise EntryError, "clear_picks refused: #{response['error']}"
      end

      def build_cart
        picks.each_with_index do |matchup_id, index|
          response = session.post_json(path("toggle_selection"), matchup_id: matchup_id)

          if response["error"].present?
            raise EntryError, "pick #{matchup_id} refused: #{response['error']}"
          end

          # Assert the server's own count rather than trusting the loop. A
          # toggle that silently no-opped would otherwise surface much later as
          # "exactly N picks required" from prepare_entry, pointing at the wrong
          # step.
          expected = index + 1
          actual = response["selection_count"]
          next if actual == expected

          raise EntryError,
                "after #{expected} pick(s) the server reports #{actual.inspect} selected — " \
                "the cart is not tracking what this step believes it built"
        end
      end

      def prepare
        response = session.post_json(path("prepare_entry"))

        unless response["success"] && response["serialized_tx"].present?
          raise EntryError, "prepare_entry refused: #{response['error'] || response.inspect}"
        end

        response
      end

      def confirm(prepared)
        signed = Solana::Transaction.cosign_wire_base64(
          prepared.fetch("serialized_tx"),
          signer: session.keypair,
          require_complete: false
        )

        # Echo back EVERYTHING prepare handed over, the way the board does
        # (`{ signed_tx, entry_id, entry_pda, ptx_slug }`). entry_pda is not
        # decoration: the server re-derives the PDA from the entry's number and
        # compares it to this value, so omitting it does not skip the check —
        # it fails it, with "Entry PDA mismatch", which reads like a wallet
        # problem rather than a missing field.
        response = session.post_json(path("confirm_onchain_entry"),
          entry_id:  prepared.fetch("entry_id"),
          entry_pda: prepared["entry_pda"],
          ptx_slug:  prepared["ptx_slug"],
          signed_tx: signed)

        unless response["success"]
          raise EntryError, "confirm_onchain_entry refused: #{response['error'] || response.inspect}"
        end

        response.merge("entry_id" => prepared["entry_id"], "token_funded" => prepared["token_funded"])
      end
    end
  end
end
