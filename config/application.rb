require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TurfMonster
  class Application < Rails::Application
    # Configuration defaults. Upgraded from the originally generated 7.2 to 8.1.
    # All six new_framework_defaults_8_1 toggles were reviewed individually:
    # four adopted as the 8.1 default (path-relative redirect :raise — turf has
    # zero bare-string redirects; finder order-column raise; :ruby render tracker;
    # hidden-field autocomplete removal), and two JSON-escaping toggles kept at
    # the stricter pre-8.1 behavior below (Audit JSON-1).
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Use Sidekiq for background jobs
    config.active_job.queue_adapter = :sidekiq

    # Escape <, >, & in JSON string values (Rails default is false). Defense-in-depth
    # for every `.to_json` rendered inside a <script> block — a stray unescaped
    # </script> or HTML metachar can't break out of the JSON island. (Audit JSON-1.)
    config.active_support.escape_html_entities_in_json = true

    # Rails 8.1 splits U+2028 / U+2029 (line/paragraph separator) escaping out of
    # escape_html_entities_in_json into its own flag, defaulting it OFF. Keep it ON
    # to preserve turf's pre-8.1 script-island defense for `.to_json` output (same
    # Audit JSON-1 rationale as above). NOTE: the sibling controller-renderer flag
    # action_controller.escape_json_responses is intentionally left at the 8.1
    # default — it only affects `render json:` API responses (never embedded in a
    # <script>), and Rails 8.1 already deprecates setting it to true (removed in 8.2).
    config.active_support.escape_js_separators_in_json = true

    # Active Storage variants run through ImageMagick, NOT libvips. Rails 8.1
    # defaults variant_processor to :vips, and libvips is absent everywhere this
    # app runs — measured 2026-09-08 on turf-monster-mainnet (heroku-26),
    # turf-monster-qa (heroku-24) and the development Mac: `command -v vips` finds
    # nothing on all three while /usr/bin/magick is present on all three. Left at
    # the default, the contest link-preview card (Contest's :og_card variant)
    # would raise on every render. ruby-vips stays in the Gemfile for Active
    # Storage's block_untrusted hardening (see the Gemfile note) — this flag only
    # decides which processor renders a variant.
    config.active_storage.variant_processor = :mini_magick

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
