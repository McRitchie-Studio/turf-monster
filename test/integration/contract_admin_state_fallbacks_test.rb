require "test_helper"

# admin-state-rescue-messages-mislead — the three `(X rescue "...")` fallbacks in
# app/views/contract/_section_admin_state.html.erb must describe the state that
# ACTUALLY produces them.
#
# THE DEFECT WAS THE MESSAGE, NOT THE RESCUE. Each fallback named an env var and
# declared it "not set". None of those three variables can reach a RENDERED page
# unset:
#
#   * SOLANA_PROGRAM_ID and SOLANA_NETWORK back LOAD-TIME constants that raise
#     during eager load in production (OPSEC-012; for NETWORK, unset, empty and
#     whitespace-only alike since empty-solana-network-fails-open / PR 559).
#     production.rb sets `config.eager_load = true`, so a missing value stops
#     BOOT — the dyno never serves the page the fallback would appear on. Dev
#     and test resolve both to devnet defaults and cannot raise at all.
#   * Solana::Config.squads_vault_pda never raises anywhere: env override, else
#     a network-keyed default. And its key is ABSENT from turf-monster-mainnet
#     and turf-monster-qa alike (re-verified 2026-09-06 by KEY PRESENCE —
#     `heroku config --json -a <app> | jq 'has("SOLANA_SQUADS_VAULT_PDA")'`
#     answers false on both), which is the CORRECT state: the cluster default is
#     the path every production render takes. So "(SOLANA_SQUADS_VAULT_PDA not
#     set)" called the normal production state an error.
#
# WHAT SURVIVES is Solana::Config itself failing to resolve — a Zeitwerk load
# failure raises NameError, which a bare `rescue` modifier catches. That is the
# state the messages now name.
#
# WHY THE TESTS REMOVE A CONSTANT. `remove_const` makes `Solana::Config::NETWORK`
# raise NameError on read, which is not an approximation of the surviving
# trigger — it is the same exception class from the same cause (an unresolvable
# constant under Solana::Config). Same technique, and the same fork-isolation
# argument, as ContractUpgradeAuthorityTest's `with_network`.
class ContractAdminStateFallbacksTest < ActionDispatch::IntegrationTest
  PARTIAL = "app/views/contract/_section_admin_state.html.erb".freeze

  # Extract a cell BY POSITION off its <dt>. A card that failed to render (the
  # admin gate, a 500) returns nil here rather than silently satisfying an
  # assertion about what the page does not say.
  def cell_for(body, label)
    body[%r{#{Regexp.escape(label)}</dt>\s*<dd[^>]*>\s*(.*?)\s*</dd>}m, 1]&.strip
  end

  def without_const(name)
    previous = Solana::Config.const_get(name)
    Solana::Config.send(:remove_const, name)
    yield
  ensure
    Solana::Config.const_set(name, previous)
  end

  setup { log_in_as(users(:alex)) }

  # --- 1. PROGRAM_ID: absence stops boot, so it never shows up here ---

  test "the Program ID fallback names the load failure, not a missing var" do
    without_const(:PROGRAM_ID) do
      get contract_path
      assert_response :success

      value = cell_for(response.body, "Program ID")
      assert value.present?,
        "the admin card rendered no Program ID cell - the assertions below would pass vacuously"
      assert_match(/Solana::Config did not load/, value,
        "the Program ID fallback must name the only state that produces it: Solana::Config failing to resolve")
      assert_match(/stops boot/, value,
        "the fallback must tell the reader an unset SOLANA_PROGRAM_ID stops boot rather than rendering here")
      assert_no_match(/SOLANA_PROGRAM_ID not set/, value,
        "an unset SOLANA_PROGRAM_ID raises during eager load, so it cannot be the cause of a rendered fallback")
    end
  end

  # --- 2. squads_vault_pda: absence is the CORRECT production state ---
  #
  # But it is the correct state, not a permanent one. config.rb keeps the env
  # override as "the runbook escape hatch", so the message must offer the unset
  # case as a CONDITION it is describing rather than assert it as a live fact.
  # An unconditional "is correctly unset" turns the first legitimate use of that
  # hatch into a false sentence printed by the app.

  test "the Upgrade authority fallback does not call the correct production state an error" do
    raiser = ->(*) { raise NameError, "uninitialized constant Solana::Config" }

    Solana::Config.stub(:squads_vault_pda, raiser) do
      get contract_path
      assert_response :success

      value = cell_for(response.body, "Upgrade authority")
      assert value.present?,
        "the admin card rendered no Upgrade authority cell - the assertions below would pass vacuously"
      assert_match(/Solana::Config did not load/, value,
        "squads_vault_pda cannot raise on its own, so the fallback must name the load failure")
      assert_match(/with SOLANA_SQUADS_VAULT_PDA unset/, value,
        "the message must frame the unset case as the CONDITION it describes. config.rb keeps the " \
        "env override as the runbook escape hatch, so a message that asserts the variable IS unset " \
        "prints a false sentence the first time an operator legitimately sets it.")
      assert_match(/cluster default is the live path/, value,
        "the operative fact must survive the rewording: the NETWORK-keyed default is what both " \
        "deployed apps actually read")
      assert_no_match(/SOLANA_SQUADS_VAULT_PDA not set/, value,
        "the key is absent on turf-monster-mainnet and turf-monster-qa alike; calling that 'not set' " \
        "points the reader at the wrong cause")
    end
  end

  # --- 3. NETWORK: the fallback is never SEEN, and the message says so ---
  #
  # Established here rather than inherited. The application layout reads
  # Solana::Config.devnet? on the body tag of every render, unrescued, and
  # devnet? reads NETWORK. So anything that makes NETWORK unreadable raises in
  # the LAYOUT and the page 500s.
  #
  # WHAT THIS TEST DOES NOT PROVE, and what its name used to claim. The layout
  # renders AFTER the template and its partials, not before: template_renderer
  # stores the layout as view_flow.set(:layout, yield(layout)) and the yield
  # runs the template first. The partial therefore RENDERS, its NETWORK rescue
  # FIRES, and the already-rendered body is discarded when the layout raises.
  # Measured on 2026-09-06 by instrumenting render_partial.action_view during a
  # failing request: the admin partial's event completes with exception nil,
  # eleven events before the layout's event carries the NameError. Rendering
  # the partial standalone with NETWORK removed returns 3,569 bytes with the
  # fallback string present.
  #
  # A trace with no partial frames is consistent with BOTH "never ran" and "ran
  # and was discarded", because a partial's frames are popped when it COMPLETES.
  # So this test is scoped to what the trace can actually distinguish: WHERE the
  # raise came from. The pair of assertions is that proof - the contract page
  # raises from the layout frame, AND a page that does not contain this partial
  # at all raises identically. The second is the control: without it, "the page
  # raised" would be equally consistent with the partial being what failed.

  test "the NETWORK failure raises in the layout frame, not inside the admin partial" do
    without_const(:NETWORK) do
      partial_page = assert_raises(ActionView::Template::Error) { get contract_path }
      assert_match(/NETWORK/, partial_page.message,
        "expected the NameError for the missing constant, not some unrelated view failure")

      # The failure is in the LAYOUT. Asserting the partial is ABSENT from the
      # trace is the half that matters: it rules out "the partial raised and its
      # own rescue failed to catch". It does NOT rule out the partial having
      # run - it ran, and its frames were popped on completion.
      trace = partial_page.backtrace.join("\n")
      assert_match(%r{layouts/application\.html\.erb}, trace,
        "expected the layout's body tag (data-solana-cluster) to be the raising frame")
      assert_no_match(/_section_admin_state/, trace,
        "the raise must come from the layout, not from inside the partial. Zero partial frames " \
        "does not mean the partial never ran - a completed partial leaves none either - so read " \
        "this as 'the partial did not raise', which is the claim the caption depends on.")

      # CONTROL: a page WITHOUT the admin card, rendered through the same
      # layout, must fail identically. root_path is a 302 that renders no
      # layout at all, so the redirect has to be FOLLOWED for this to mean
      # anything - an unfollowed 302 passes this test while proving nothing.
      no_partial_page = assert_raises(ActionView::Template::Error) do
        get root_path
        follow_redirect!
      end
      assert_match(/NETWORK/, no_partial_page.message,
        "a page WITHOUT the admin card must fail the same way - otherwise the failure is " \
        "partial-local and the fallback would be reachable after all")
    end
  end

  # WHERE THIS RESCUE LIVES, as of card-claims-program-invariance: HOISTED above
  # the <dl>, into a `cluster` local, and read by BOTH captions that name the
  # cluster — Program ID and Upgrade authority. It used to sit inline in the
  # Upgrade authority caption. The regex below takes the FIRST match in the
  # file, so one shared rescue is also what keeps this guard pointed at the only
  # NETWORK fallback there is; a second copy would have captured that one
  # instead and left this one unread while still passing.
  test "the cluster caption fallback says it is unreachable rather than inventing an error" do
    source = Rails.root.join(PARTIAL).read

    caption = source[/Solana::Config::NETWORK rescue "([^"]*)"/, 1]
    assert caption.present?,
      "could not find the NETWORK rescue in #{PARTIAL} - this guard would pass vacuously"
    assert_match(/unreachable/, caption,
      "the NETWORK fallback is never seen by a reader. Acceptance is that a string nobody can " \
      "reach says so, rather than being dressed in a friendlier error string.")
    assert_match(/discarded/, caption,
      "unreachable must be stated with the RIGHT mechanism. The fallback does fire - the partial " \
      "renders before the layout does - and the rendered body is then discarded. A caption that " \
      "says the partial never renders is the defect this line exists to catch.")
    assert_no_match(/before this line renders/, caption,
      "the layout renders AFTER the template and its partials, so nothing raises before this " \
      "line renders; verified against actionview template_renderer and by standalone render")
    assert_no_match(/not set/i, caption,
      "an unset SOLANA_NETWORK raises in production by design (OPSEC-012), and since PR 559 " \
      "empty and whitespace-only do too - none of them can produce this text")
  end

  # --- the standing guard: this card's fallbacks may never blame an env var ---
  #
  # The class of defect, kept armed for fallbacks that do not exist yet. All
  # THREE of this card's current rescues read Solana::Config -- the NETWORK one
  # hoisted above the <dl> since card-claims-program-invariance, and shared by
  # the two captions that name the cluster -- and no unset variable can produce
  # a rendered fallback for any of them, so "not set" is never the true cause of
  # one today.
  #
  # That is a claim about the three rescues, NOT about the card. The card has
  # six cells, and four of them (Paused, Registered currencies, Operator
  # revenue, Treasury authority) are Phase 2 placeholders bound for the
  # vault-state preload rather than Solana::Config. A fallback added for one of
  # those would have a DIFFERENT true cause, and the loop below would wrongly
  # demand a Solana::Config-shaped message for it.
  #
  # The count assertion is what keeps that safe: a fourth fallback fails it
  # loudly and forces this rationale to be re-derived, instead of being quietly
  # swept into a message that names the wrong cause. Extend it deliberately.

  test "no fallback in the admin card blames a missing env var" do
    source = Rails.root.join(PARTIAL).read

    fallbacks = source.scan(/rescue\s+"([^"]*)"/).flatten
    assert_equal 3, fallbacks.length,
      "expected the 3 known rescue fallbacks in #{PARTIAL}; found #{fallbacks.length}. " \
      "If a fallback was added or removed, extend this guard rather than relaxing it - " \
      "a zero-match scan would pass without reading a line."

    fallbacks.each do |text|
      assert_no_match(/not set/i, text,
        "#{PARTIAL} fallback #{text.inspect} blames an unset variable. None of these three values " \
        "can render with its variable unset: PROGRAM_ID and NETWORK raise during eager load in " \
        "production, and squads_vault_pda never raises. Name the load failure instead.")
      assert_match(/Solana::Config did not load|unreachable/, text,
        "#{PARTIAL} fallback #{text.inspect} must name the state that actually produces it - " \
        "a Solana::Config load failure, or, for the NETWORK caption, that no reader can ever see it")
    end
  end
end
