# What is this account still missing, in the order we ask for it?
#
# ONE resolver for the post-auth chain, so "which modal comes next" is decided
# server-side in a single place instead of being spread across three controllers
# and a layout script. Two named flows, in order (operator spec, 2026-08-12):
#
#   Onboarding    :welcome     — "you're in, here's your username"
#                 :first_name  — captured for marketing; SKIPPABLE
#   Wallet setup  :age         — the DOB gate
#                 :wallet      — link Phantom
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
  STEPS = [:welcome, :first_name, :age, :wallet].freeze

  def initialize(user, welcome: false, skipped_first_name: false, age_gate_enabled: false)
    @user = user
    @welcome = welcome
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

  # Shown once, for an account created in this session. The caller passes the
  # flag (only the signup controllers know a create from a login) rather than
  # inferring it from created_at, which would re-fire on every login inside some
  # arbitrary window.
  def welcome_outstanding?
    @welcome
  end

  # Marketing wants a first name; friction says do not wall a brand-new user in
  # behind it. So: asked while blank, dropped for the rest of the session the
  # moment they skip.
  def first_name_outstanding?
    return false if @skipped_first_name

    user.first_name.blank?
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
