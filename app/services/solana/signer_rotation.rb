module Solana
  # One proposed `update_signers` rotation, judged against turf-vault's OWN
  # guards before a byte is built.
  #
  # ── WHY REFUSE IN RAILS WHEN THE PROGRAM ALREADY REFUSES ──────────────────
  #
  # Because of WHEN and HOW. The program's refusal arrives after the operator
  # has switched Phantom accounts two or three times and paid a fee, and it
  # arrives as `custom program error: 0x17a4`. This class refuses before the
  # first Phantom dialog, in a sentence that names the rule, the count and the
  # key. It widens NOTHING — `handle_update_signers` is the real gate and a set
  # this class approved can still be rejected on chain.
  #
  # ── THE ORDER OF THE CHECKS IS THE POINT, NOT AN IMPLEMENTATION DETAIL ────
  #
  # Anchor returns the FIRST failing constraint and stops. So a set that breaks
  # two rules surfaces only the earlier one, and a Rails-side validator that
  # checked them in a different order would name a DIFFERENT error than the
  # chain — sending the operator to fix the wrong thing during an incident.
  # Every `refuse!` below therefore carries the program's own error code, and
  # the sequence is copied from the handler rather than arranged for
  # readability.
  #
  #   v0.26 `handle_update_signers` (turf-vault accepted):
  #     authorize            -> Unauthorized 6000 / InsufficientSigners 6046
  #     gap before a live key-> SignerSetTooSmall 6052
  #     duplicate in the set -> DuplicateSigner 6014
  #     count <  required    -> SignerSetTooSmall 6052
  #     count <  max_live    -> SignerSetTooSmall 6052
  #     count >  MAX_SIGNERS -> SignerSetTooSmall 6052
  #     continuity           -> SignerContinuityRequired 6017
  #
  #   v0.25 (what is DEPLOYED on both clusters today) is a different program
  #   with a different order and a different shape — three slots, no empties
  #   allowed at all, exactly two signatures, and BOTH of them must survive:
  #     validate_multisig    -> Unauthorized 6000
  #     duplicate in the set -> DuplicateSigner 6014
  #     any zeroed slot      -> SignerContinuityRequired 6017
  #     continuity           -> SignerContinuityRequired 6017
  #
  # Both are implemented because both are real: `accepted` carries v0.26 and
  # the chain runs v0.25 (GovernanceConfig PDA absent on devnet and mainnet,
  # measured 2026-09-15). A validator that only knew the newer one would
  # cheerfully approve a five-slot set the live program cannot even decode.
  #
  # ── WHAT THIS CLASS DELIBERATELY DOES NOT DO ─────────────────────────────
  #
  # It does not decide WHICH keys to evict, and it has no notion of "the
  # compromised set". That is the operator's judgment, made on the page, and
  # baking a list of suspect keys into a service would be a second source of
  # truth for something only a human knows.
  class SignerRotation
    # The empty-slot sentinel. `Pubkey::default()` renders as this in base58 and
    # is what `all_signers()` skips.
    EMPTY = "11111111111111111111111111111111".freeze

    # Slot counts per deployed program shape.
    MAX_SLOTS_V025 = 3
    MAX_SLOTS_V026 = 5

    # Exactly two signatures on v0.25 — `validate_multisig` is structurally two
    # and never reads a threshold. Not a default that can be overridden: it is
    # what the deployed binary can express.
    REQUIRED_V025 = 2

    # A refusal that names the program error it is standing in for, so the
    # operator sees the same vocabulary here and in a failed simulation.
    class Refusal < StandardError
      attr_reader :code, :error_name

      def initialize(message, code:, error_name:)
        @code = code
        @error_name = error_name
        super("#{message} (turf-vault would reject this as #{error_name}, #{code}.)")
      end
    end

    UNAUTHORIZED   = { code: 6000, error_name: "Unauthorized" }.freeze
    DUPLICATE      = { code: 6014, error_name: "DuplicateSigner" }.freeze
    CONTINUITY     = { code: 6017, error_name: "SignerContinuityRequired" }.freeze
    INSUFFICIENT   = { code: 6046, error_name: "InsufficientSigners" }.freeze
    TOO_SMALL      = { code: 6052, error_name: "SignerSetTooSmall" }.freeze

    attr_reader :current_signers, :proposed, :authorizers, :required, :max_slots, :max_live_threshold

    # `governance:` selects the shape. True = the v0.26 five-slot program;
    # false = the deployed v0.25 three-slot one. Callers pass what they read
    # off the CHAIN (`Vault#read_governance` present or absent), never a
    # preference — see Admin::AuthoritiesController#vault_shape!.
    def self.for_chain(current_signers:, proposed:, authorizers:, governance:, max_live_threshold: nil)
      new(
        current_signers: current_signers,
        proposed: proposed,
        authorizers: authorizers,
        governance: governance,
        required: governance ? Governance.required_signatures("update_signers") : REQUIRED_V025,
        max_live_threshold: max_live_threshold
      )
    end

    def initialize(current_signers:, proposed:, authorizers:, governance:, required:,
                   max_live_threshold: nil)
      @governance      = governance
      @current_signers = normalize(current_signers)
      # NOT normalized — blanks are RETAINED so a gap can be detected. A
      # validator that compacted its input first could never refuse a gap,
      # because compacting IS the bug the program's gap rule exists to catch.
      @proposed        = Array(proposed).map { |k| k.to_s.strip }
      @authorizers     = normalize(authorizers)
      @required        = required.to_i
      @max_slots       = governance ? MAX_SLOTS_V026 : MAX_SLOTS_V025
      @max_live_threshold = max_live_threshold
    end

    def governance? = @governance

    # The live keys of the proposed set, in slot order, empties dropped.
    def live_slots
      @live_slots ||= proposed.reject { |k| k.blank? || k == EMPTY }
    end

    # The full slot array the instruction argument needs: live keys left-packed,
    # then the empty sentinel out to `max_slots`.
    def padded_slots
      live_slots + Array.new([max_slots - live_slots.length, 0].max, EMPTY)
    end

    def evicted  = current_signers - live_slots
    def retained = current_signers & live_slots
    def added    = live_slots - current_signers

    # Authorizers that would NOT survive this rotation. Displayed on the page
    # because an operator who signs himself out is the failure mode continuity
    # exists to catch, and the number is easier to read than the rule.
    def surviving_authorizers = authorizers & live_slots

    # Raises the FIRST Refusal the chain would raise, or returns self.
    def validate!
      validate_authorizers!
      if governance?
        validate_v026_set!
      else
        validate_v025_set!
      end
      validate_continuity!
      self
    end

    def valid?
      validate!
      true
    rescue Refusal
      false
    end

    # The refusal message, or nil. For rendering a live verdict beside the form
    # without making the caller rescue.
    def refusal_message
      validate!
      nil
    rescue Refusal => e
      e.message
    end

    # A summary the page and the PendingTransaction metadata both read, so what
    # the operator was shown and what the row records cannot drift.
    def to_plan
      {
        shape: governance? ? "v0.26" : "v0.25",
        required_signatures: required,
        max_slots: max_slots,
        current: current_signers,
        proposed: live_slots,
        padded: padded_slots,
        evicted: evicted,
        retained: retained,
        added: added,
        authorizers: authorizers
      }
    end

    private

    def normalize(keys)
      Array(keys).map { |k| k.to_s.strip }.reject { |k| k.blank? || k == EMPTY }
    end

    # `authorize` (v0.26) / `validate_multisig` (v0.25) runs BEFORE any shape
    # check, so its refusals come first here too.
    #
    # THE COUNT IS CHECKED, not just membership. `Admin::VaultStateController#confirm`
    # validates each extra signer's membership and never its count, so an
    # `unpause` needing three could be recorded on one proven signature. That
    # shape is not copied here: a rotation authorized by too few keys is
    # refused by the same method that refuses an unknown one.
    def validate_authorizers!
      if authorizers.uniq.length != authorizers.length
        dupes = authorizers.tally.select { |_, n| n > 1 }.keys
        refuse!("#{dupes.join(', ')} would authorize this rotation more than once; turf-vault " \
                "counts DISTINCT signers, so a repeat fails the whole transaction rather than " \
                "counting once", DUPLICATE)
      end

      unknown = authorizers - current_signers
      if unknown.any?
        refuse!("#{unknown.join(', ')} is not in the vault's on-chain signer set " \
                "(#{current_signers.join(', ')}), so it cannot authorize a rotation", UNAUTHORIZED)
      end

      return if authorizers.length >= required

      refuse!("this rotation needs #{required} vault #{'signature'.pluralize(required)} and " \
              "#{authorizers.length} #{authorizers.length == 1 ? 'was' : 'were'} named", INSUFFICIENT)
    end

    # v0.26: gaps, then duplicates, then the three count rules.
    def validate_v026_set!
      validate_no_gaps!
      validate_no_duplicates!

      count = live_slots.length
      if count < required
        refuse!("a #{count}-key set cannot satisfy update_signers' own threshold of #{required} — " \
                "the rotation would leave no route back", TOO_SMALL)
      end

      if max_live_threshold && count < max_live_threshold.to_i
        refuse!("a #{count}-key set cannot satisfy every live action: the highest on-chain " \
                "threshold is #{max_live_threshold}, and rotating below it would brick that action " \
                "with no way back except another rotation", TOO_SMALL)
      end

      return if count <= max_slots

      refuse!("#{count} keys exceeds the #{max_slots} slots VaultState has", TOO_SMALL)
    end

    # v0.25: duplicates, then ANY empty slot, then continuity. The deployed
    # program takes exactly three keys and refuses a zeroed slot outright, so
    # "evict down to three of five" is not expressible against it at all.
    def validate_v025_set!
      validate_no_duplicates!

      count = live_slots.length
      if count != max_slots
        refuse!("the deployed program takes exactly #{max_slots} signers and refuses a zeroed " \
                "slot, so a #{count}-key set cannot be written. Reducing the set below " \
                "#{max_slots} needs turf-vault v0.26 on chain first", CONTINUITY)
      end
    end

    def validate_no_gaps!
      seen_empty = false
      proposed.each_with_index do |key, i|
        if key.blank? || key == EMPTY
          seen_empty = true
        elsif seen_empty
          refuse!("slot #{i + 1} holds a key while an earlier slot is empty. turf-vault refuses a " \
                  "gap so that \"empty\" is always a suffix — left-pack the set and let the " \
                  "trailing slots go empty", TOO_SMALL)
        end
      end
    end

    def validate_no_duplicates!
      dupes = live_slots.tally.select { |_, n| n > 1 }.keys
      return if dupes.empty?

      refuse!("#{dupes.join(', ')} appears more than once. A duplicated signer silently shrinks " \
              "the effective set, so turf-vault rejects the whole rotation", DUPLICATE)
    end

    # At least `required` of the keys that AUTHORIZE this rotation must survive
    # it. Runs LAST on both shapes, matching the handler.
    #
    # It is what stops an operator signing himself out of his own vault, and it
    # is NOT what stops an eviction: a key that did not authorize the rotation
    # may be dropped freely, which is exactly how the compromised keys leave.
    def validate_continuity!
      survivors = surviving_authorizers.length
      return if survivors >= required

      lost = authorizers - live_slots
      refuse!("#{survivors} of the #{authorizers.length} authorizing " \
              "#{'wallet'.pluralize(authorizers.length)} would survive this rotation and " \
              "#{required} must. #{lost.join(', ')} would sign the transaction and then be " \
              "evicted by it, leaving the vault unable to reach #{required} signatures again",
              CONTINUITY)
    end

    def refuse!(message, kind)
      raise Refusal.new(message, **kind)
    end
  end
end
