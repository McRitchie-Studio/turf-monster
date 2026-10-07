# How long a Solana RPC call made from a web request may spend WAITING
# between retries (solana-studio >= 0.12.3, Solana::Client wait budgets).
#
# The gem's default budget is 15 seconds of waits per #call. That suits a
# Sidekiq job, which has no deadline. It does not suit a request: Heroku cuts
# a request at 30 seconds, and a page or JSON endpoint that makes two or three
# throttled calls at 15 seconds each answers with a router H12 instead of an
# error the client can show. So every request runs under REQUEST seconds per
# call, and the paths named below run tighter still.
#
# The budget bounds the SLEEPS between attempts only, not the time an attempt
# spends on the wire (the gem's own open/read timeouts), and it is per #call,
# not per request. It is thread-local: `Solana::Client.with_wait_budget` sets
# it for the current thread, so a Thread.new body must open its own block
# (see ApplicationController#fetch_navbar_hydrate).
#
# When the budget stops a call, the call raises its last error at once
# (`Solana::Client::HttpError` 429, say), with `call_stats.budget_stopped`
# set. Every caller already handles that error; Solana::ErrorInterpreter
# turns a rate limit into a "network is busy" message.
#
# Jobs do not include this, and keep the gem's 15-second default.
module SolanaWaitBudget
  extend ActiveSupport::Concern

  # Every Solana call a request makes, unless a path below names its own.
  REQUEST = 5
  # Each navbar hydrate read (balances, seeds, entry tokens). These run after
  # first paint, and a missing value is shown as "unknown", so they give up
  # first.
  NAVBAR_HYDRATE = 2
  # The account preamble of an entry (Vault#ensure_user_account).
  ENSURE_USER_ACCOUNT = 5

  included do
    # Prepended so the before_actions that read the chain run inside it too.
    prepend_around_action :run_under_solana_wait_budget
  end

  private

  def run_under_solana_wait_budget(&block)
    Solana::Client.with_wait_budget(SolanaWaitBudget::REQUEST, &block)
  end
end
