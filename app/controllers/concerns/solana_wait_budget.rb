# How long a Solana RPC call made from a web request may spend WAITING
# between retries (Solana::Client wait budgets, solana-studio >= 0.12.3).
#
# Two bounds apply to every request:
#
#   * per call: REQUEST seconds of waits, or the tighter budget a path below
#     names. A call its own budget stops raises its last error (an HttpError
#     429, say), which Solana::ErrorInterpreter words as "network is busy".
#   * per request: Solana::Deadline::WEB seconds from the start. Each call
#     waits the smaller of its own budget and the time left, and a call the
#     deadline stops raises Solana::Deadline::Exceeded, answered 503 below.
#
# Solana::Deadline lists what runs outside the deadline: a send and what
# follows it, and the LONG_BUDGET calls. LONG_BUDGET_ACTIONS names the
# actions that run there whole.
#
# Both bounds cover the SLEEPS between attempts, not the time an attempt
# spends on the wire (the gem's own open and read timeouts). The per-call
# budget is thread-local and the deadline lives on Current, so a Thread.new
# body opens its own (#under_navbar_hydrate_budget).
#
# Jobs do not include this: ApplicationJob sets their deadline, and their
# calls keep the gem's 15-second default.
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
    rescue_from Solana::Deadline::Exceeded, with: :render_rpc_deadline
  end

  private

  def run_under_solana_wait_budget(&block)
    Solana::Client.with_wait_budget(SolanaWaitBudget::REQUEST) do
      Solana::Deadline.within(Solana::Deadline::WEB) do
        name = Solana::Deadline::LONG_BUDGET_ACTIONS["#{controller_path}##{action_name}"]
        name ? Solana::Deadline.long_budget(name, &block) : block.call
      end
    end
  end

  # One navbar hydrate read, inside its own thread. `deadline` is the
  # request's Solana::Deadline.current, read before the thread starts.
  def under_navbar_hydrate_budget(deadline, &block)
    Solana::Deadline.at(deadline) do
      Solana::Client.with_wait_budget(SolanaWaitBudget::NAVBAR_HYDRATE, &block)
    end
  end

  # 503 with Retry-After. Exceeded is raised only before any send, so the
  # body's "nothing was sent" holds.
  def render_rpc_deadline(error)
    response.set_header("Retry-After", Solana::Deadline::RETRY_AFTER.to_s)
    if respond_to?(:render_api_error, true)
      render_api_error(:rpc_deadline, error.message, status: :service_unavailable)
    elsif request.format.html?
      render plain: error.message, status: :service_unavailable
    else
      render json: { error: error.message, error_code: "RPC_DEADLINE" }, status: :service_unavailable
    end
  end
end
