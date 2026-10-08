module Studio
  # How this app proves itself to the McRitchie Studio hub.
  #
  # Two credentials, read in this order:
  #
  # - STUDIO_RUNTIME_KEY: this app's own runtime key. The hub mints it for the
  #   turf-monster client soul, and it reaches exactly the two endpoints this app
  #   calls (GET /api/v1/athletes, POST /api/v1/game_recaps). It is presented as
  #   the bearer directly; there is no exchange call.
  # - AGENT_API_SECRET: the hub's shared agent secret, exchanged at POST
  #   /api/v1/auth for a 24-hour token. Read only while STUDIO_RUNTIME_KEY is
  #   unset.
  #
  # Neither value is ever logged or raised.
  module HubCredential
    KEY_ENV = "STUDIO_RUNTIME_KEY".freeze
    SECRET_ENV = "AGENT_API_SECRET".freeze
    # The request header that names the caller in the hub's legacy-use census.
    CALLER_HEADER = "X-Agent-Caller".freeze
    MISSING = "neither #{KEY_ENV} nor #{SECRET_ENV} is set".freeze

    module_function

    def runtime_key = ENV[KEY_ENV].to_s.strip.presence
    def secret = ENV[SECRET_ENV].presence

    # A stack with neither credential does not talk to the hub at all.
    def configured? = runtime_key.present? || secret.present?
  end
end
