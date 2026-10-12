module Solana
  # The rotation ceremony for THIS cluster (config/signer_ceremony.yml) with
  # each step's preconditions read live and rendered as verdicts. The page is
  # the handoff between Mr. McRitchie and Steffon: a runbook step turns green
  # when the chain or this process shows it done, with no chat in between.
  #
  # Verdicts:
  #   hard   must pass before a console step's link is live
  #   soft   shown with the reading; does not block
  #   manual the page cannot read it; the operator ticks it in his head
  class SignerCeremony
    PATH = Rails.root.join("config/signer_ceremony.yml").freeze
    LOCK_WINDOW = 6.hours

    Check = Struct.new(:id, :label, :level, :ok, :detail, keyword_init: true)

    attr_reader :network

    # Every input is a READ the caller made (or nil when it failed), so this
    # class does no I/O of its own beyond the database counts and is testable
    # with plain values.
    def initialize(network:, chain_set:, chain_governance:, config_governance:, server:, server_held:,
                   fee_payer: nil, steps: nil, roster: SignerRoster.default)
      @network = network.to_s
      @chain_set = chain_set
      @chain_governance = chain_governance
      @config_governance = config_governance
      @server = server
      @server_held = Array(server_held)
      @fee_payer = fee_payer
      @roster = roster
      @steps = steps || Array(YAML.safe_load_file(PATH)[@network])
    end

    def steps
      @steps.map { |step| evaluate(step) }
    end

    def name_for(address) = @roster[address]&.name || "Unknown key"

    private

    def evaluate(step)
      kind = step["kind"].to_s
      done = kind == "console" ? same_set?(@chain_set, step["end"]) : runbook_done?(step["done_when"] || {})
      checks = kind == "console" && !done ? console_checks(step) : []
      ready = kind == "console" && !done && checks.select { |c| c.level == :hard }.all?(&:ok)

      {
        id: step["id"], kind: kind, title: step["title"], who: step["who"], note: step["note"],
        runbook: step["runbook"], done: done == true, ready: ready, checks: checks,
        status: if done == true then "done"
                elsif done.nil? then "unread"
                elsif kind == "console" then ready ? "ready" : "blocked"
                else "waiting"
                end,
        console_path: kind == "console" ? console_path(step) : nil,
        start: step["start"], end: step["end"]
      }
    end

    def console_checks(step)
      open_rows = PendingTransaction.where(status: %w[pending submitted]).count
      locking = Contest.where(starts_at: Time.current..LOCK_WINDOW.from_now).where.not(status: "settled").count
      owed = Contest.where(status: "settlement_pending").count

      [
        Check.new(id: "chain_set", label: "The chain's set is this step's starting set", level: :hard,
                  ok: same_set?(@chain_set, step["start"]) == true,
                  detail: @chain_set.nil? ? "The vault could not be read." : "Chain holds #{@chain_set.length} keys."),
        Check.new(id: "shape", label: "Program shape and the app's switch agree", level: :hard,
                  ok: !@chain_governance.nil? && @chain_governance == @config_governance,
                  detail: @chain_governance.nil? ? "GovernanceConfig could not be read." :
                          "Chain #{@chain_governance ? 'v0.26' : 'v0.25'}; app #{@config_governance ? 'v0.26' : 'v0.25'}."),
        Check.new(id: "server", label: "This server signs as #{name_for(step['server'])}", level: :hard,
                  ok: @server.present? && @server == step["server"],
                  detail: @server.present? ? "Server key: #{@server}" : "This process holds no admin key."),
        Check.new(id: "window_cosigners", label: "Window cosigners are held by the server", level: :hard,
                  ok: (Array(step["window_cosigners"]) - @server_held).empty?,
                  detail: missing_cosigners(step)),
        Check.new(id: "no_open_rows", label: "No transaction is pending or in flight", level: :hard,
                  ok: open_rows.zero?, detail: "#{open_rows} open."),
        Check.new(id: "fee_payer", label: "The server can pay the fee", level: :hard,
                  ok: @fee_payer && @fee_payer[:funded] == true,
                  detail: @fee_payer&.dig(:balance_sol) ? format("%.4f SOL", @fee_payer[:balance_sol]) : "Balance unread."),
        Check.new(id: "contests", label: "No contest starts in the next 6 hours; no settlement owed", level: :soft,
                  ok: locking.zero? && owed.zero?, detail: "#{locking} starting soon, #{owed} owed."),
        Check.new(id: "manual", label: "No deploy in flight; Phantom on a desktop as the signing account",
                  level: :manual, ok: nil, detail: "Not readable here.")
      ]
    end

    def missing_cosigners(step)
      missing = Array(step["window_cosigners"]) - @server_held
      return "None needed." if Array(step["window_cosigners"]).empty?
      return "Held." if missing.empty?

      "Not held: #{missing.map { |a| name_for(a) }.join(', ')} (Steffon sets SOLANA_COSIGNER_KEYS)."
    end

    # true/false, or nil when the chain could not be read.
    def runbook_done?(rule)
      return @server.present? && @server == rule["server"] if rule["server"]
      return @server_held.empty? if rule["no_window_cosigners"]
      return nil if rule["not_seated"] && @chain_set.nil?
      return (Array(rule["not_seated"]) & @chain_set).empty? if rule["not_seated"]

      false
    end

    def same_set?(chain, expected)
      return nil if chain.nil?

      chain.sort == Array(expected).sort
    end

    def console_path(step)
      query = { intent: step["intent"], remove: Array(step["remove"]).join(","), add: Array(step["add"]).join(",") }
      "/admin/authorities?#{query.compact_blank.to_query}"
    end
  end
end
