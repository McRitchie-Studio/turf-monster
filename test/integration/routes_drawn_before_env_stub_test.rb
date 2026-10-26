require "test_helper"
require "open3"

# The route-draw leak (folded into /tasks/turf-adopts-css-first-tailwind).
#
# Rails 8.1 draws routes LAZILY: with eager_load off (a `bin/rails test` or
# `rake` run), config/routes.rb is evaluated by the first request or URL helper
# that needs it, in whatever state the process is in AT THAT MOMENT. Its
# `unless Rails.env.production?` block (toast_test, seeds_lab, the live score
# injectors) therefore draws or not depending on who goes first. Tests that fake
# production with `Rails.env.stub(:production?, true)` (for one,
# test/integration/web2_entry_token_funding_test.rb#in_production) could be a
# worker's FIRST draw, and then that worker drew the production route set for
# the rest of its life: every later admin page errored `undefined local variable
# or method 'toast_test_path'`. Seed-dependent and parallel-only in CI; locally
# `--seed 2` of the funding test plus test/views/admin_hub_benchmarks_link_test.rb
# reproduced it every time.
#
# The fix is that test/test_helper.rb draws the routes itself, once, before
# `parallelize` forks and before any test can stub the environment.
#
# WHY A SUBPROCESS. In this process the routes were drawn long ago by whichever
# test ran first, so an in-process check would pass with or without the fix.
# A fresh process that loads test_helper exactly as the runner does, with
# eager_load OFF (CI unset; eager loading would draw at boot and hide the
# leak), then forces the first draw inside a production stub, is the
# order-independent form of the failure: it is red without the fix.
#
# Solana::Config is held to the same rule: its body reads Rails.env.production?
# at load, so it too must load before any stub (test_helper loads it).
class RoutesDrawnBeforeEnvStubTest < ActiveSupport::TestCase
  PROBE = <<~'RUBY'
    require "./test/test_helper"
    loaded_before_stub = Rails.application.routes_reloader.loaded
    network_inside_stub = Rails.env.stub(:production?, true) do
      Rails.application.reload_routes_unless_loaded
      Solana::Config::NETWORK
    rescue => e
      "RAISED #{e.message}"
    end
    puts "solana_network=#{network_inside_stub}"
    helpers = Rails.application.routes.url_helpers
    puts "loaded_before_stub=#{loaded_before_stub}"
    puts "toast_test_path=#{helpers.respond_to?(:toast_test_path) ? helpers.toast_test_path : 'MISSING'}"
    puts "seeds_lab_path=#{helpers.respond_to?(:seeds_lab_path) ? helpers.seeds_lab_path : 'MISSING'}"
  RUBY

  test "routes and Solana::Config load before a test can stub Rails.env.production?" do
    env = { "CI" => nil, "COVERAGE" => nil, "PARALLEL_WORKERS" => "1", "RAILS_ENV" => "test", "SOLANA_NETWORK" => nil }
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", PROBE, chdir: Rails.root.to_s)
    report = out.lines.grep(/\A(loaded_before_stub|toast_test_path|seeds_lab_path|solana_network)=/).join

    assert status.success?, "the probe process failed:\n#{out.lines.last(20).join}"
    # Control: the probe really ran with lazy routes (eager_load off), so the
    # assertions below are about the draw order and not about eager loading.
    refute_empty report, "the probe printed nothing it was asked to:\n#{out.lines.last(20).join}"
    assert_includes report, "loaded_before_stub=true",
                    "test_helper finished loading with the routes still UNDRAWN, so the first test to " \
                    "need them draws them in whatever state it is in:\n#{report}"
    assert_includes report, "toast_test_path=/toast_test", "a production stub drew the routes:\n#{report}"
    assert_includes report, "seeds_lab_path=/seeds_lab", "a production stub drew the routes:\n#{report}"
    # Solana::Config reads Rails.env.production? in its body; first loaded inside
    # the stub it raises (SOLANA_NETWORK unset) or keeps production values.
    assert_includes report, "solana_network=devnet",
                    "Solana::Config first loaded inside a production stub:\n#{report}"
  end
end
