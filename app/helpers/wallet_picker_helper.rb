# frozen_string_literal: true

# Locals for solana-studio's Connect-Wallet picker
# (solana_studio/modals/_wallet_connect). It sat in studio-engine until
# /tasks/turf-rides-gem-modals; the locals contract did not change with the move.
#
# WHY A HELPER AND NOT TWO CALLSITES. The picker is mounted from BOTH layouts —
# layouts/application and layouts/modal_preview — and each keeps its own modal
# registration list, so anything written inline at the callsite has to be written
# twice and is then free to drift. That has bitten this app before (see the
# age-verify note in layouts/modal_preview: a modal registered in one layout and
# not the other renders as a blank card). Matching age_gate_modal_locals.
module WalletPickerHelper
  def wallet_connect_modal_locals
    {
      extra_data: wallet_connect_extra_data,
      # The attestation is the picker's SLOT — a named local holding a partial
      # path, never a block. `block_given?` is ALWAYS true inside a compiled
      # Rails partial, so a block-shaped slot falls through to
      # view_flow[:layout] and prints the whole page body inside the card, and
      # it only fires during the LAYOUT pass — exactly how a modal is mounted.
      #
      # The FLAG LIVES HERE, not in the partial: the engine's attestation
      # checkbox deliberately does not self-gate (unlike the turf fork deleted
      # in /tasks/adopt-engine-age-attestation), so with the flag parked off the
      # picker simply passes no slot.
      slot: (AppFlags.age_attestation? ? "modals/wallet_connect_attestation" : nil)
    }
  end

  private

  # EXTRA x-data members, as a JS fragment with no surrounding braces. The
  # engine picker merges it after its own built-ins and marks it html_safe, so
  # it reaches the attribute as written.
  #
  # NO DOUBLE QUOTES ANYWHERE IN HERE. The x-data attribute is double-quoted, so
  # a single " closes it early and Alpine mounts the component as a silent
  # no-op — a dead modal that every markup assertion still passes.
  # wallet_picker_single_phantom_test pins that.
  #
  # These are the four hooks the engine documents, plus the two state members
  # they read. Together they are the whole of what turf-monster adds to the
  # shared picker.
  def wallet_connect_extra_data
    <<~JS.strip
      ageAttested: false,
      ageError: false,
      // Show the legal-age attestation for guests (a wallet connect is
      // create-or-login, so a brand-new wallet creates an account). Linking
      // flows and logged-in users skip it. Server-side enforcement in
      // SolanaSessionsController#verify is the boundary for NEW accounts.
      // Hard false when the attestation flag is off, so canPick always passes.
      get needsAttestation() {
        if (!#{AppFlags.age_attestation?}) return false;
        var s = Alpine.store('session');
        return !this.props.linkMode && !(s && s.loggedIn);
      },
      onInit() {
        // Pre-check when the opener (the signin card) already collected it.
        this.ageAttested = this.props.ageAttested === true;
      },
      canPick() {
        if (!this.needsAttestation) return true;
        if (this.ageAttested) return true;
        this.ageError = true;
        return false;
      },
      verifyArgs() {
        return { ageAttested: this.ageAttested };
      },
      onDeepLink() {
        // The deep link round-trips out through the Phantom app - stash the
        // attestation alongside the other phantom_dl_* keys so the callback
        // page can include it in the verify POST.
        try { localStorage.setItem('phantom_dl_age_attested', this.ageAttested ? '1' : '0'); } catch (e) {}
        if (typeof startPhantomDeepLink === 'function') {
          startPhantomDeepLink(this.props.linkMode || false, (this.props.linkMode && this.props.currentUserId) || null);
        }
      },
      onBack() {
        // In-contest flow (swapped in from the auth modal) slides back to the
        // auth options; the step-up card gets back the card the user left;
        // standalone just closes, revealing the page's own choices.
        if (this.props.backTo === 'auth') {
          Alpine.store('modals').swap('auth',
            { step: 'credentials', submitting: null, formError: '', phantomError: '', googleError: '' },
            { direction: 'back' });
        } else if (this.props.backTo === 'web3-step-up') {
          Alpine.store('modals').swap('web3-step-up', this.props.stepUpProps || {}, { direction: 'back' });
        } else {
          Alpine.store('modals').close();
        }
      }
    JS
  end
end
