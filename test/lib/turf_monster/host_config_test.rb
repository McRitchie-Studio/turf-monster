require "minitest/autorun"
require_relative "../../../lib/turf_monster/host_config"

class TurfMonster::HostConfigTest < Minitest::Test
  def test_aliases_strips_blanks_and_ignores_empty_entries
    aliases = TurfMonster::HostConfig.aliases(" app.turfmonster.media, ,www.turfmonster.media ")

    assert_equal [ "app.turfmonster.media", "www.turfmonster.media" ], aliases
  end

  def test_public_hosts_keeps_canonical_host_first_and_removes_duplicates
    hosts = TurfMonster::HostConfig.public_hosts(
      app_host: "turfmonster.media",
      aliases: [ "app.turfmonster.media", "turfmonster.media" ]
    )

    assert_equal [ "turfmonster.media", "app.turfmonster.media" ], hosts
  end

  def test_allowed_https_origins_matches_exact_https_origins
    origins = TurfMonster::HostConfig.allowed_https_origins([
      "turfmonster.media",
      "app.turfmonster.media"
    ])

    assert origins.any? { |origin| origin.match?("https://turfmonster.media") }
    assert origins.any? { |origin| origin.match?("https://app.turfmonster.media") }
    assert origins.none? { |origin| origin.match?("http://turfmonster.media") }
    assert origins.none? { |origin| origin.match?("https://evil-turfmonster.media") }
  end

  # --- route_url_options ------------------------------------------------------
  #
  # These options are what Rails.application.routes falls back to when there is
  # no request. Leave any branch without a host and RouteSet#default_env answers
  # with "example.org" instead — silently, in production. See
  # /tasks/blob-url-uses-example-org and the mechanism note on the method.

  def test_production_route_url_options_use_app_host_over_https
    options = TurfMonster::HostConfig.route_url_options(
      env: "production", app_host: "app.turfmonster.media"
    )

    assert_equal({ host: "app.turfmonster.media", protocol: "https" }, options)
  end

  def test_production_route_url_options_fall_back_to_the_canonical_host
    [ nil, "", "   " ].each do |unset|
      options = TurfMonster::HostConfig.route_url_options(env: "production", app_host: unset)

      assert_equal TurfMonster::HostConfig::DEFAULT_APP_HOST, options[:host],
                   "APP_HOST=#{unset.inspect} must fall back to the canonical host"
      assert_equal "https", options[:protocol]
    end
  end

  def test_test_route_url_options_match_the_mailer_host
    options = TurfMonster::HostConfig.route_url_options(env: "test")

    assert_equal({ host: "www.example.com", protocol: "http" }, options)
  end

  def test_development_route_url_options_point_at_this_desk_port
    options = TurfMonster::HostConfig.route_url_options(env: "development", app_port: "3116")

    assert_equal({ host: "localhost", port: 3116, protocol: "http" }, options)
  end

  def test_development_route_url_options_fall_back_to_the_default_dev_port
    [ nil, "", "0" ].each do |unset|
      options = TurfMonster::HostConfig.route_url_options(env: "development", app_port: unset)

      assert_equal TurfMonster::HostConfig::DEFAULT_DEV_PORT, options[:port],
                   "APP_PORT=#{unset.inspect} must fall back to the default dev port"
    end
  end

  def test_no_environment_ever_yields_the_placeholder_host
    %w[production development test staging].each do |env|
      options = TurfMonster::HostConfig.route_url_options(env: env)

      refute_nil options[:host], "#{env} produced no host — Rails would invent example.org"
      refute_empty options[:host].to_s
      refute_equal TurfMonster::HostConfig::PLACEHOLDER_HOST, options[:host]
    end
  end
end
