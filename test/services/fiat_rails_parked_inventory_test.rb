require "test_helper"

# [unit] The parked-rails inventory. FiatRailsParked lists every fiat
# controller action, job and view, and this test DISCOVERS fiat code on disk
# and in the router and fails when something is missing from the list, so a
# new fiat file cannot ship ungated. Each view's gate kind is then measured:
# the predicate it names must be false while parked, and every render site
# must sit under it.
class FiatRailsParkedInventoryTest < ActiveSupport::TestCase
  PROVIDER = /stripe|paypal|coinflow|aeropay/i

  # Source that names a fiat model, client or the deposit ledger a fiat job
  # writes. Used to discover jobs.
  FIAT_SOURCE = /StripePurchase|PaypalPurchase|CoinflowPurchase|AeropayPurchase|Stripe::|Paypal::|Coinflow::|Aeropay::|stripe_session_id|Deposits::OnchainReconciler/

  # The guard each predicate kind must find around a render site.
  GUARDS = {
    coinflow: /AppFlags\.coinflow\?|onramp_rail_visible\?\(:coinflow\)/,
    aeropay: /AppFlags\.aeropay\?|onramp_rail_visible\?\(:aeropay\)/,
    paypal: /Payments\.paypal_checkout\?|entry_funding_mode == :paypal/,
    stripe: /Payments\.stripe\?|entry_funding_mode == :stripe/
  }.freeze
  ANY_FIAT_GUARD = Regexp.union(*GUARDS.values, /AppFlags\.fiat_rails\?/)
  WHOLE_FILE_KINDS = %i[parked_action coinflow aeropay paypal stripe].freeze

  def with_env(pairs)
    originals = pairs.keys.index_with { |key| ENV[key] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Every per-provider switch on; only ENABLE_FIAT_RAILS varies.
  def with_providers_on(fiat:)
    config = Rails.application.config.x
    saved = [config.payment_provider, config.stripe_enabled, config.paypal_enabled]
    with_env("ENABLE_FIAT_RAILS" => (fiat ? "true" : nil), "ENABLE_COINFLOW" => "true", "ENABLE_AEROPAY" => "true") do
      config.payment_provider = "paypal"
      config.paypal_enabled = true
      config.stripe_enabled = true
      yield
    end
  ensure
    config.payment_provider, config.stripe_enabled, config.paypal_enabled = saved
  end

  # One answer per predicate kind, read with the providers forced on. PayPal
  # and Stripe are one PAYMENT_PROVIDER apart, so each is read under its own.
  def predicate_answers
    helpers = ApplicationController.helpers
    config = Rails.application.config.x
    answers = {
      coinflow: [AppFlags.coinflow?, helpers.onramp_rail_visible?(:coinflow)],
      aeropay: [AppFlags.aeropay?, helpers.onramp_rail_visible?(:aeropay)],
      paypal: [Payments.paypal_checkout?, helpers.onramp_rail_visible?(:paypal), helpers.onramp_rail_visible?(:venmo)]
    }
    config.payment_provider = "stripe"
    answers[:stripe] = [Payments.stripe?, helpers.onramp_rail_visible?(:stripe)]
    answers
  ensure
    config.payment_provider = "paypal"
  end

  def view_source(path)
    Rails.root.join(path).read
  end

  # The code of a view with ERB comments and whole-line JS comments removed,
  # so a comment that names a route is not mistaken for a caller.
  def view_code(path)
    view_source(path).gsub(/<%#.*?%>/m, "").lines.reject { |line| line.strip.start_with?("//") }.join
  end

  def view_files
    Dir[Rails.root.join("app/views/**/*.erb")].map { |f| f.delete_prefix("#{Rails.root}/") }
  end

  def parked_route_markers
    Rails.application.routes.routes.each_with_object([]) do |route, markers|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller && action && FiatRailsParked.parked_action?(controller, action)

      markers << route.path.spec.to_s.sub("(.:format)", "")
      markers << "#{route.name}_path" << "#{route.name}_url" if route.name
    end.uniq
  end

  # [file, line_index] for every `render "<partial>"` in the views.
  def render_sites(partial)
    pattern = /render\s*\(?\s*["']#{Regexp.escape(partial)}["']/
    view_files.flat_map do |file|
      view_source(file).lines.each_with_index.filter_map { |line, i| [file, i] if line.match?(pattern) && !line.strip.start_with?("<%#") }
    end
  end

  # The condition of the nearest ERB if/elsif/unless enclosing line `index`,
  # walking up and skipping closed blocks; nil when the line sits under an
  # `else` or at top level (no positive guard).
  def enclosing_condition(lines, index)
    depth = 0
    (index - 1).downto(0) do |i|
      line = lines[i]
      tags = line.scan(/<%-?\s*(.*?)\s*-?%>/m).flatten
      tags.reverse_each do |tag|
        if tag.match?(/\Aend\b/)
          depth += 1
        elsif tag.match?(/\A(if|unless)\b/) || tag.match?(/\bdo(\s*\|[^|]*\|)?\z/)
          if depth.positive?
            depth -= 1
          elsif tag.match?(/\A(if|unless)\b/)
            return tag
          end
        elsif depth.zero? && tag.match?(/\Aelsif\b/)
          return tag
        elsif depth.zero? && tag.match?(/\Aelse\z/)
          return nil
        end
      end
    end
    nil
  end

  def partial_name(path)
    path.delete_prefix("app/views/").sub(%r{/_([^/]+)\.html\.erb\z}, '/\1')
  end

  # A render site is gated when its file is itself rendered only under a gate
  # (a whole-file kind), or when the site sits under `guard`.
  def guarded?(file, index, guard)
    return true if WHOLE_FILE_KINDS.include?(FiatRailsParked::VIEW_GATES[file])

    lines = view_source(file).lines
    lines[index].match?(guard) || enclosing_condition(lines, index).to_s.match?(guard)
  end

  # ── Controllers ────────────────────────────────────────────────────────

  test "unit every controller named for a provider is parked whole" do
    Dir[Rails.root.join("app/controllers/**/*_controller.rb")].each do |file|
      path = file.delete_prefix("#{Rails.root}/app/controllers/").delete_suffix("_controller.rb")
      next unless path.match?(PROVIDER)

      assert_equal :all, FiatRailsParked::CONTROLLER_ACTIONS[path],
                   "#{path} is a fiat controller; park it in FiatRailsParked::CONTROLLER_ACTIONS"
    end
  end

  test "unit every routed action or path named for a provider is parked" do
    Rails.application.routes.routes.each do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller && action
      next unless "#{route.path.spec} #{action}".match?(PROVIDER)
      next if controller.start_with?("rails/")

      assert FiatRailsParked.parked_action?(controller, action),
             "#{controller}##{action} (#{route.path.spec}) is a fiat route; add it to FiatRailsParked::CONTROLLER_ACTIONS"
    end
  end

  test "unit every parked action is a real controller action" do
    FiatRailsParked::CONTROLLER_ACTIONS.each do |path, actions|
      klass = "#{path.camelize}Controller".constantize
      next if actions == :all

      actions.each do |action|
        assert_includes klass.action_methods, action, "#{path}##{action} is parked but no longer exists; drop it"
      end
    end
  end

  # ── Jobs ───────────────────────────────────────────────────────────────

  test "unit every job that touches fiat money is parked" do
    discovered = Dir[Rails.root.join("app/jobs/**/*_job.rb")].filter_map do |file|
      source = File.read(file)
      code = source.lines.reject { |line| line.strip.start_with?("#") }.join
      next unless File.basename(file).match?(PROVIDER) || code.match?(FIAT_SOURCE)

      source[/^\s*class\s+([\w:]+)/, 1]
    end

    assert_equal discovered.sort, FiatRailsParked::JOBS.sort,
                 "the fiat jobs on disk and FiatRailsParked::JOBS disagree"
  end

  test "unit every parked job inherits the gate" do
    FiatRailsParked::JOBS.each do |name|
      callbacks = name.constantize._perform_callbacks.map(&:filter)
      assert_includes callbacks, :skip_parked_fiat_job, "#{name} does not run FiatRailsJobGate"
    end
  end

  # ── Views ──────────────────────────────────────────────────────────────

  test "unit every view named for a provider or calling a parked route is inventoried" do
    markers = parked_route_markers
    refute_empty markers, "no parked routes found; this discovery has gone blind"

    discovered = view_files.select do |file|
      code = view_code(file)
      File.basename(file).match?(PROVIDER) || markers.any? { |marker| code.include?(marker) }
    end

    missing = discovered - FiatRailsParked::VIEW_GATES.keys
    assert_empty missing, "fiat views missing from FiatRailsParked::VIEW_GATES: #{missing.join(', ')}"
  end

  test "unit every inventoried view exists" do
    FiatRailsParked::VIEW_GATES.each_key do |path|
      assert Rails.root.join(path).exist?, "#{path} is inventoried but gone; drop it"
    end
  end

  test "unit each predicate gate is false while parked even with every provider on" do
    with_providers_on(fiat: false) do
      predicate_answers.each do |kind, answers|
        assert answers.none?, "#{kind} predicates answer #{answers.inspect} while parked"
      end
    end

    # Control: the same predicates open with the flag on, so the parked answer
    # above is the flag's doing.
    with_providers_on(fiat: true) do
      predicate_answers.each do |kind, answers|
        assert answers.all?, "#{kind} predicates answer #{answers.inspect} with the flag on"
      end
    end
  end

  test "unit every render site of a predicate-gated partial sits under its predicate" do
    FiatRailsParked::VIEW_GATES.each do |path, kind|
      next unless GUARDS.key?(kind)

      sites = render_sites(partial_name(path))
      refute_empty sites, "#{path} has no render site; drop it or fix the discovery" unless path.end_with?("buy.html.erb")
      sites.each do |file, index|
        assert guarded?(file, index, GUARDS[kind]),
               "#{file}:#{index + 1} renders #{path} outside #{GUARDS[kind].source}"
      end
    end
  end

  test "unit a partial rendered only by fiat views has every caller gated" do
    FiatRailsParked::VIEW_GATES.each do |path, kind|
      next unless kind == :fiat_callers

      sites = render_sites(partial_name(path))
      refute_empty sites
      sites.each do |file, index|
        assert guarded?(file, index, ANY_FIAT_GUARD),
               "#{file}:#{index + 1} renders #{path} without a fiat gate"
      end
    end
  end

  test "unit a parked-action view belongs to a parked action and has no other caller" do
    FiatRailsParked::VIEW_GATES.each do |path, kind|
      next unless kind == :parked_action

      controller, action = path.delete_prefix("app/views/").delete_suffix(".html.erb").split("/", 2).then { |c, a| [c, a] }
      assert FiatRailsParked.parked_action?(controller, action), "#{path} is not the view of a parked action"
      assert_empty render_sites("#{controller}/#{action}"), "#{path} is rendered from elsewhere"
    end
  end

  test "unit a fiat_rails view checks the master flag itself" do
    FiatRailsParked::VIEW_GATES.each do |path, kind|
      next unless kind == :fiat_rails

      assert_match(/AppFlags\.fiat_rails\?/, view_code(path), "#{path} claims an explicit gate but has none")
    end
  end

  test "unit the contest board's status poll treats a parked 404 as not ready" do
    FiatRailsParked::VIEW_GATES.each do |path, kind|
      next unless kind == :fiat_return_poll

      code = view_code(path)
      assert_match(%r{fetch\('/tokens/status\?}, code, "#{path} no longer polls /tokens/status; drop the exemption")
      assert_match(/if \(r\.ok\)/, code, "#{path} polls /tokens/status without an r.ok check, so a parked 404 would be parsed as an answer")
    end
  end

  # ── The enclosing-condition walker, controlled ─────────────────────────

  test "unit control: the walker finds a guard across a closed block and refuses an else" do
    lines = [
      "<% if AppFlags.coinflow? %>\n",
      "  <% unless Rails.env.production? %>\n",
      "    <p>dev</p>\n",
      "  <% end %>\n",
      "  <%= render \"tokens/coinflow_script\" %>\n",
      "<% else %>\n",
      "  <%= render \"tokens/coinflow_script\" %>\n",
      "<% end %>\n"
    ]
    assert_equal "if AppFlags.coinflow?", enclosing_condition(lines, 4)
    assert_nil enclosing_condition(lines, 6)
  end
end
