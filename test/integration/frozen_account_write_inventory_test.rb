require "test_helper"

# THE FREEZE HOLDS BY CONSTRUCTION, and this is the proof that it does.
#
# OPSEC-048: a frozen account may read and may not write. FrozenAccountGuard is
# default-deny on every request that is not a GET or a HEAD, so the claim this
# file checks is not "someone remembered the gate on action X". It is: EVERY
# routed write, today's and any added later, either runs the gate or is named
# below with a reason.
#
# It discovers the write endpoints from the route set itself — no hand list of
# what exists — and for each one asks the controller class:
#
#   * does its callback chain run :refuse_frozen_account_writes, unconditionally
#     (no only:/if: that could leave this action out)?
#   * if the action is opted out (allow_frozen_account_writes), is that exact
#     controller#action listed in EXEMPT_ACTIONS here, with the same reason?
#
# So a new write route on a controller outside the gate, or a new opt-out
# nobody wrote down here, reddens this file. An entry here that no longer
# matches the code reddens it too, so the list cannot rot into a decoy.
class FrozenAccountWriteInventoryTest < ActiveSupport::TestCase
  READ_VERBS = %w[GET HEAD].freeze

  # controller#action => the reason its controller states. A frozen account may
  # still do these. Each one either acts for no one, only removes access, or
  # signs in (a read: the freeze holds actions, not access).
  EXEMPT_ACTIONS = {
    "sessions#create"                 => "signing in is a read: the freeze holds actions, not access",
    "sessions#sso_continue"           => "signing in is a read: the freeze holds actions, not access",
    "registrations#create"            => "signing in is a read: the freeze holds actions, not access",
    "magic_links#create"              => "signing in is a read: the freeze holds actions, not access",
    "magic_links#consume"             => "signing in is a read: the freeze holds actions, not access",
    "studio/links#consume"            => "signing in is a read: the freeze holds actions, not access",
    "admin/impersonations#destroy"    => "the admin's Return: ends an impersonation of a frozen account",
    "api_keys#destroy"                => "revoking a key removes access; it grants nothing",
    "api_keys#create"                 => "asks api_key_mint_blocker first, which refuses :frozen inside the keys card's own frame",
    "newsletter#unsubscribe"          => "opting out of email is always allowed",
    "experiment_events#create"        => "an anonymous A/B beacon; records a page view, acts for no one",
    "solana_sessions#report_failure"  => "client wallet-failure telemetry; writes a log line, acts for no one",
    "contests#discard_prepared_entry" => "drops an unsigned prepared entry; it can only undo, never enter",
    "mcp#rpc"                         => "one POST carries every tool; each writing tool asks write_refusal itself",
    "test#set_frozen"                 => "e2e fixture that lifts the freeze; never routed in production"
  }.freeze

  # Routed writes whose controller is not ours and has no signed-in player to
  # freeze: Rails' own framework endpoints.
  EXEMPT_CONTROLLER_PREFIXES = {
    "action_mailbox/"         => "inbound email ingress: authenticated by the provider's password, no session",
    "rails/conductor/"        => "Rails' development-only inbound email conductor, not routed in production",
    "active_storage/"         => "a blob upload attached to nothing; the attach is a guarded write (avatar, banner)"
  }.freeze

  # Mounted Rack apps: no controller, no callback chain.
  EXEMPT_MOUNTS = {
    "/admin/jobs" => "Sidekiq::Web, behind the admin constraint; an operator tool, not a player write",
    "/assets"     => "Propshaft's static asset server; reads only",
    "/cable"      => "ActionCable: Turbo Stream broadcasts out; app/channels defines no client action in"
  }.freeze

  def write_routes
    Rails.application.routes.routes.filter_map do |route|
      verbs = route.verb.to_s.split("|")
      next if verbs.empty? || (verbs - READ_VERBS).empty?

      controller = route.defaults[:controller]
      next if controller.nil?

      { controller: controller, action: route.defaults[:action].to_s, verb: route.verb, path: route.path.spec.to_s }
    end.uniq { |r| [r[:controller], r[:action]] }
  end

  def framework_exempt?(controller)
    EXEMPT_CONTROLLER_PREFIXES.keys.any? { |prefix| controller.start_with?(prefix) }
  end

  def gate_callback(klass)
    klass._process_action_callbacks.find { |cb| cb.kind == :before && cb.filter == :refuse_frozen_account_writes }
  end

  test "the route set has write endpoints to check (the floor)" do
    routes = write_routes
    # 150+ on 2026-10-06. A parse that silently matched nothing would pass
    # everything below, so the sweep must see a real number and known writes.
    assert_operator routes.size, :>=, 150, "found only #{routes.size} write routes"
    keys = routes.map { |r| "#{r[:controller]}##{r[:action]}" }
    %w[contests#enter messages#create accounts#update_username api/v1/entries#create mcp#rpc wallets#withdraw].each do |key|
      assert_includes keys, key
    end
  end

  test "every routed write runs the freeze gate or is a named exemption" do
    unguarded = []

    write_routes.each do |route|
      key = "#{route[:controller]}##{route[:action]}"
      next if framework_exempt?(route[:controller])

      klass = "#{route[:controller].camelize}Controller".safe_constantize
      if klass.nil?
        unguarded << "#{key} (#{route[:verb]} #{route[:path]}): no controller class"
        next
      end

      callback = gate_callback(klass)
      if callback.nil?
        unguarded << "#{key} (#{route[:verb]} #{route[:path]}): #{klass} never runs the freeze gate"
        next
      end
      # No conditions on the gate: a skip_before_action or an only:/if: would
      # turn up here as a condition, and an action could slip out of it unseen.
      conditions = callback.instance_variable_get(:@if).to_a + callback.instance_variable_get(:@unless).to_a
      unguarded << "#{key}: the freeze gate carries a condition" if conditions.any?

      if klass.frozen_write_exempt?(route[:action])
        unless EXEMPT_ACTIONS.key?(key)
          unguarded << "#{key}: opted out with allow_frozen_account_writes but not listed in EXEMPT_ACTIONS"
        end
      end
    end

    assert_empty unguarded, "A frozen account could write through:\n  #{unguarded.join("\n  ")}"
  end

  test "every listed exemption is real, routed, and carries the controller's own reason" do
    routed = write_routes.map { |r| "#{r[:controller]}##{r[:action]}" }

    EXEMPT_ACTIONS.each do |key, reason|
      controller, action = key.split("#")
      klass = "#{controller.camelize}Controller".constantize
      assert_includes routed, key, "#{key} is listed but no write route reaches it"
      assert klass.frozen_write_exempt?(action), "#{key} is listed here but the controller does not opt it out"
      assert_equal reason, klass.frozen_write_exemptions.fetch(action.to_sym),
                   "#{key}: the reason here and in the controller disagree"
    end
  end

  test "the agent API authenticates before it asks the freeze" do
    [Api::V1::BaseController, McpController].each do |klass|
      names = klass._process_action_callbacks.select { |cb| cb.kind == :before }.map(&:filter)
      assert_operator names.index(:authenticate_api_key!), :<, names.index(:refuse_frozen_account_writes),
                      "#{klass}: the freeze gate must run after the key resolves current_user"
    end
  end

  test "every mounted app is a known one that takes no player write" do
    mounts = Rails.application.routes.routes.select { |r| r.defaults[:controller].nil? && r.verb.to_s.empty? }
                  .map { |r| r.path.spec.to_s.sub(/\(.*\z/, "") }.uniq
    assert_equal EXEMPT_MOUNTS.keys.sort, mounts.reject(&:empty?).sort
  end
end
