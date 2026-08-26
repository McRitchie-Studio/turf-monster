# frozen_string_literal: true

# Does THIS SESSION owe a wallet signature before it is really the user it says?
#
# The situation this names: an account secured by a self-custody wallet signs in
# with email or Google. Both facts are true at once and neither is wrong —
# the account holds a Phantom-class wallet (an identity fact), and the session
# was established by a web2 credential (a session fact). studio-engine's
# SessionContext has modelled that intersection since it was lifted out of this
# app — `web2?` AND `phantom_linked?` — but nothing ever acted on it, so a wallet
# owner arriving by magic link was logged straight in with no web3 beat at all.
# This policy is the missing verdict; SessionContext stays the state.
#
# The rule, in order:
#   1. No user                 -> NO. A guest owes nothing; they owe a login.
#   2. Session already :web3   -> NO. They signed THIS session (onchain_session?),
#                                 which is the very thing a step-up asks for.
#   3. No self-custody wallet  -> NO. A managed/web2-only account is fully
#                                 served by the session it just established.
#      Note this is deliberately NOT the same question WalletSetupPolicy asks.
#      That one asks "should this account GET a wallet?"; this one asks "should
#      this SESSION prove the wallet it already has?" — opposite populations,
#      which is why a user can never be shown both (a phantom_wallet? account
#      exits WalletSetupPolicy at its own step 1).
#   4. Otherwise               -> YES.
#
# ADVISORY, NOT AN ENFORCEMENT BOUNDARY (operator call, 2026-08-21). A `true`
# here opens a DISMISSIBLE modal; it does not suspend the session. The teeth are
# where they already were — ContestsController#enter refuses a web3 session
# OUTRIGHT (routing it to prepare_entry -> confirm_onchain_entry, where the
# signed transaction is the proof), and every on-chain path still demands a live
# signature — so this moves
# the PROMPT to sign-in without moving any gate, exactly the way the age gate's
# prompt moved to onboarding while its enforcement stayed at entry. Getting this
# backwards would lock a legitimate owner out of their own account over a
# wallet they merely cannot reach right now.
#
# NO I/O. Unlike WalletSetupPolicy (which reads a balance), every input here is a
# column or a session flag, so this is safe on the render path and costs nothing
# to ask twice.
class Web3StepUpPolicy
  # `session_mode` is SessionContext#mode — :guest / :web2 / :web3. Taking the
  # mode rather than a bare boolean keeps the callsite honest: the caller has to
  # have consulted the canonical session model to answer, instead of inferring
  # "this must be web2 because of which controller I am in". Two auth paths call
  # this and BOTH were web2-by-construction when it was written; that is precisely
  # the kind of fact that quietly stops being true.
  def initialize(user, session_mode:)
    @user = user
    @session_mode = session_mode
  end

  def self.required_for?(user, session_mode:)
    new(user, session_mode: session_mode).required?
  end

  def required?
    return false if user.blank?
    return false if @session_mode == :web3
    return false unless self_custodied?

    true
  end

  # The brand this account last proved a signature with, normalised, or nil.
  # nil is a first-class answer — every wallet linked before the provider column
  # existed has one — and it means the modal opens the full picker instead of a
  # one-click "Continue with Phantom".
  def provider
    return nil if user.blank?

    Solana::WalletProvider.normalize(user.web3_wallet_provider)
  end

  # How that brand writes its own name, for the CTA. nil when unremembered.
  def provider_label
    Solana::WalletProvider.label(provider)
  end

  # The truncated address the user will recognise on their own wallet's account
  # screen — 4 leading and 4 trailing base58 characters, the convention every
  # Solana wallet UI uses. Shown under the CTA so the user can confirm we are
  # asking for the wallet they think we are before they open the extension.
  def wallet_hint
    address = user&.web3_solana_address.to_s
    return nil if address.length < 12

    "#{address.first(4)}…#{address.last(4)}"
  end

  # The payload the layout serialises for the step-up modal. Shaped like
  # SessionContext#to_h (camelCase, cheap, no RPC) because it is read by the same
  # Alpine layer.
  def to_h
    {
      provider:      provider,
      providerLabel: provider_label,
      walletHint:    wallet_hint
    }
  end

  private

  attr_reader :user

  # Asked through respond_to? for the same reason SessionContext#phantom_linked?
  # is: this policy is written to lift into solana-studio, where the host's User
  # may not implement wallet predicates at all.
  def self_custodied?
    user.respond_to?(:phantom_wallet?) && user.phantom_wallet?
  end
end
