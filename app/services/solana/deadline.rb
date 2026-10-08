module Solana
  # One deadline for every Solana RPC call a request or job makes.
  #
  # Inside `within`, each Solana::Client#call waits at most the smaller of its
  # own wait budget and the time left. A call that starts with no time left,
  # or that the shortened budget stops, raises Exceeded. Controllers answer
  # Exceeded with 503 (SolanaWaitBudget#render_rpc_deadline).
  #
  # The deadline bounds the sleeps between attempts. The time one attempt
  # spends on the wire is the gem's (Solana::Client#http_post).
  #
  # Two things run outside the deadline, each under the per-call budget it
  # already has:
  #
  #   * a `sendTransaction`, and every call after it in the same request or
  #     job. So Exceeded always means this request or job sent nothing.
  #   * a `long_budget` block, named in LONG_BUDGET.
  module Deadline
    class Exceeded < StandardError
      def initialize(message = "The Solana network is slow right now. Nothing was sent. Try again in a moment.")
        super
      end
    end

    # Seconds. Heroku's router cuts a request at 30.
    WEB = 25
    JOB_DEFAULT = 120
    # The Retry-After a 503 carries.
    RETRY_AFTER = 5
    SENDS = %w[sendTransaction].freeze
    RELEASED = :released

    # Calls the deadline never shortens or refuses: each spends a player's
    # money or decides whether a spend landed. One line per `long_budget`
    # block, with the per-call wait budget it runs under.
    LONG_BUDGET = {
      managed_entry_spend: "Entries::ManagedEntry#call around #fund!: slot probe, funding reads, send and confirm (15 s)",
      cosign_submit: "Solana::Vault#under_cosign_wait_budget: simulate, send and confirm of a cosigned entry, contest creation, contest time or settlement (5 s)",
      api_entry_submission: "Entries::ApiSubmission#call: the orphan probe that decides whether an earlier spend landed, then the managed spend (5 s, 15 s in #fund!)",
      entry_reconcile: "Entries::OnchainReconciler#reconcile_entry: reads whether a paid entry landed (the caller's budget)",
      entry_confirm: "contests#confirm_onchain_entry: the Phantom cosign and the verify that confirms the entry (5 s)",
      entry_recovery: "contests#recover_pending_entry: the verdict on a broadcast entry (5 s)",
      contest_create: "contests#finalize, #finalize_bundle and #confirm_onchain_contest: the creation cosign and its verify (5 s)",
      reconcile_sweep: "the reconciler jobs: each row is a verdict on a spend (15 s)",
      free_entries_refresh: "Admin::FreeEntriesRefreshJob: reads for every user in the batch, with no spend (15 s)"
    }.freeze

    # Whole actions that run as a `long_budget` block.
    LONG_BUDGET_ACTIONS = {
      "contests#confirm_onchain_entry" => :entry_confirm,
      "contests#recover_pending_entry" => :entry_recovery,
      "contests#finalize" => :contest_create,
      "contests#finalize_bundle" => :contest_create,
      "contests#confirm_onchain_contest" => :contest_create
    }.freeze

    class << self
      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def job_seconds
        Float(ENV.fetch("SOLANA_JOB_DEADLINE", JOB_DEFAULT))
      end

      # Runs the block under a deadline `seconds` from now, or under the one
      # already set when that is sooner.
      def within(seconds, &block)
        at(clock + seconds, &block)
      end

      # Runs the block under `deadline`, a `current` value. A Thread.new body
      # takes its parent's deadline this way: Current does not cross threads.
      def at(deadline)
        previous = Current.rpc_deadline
        Current.rpc_deadline = previous == RELEASED ? RELEASED : [previous, deadline].compact.min
        yield
      ensure
        # A send inside the block releases the enclosing deadline too.
        Current.rpc_deadline = previous && Current.rpc_deadline == RELEASED ? RELEASED : previous
      end

      # Runs the block outside the deadline. `name` is a LONG_BUDGET key.
      def long_budget(name)
        LONG_BUDGET.fetch(name)
        previous = Current.rpc_long_budget
        begin
          Current.rpc_long_budget = name
          yield
        ensure
          Current.rpc_long_budget = previous
        end
      end

      # The deadline to hand a thread, or nil when none applies.
      def current
        Current.rpc_deadline if remaining
      end

      # Seconds left, or nil when no deadline applies.
      def remaining
        deadline = Current.rpc_deadline
        return nil if deadline.nil? || deadline == RELEASED || Current.rpc_long_budget

        deadline - clock
      end

      def release!
        Current.rpc_deadline = RELEASED if Current.rpc_deadline
      end
    end

    # Prepended over Solana::Client#call, outside Solana::ClientLogger
    # (config/initializers/solana_deadline.rb).
    module ClientCall
      private

      def call(method, params = [])
        Solana::Deadline.release! if SENDS.include?(method.to_s)
        left = Solana::Deadline.remaining
        return super if left.nil?
        raise Exceeded if left <= 0

        own = Thread.current[Solana::Client::WAIT_BUDGET_KEY] || wait_budget
        return super if own <= left

        begin
          Solana::Client.with_wait_budget(left) { super }
        rescue Solana::Client::RpcError => e
          raise unless e.call_stats&.budget_stopped

          raise Exceeded
        end
      end
    end
  end
end
