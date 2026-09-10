# What is this account still missing, in the order we ask for it?
#
# ONE resolver for the post-auth chain, so "which modal comes next" is decided
# server-side in a single place instead of being spread across three controllers
# and a layout script. Two named flows, in order (operator spec, 2026-08-15):
#
#   Onboarding    :first_name  — captured for marketing; SKIPPABLE
#   Wallet setup  :age         — the DOB gate
#                 :wallet      — link Phantom
#
# THE WELCOME BEAT IS GONE (operator call, 2026-08-15). A "you're in, here's
# your username" card opened the chain until then; it cost a click and told the
# user something they had not asked for, so the chain now greets with the first
# real question. Removed rather than skipped: a step nothing ever emits is a
# dead branch in the modal, the driver and this list at once.
#
# Each step is listed only while it is still OUTSTANDING, so the chain a user
# walks is exactly what they have left: a returning web2 player with a funded
# managed wallet and a verified DOB gets `[]` and sees nothing.
#
# WHAT THIS IS NOT: an enforcement boundary. It decides what to ASK and in what
# order. Every gate keeps its own teeth — the age gate still blocks at entry
# (eligibilityBlocker + the server-side entry check) and the wallet gate still
# refuses in ContestsController#enter — because the chain is dismissible and a
# user who closes it must not thereby skip a gate. See the age note below.
class OnboardingFlow
  STEPS = [:first_name, :age, :wallet].freeze

  def initialize(user, skipped_first_name: false, age_gate_enabled: false)
    @user = user
    @skipped_first_name = skipped_first_name
    @age_gate_enabled = age_gate_enabled
  end

  # Ordered, outstanding steps. Empty when there is nothing to ask.
  def steps
    return [] if user.blank?

    STEPS.select { |step| send(:"#{step}_outstanding?") }
  end

  def self.steps_for(user, **opts)
    new(user, **opts).steps
  end

  private

  attr_reader :user

  # Marketing wants a first name; friction says do not wall a brand-new user in
  # behind it. So: asked while blank, dropped for the rest of the session the
  # moment they skip.
  #
  # Delegated to the engine (studio-engine 0.46.0), which now owns this rule for
  # every Studio app — McRitchie Studio and McRitchie Industries ask the same
  # question. The rule left here would be a second copy free to drift from the
  # one the shared endpoint enforces; what stays turf's is the ORDER around it,
  # which is the rest of this file.
  def first_name_outstanding?
    Studio.first_name_outstanding?(user, skip_session)
  end

  # The engine reads the skip from a session-shaped object; this flow is handed a
  # boolean by the controller. Same key either way — Studio::FIRST_NAME_SKIP_SESSION_KEY
  # IS :onboarding_skipped_first_name, the key this app already wrote.
  def skip_session
    @skipped_first_name ? { Studio::FIRST_NAME_SKIP_SESSION_KEY => true } : {}
  end

  # ENABLE_AGE_GATE only. Prompting here is a MOVE of the prompt, not of the
  # gate: the entry-time check stays exactly where it was, so dismissing this
  # step costs the user an extra prompt at hold-time and never buys them an
  # unverified entry.
  def age_outstanding?
    return false unless @age_gate_enabled

    user.age_attested_at.blank?
  end

  # Delegates to the one rule that already owns this question (including the
  # "grandfathered web2 user holding >= 19 USDC is fine as-is" bypass), so the
  # chain and the entry gate can never disagree about who needs a wallet.
  def wallet_outstanding?
    WalletSetupPolicy.required_for?(user)
  end
end
