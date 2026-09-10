module TurfMonster
  module HostConfig
    # The canonical public hostname when APP_HOST is unset. Lives here so the
    # production environment file and the route-set defaults below cannot drift
    # onto two different answers.
    DEFAULT_APP_HOST = "turfmonster.media".freeze

    # turf-monster's dev server runs on 3100 (3000 is mcritchie-studio); a
    # worktree desk overrides it with APP_PORT, exactly as the mailer does.
    DEFAULT_DEV_PORT = 3100

    # The host Rails invents when nothing supplies one — see route_url_options.
    PLACEHOLDER_HOST = "example.org".freeze

    module_function

    def aliases(raw_aliases)
      raw_aliases.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def public_hosts(app_host:, aliases:)
      [ app_host, *aliases ].uniq
    end

    def allowed_https_origins(hosts)
      hosts.map { |host| %r{\Ahttps://#{Regexp.escape(host)}\z} }
    end

    # Defaults for Rails.application.routes.default_url_options — the host that
    # URL helpers use when there is NO REQUEST to read one from.
    #
    # WHY THIS EXISTS (/tasks/blob-url-uses-example-org). A Turbo Stream
    # broadcast renders its partial through ApplicationController.render, i.e.
    # ActionController::Renderer, which has no request. The renderer builds its
    # Rack env from ActionDispatch::Routing::RouteSet#default_env
    # (actionpack-8.1.3.1 lib/action_dispatch/routing/route_set.rb:441), and
    # that line hard-codes `host: "example.org"` whenever the route set carries
    # no default_url_options. It does not raise; it just answers wrong. Since
    # ActionView resolves image_tag's non-String source through polymorphic_URL
    # (resolve_image_source), a broadcast-rendered Active Storage attachment is
    # ABSOLUTE — so production browsers were served
    # https://example.org/rails/active_storage/blobs/redirect/... for chat and
    # leaderboard avatars on the contest live page.
    #
    # Setting the ROUTE SET's defaults closes every out-of-request helper at
    # once (broadcasts, jobs, any render outside a request) instead of patching
    # one partial. It cannot hijack a live request: RouteSet#url_for merges
    # these UNDER the options its caller passes, and a controller's url_options
    # already carry request.host — verified by
    # test/models/broadcast_blob_url_host_test.rb and
    # test/integration/request_host_wins_over_route_defaults_test.rb.
    #
    # Pure Ruby on purpose: test/lib/turf_monster/host_config_test.rb loads this
    # file standalone, without Rails or ActiveSupport.
    def route_url_options(env:, app_host: nil, app_port: nil)
      case env.to_s
      when "production"
        { host: presence(app_host) || DEFAULT_APP_HOST, protocol: "https" }
      when "test"
        # Matches config.action_mailer.default_url_options so the whole suite
        # reads one host.
        { host: "www.example.com", protocol: "http" }
      else
        { host: "localhost", port: port_or_default(app_port), protocol: "http" }
      end
    end

    def presence(value)
      trimmed = value.to_s.strip
      trimmed.empty? ? nil : trimmed
    end

    def port_or_default(app_port)
      port = presence(app_port).to_i
      port.positive? ? port : DEFAULT_DEV_PORT
    end
  end
end
