class Entry
  # A rule said no, and nothing was spent.
  #
  # Every read-only gate on the way to an entry (Entry#assert_enterable!,
  # #update_picks!, #assign_onchain_entry_number!, and the funding choice in
  # Entries::ManagedEntry) raises one of these. It is a RuntimeError with the
  # same message the bare `raise "..."` it replaced carried, so the browser
  # path reads exactly as before: ContestsController#render_entry_error still
  # hands the message to Solana::ErrorInterpreter, and a caller rescuing
  # StandardError or RuntimeError still catches it.
  #
  # What it adds is `code`: a stable name for WHICH rule refused, so the agent
  # API (docs/AGENT_API.md) can answer `contest_full` or `team_locked` without
  # matching on message text that is written for a person and free to change.
  class Refusal < RuntimeError
    attr_reader :code

    def initialize(code, message)
      @code = code.to_sym
      super(message)
    end
  end
end
