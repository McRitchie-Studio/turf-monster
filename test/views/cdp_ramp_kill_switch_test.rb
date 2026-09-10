require "test_helper"

# [component] The ENABLE_CDP_RAMP kill-switch must leave no dead buttons.
#
# The cdp-ramp modal is registered by the host layout behind
# cdp_ramp_modal_available? (logged_in? AND AppFlags.cdp_ramp?). Any surface
# that OPENS 'cdp-ramp' must ask a question no wider than that one, or the click
# swaps to a modal id the host never registered: the modal host finds no
# template, the card renders empty, and nothing raises anywhere. That is the
# "Buy an Entry Token opened empty" report of 2026-09-06.
#
# THREE view surfaces open it: modals/_wallet_topup (the primary CTA at the entry
# blocker), modals/_onramp_hub (the Add Funds rail picker one hop behind it), and
# modals/auth/_usdc_funding (the auth wizard's funding step). All three are
# reachable from a layout that was rendered logged-out — wallet-topup, onramp-hub
# and auth are all registered UNGATED, because they must survive an in-session
# signup, while cdp-ramp is registered under logged_in?. So both halves of the
# predicate are load-bearing, and both are exercised below.
#
# THE FLAG-OFF PATH IS THE POINT. A test that only renders with the flag ON
# certifies nothing about the kill-switch — that is precisely how this survived.
#
# app/views/cdp/returns/show.html.erb, also named in the report, needs no view
# guard: it is rendered only by Cdp::ReturnsController, whose
# Cdp::BaseController prepends `head :not_found unless AppFlags.cdp_ramp?`, so
# the page cannot render with the flag off. That gate already has its regression
# at test/controllers/cdp/returns_controller_test.rb ("404s when the flag is
# off"), and a view-level guard there would be unreachable code.
class CdpRampKillSwitchTest < ActionView::TestCase
  helper OnrampHelper

  # Every surface under test opens 'cdp-ramp' through this exact string. Read it
  # off the source rather than restating it: a test that declares its own copy
  # of the id keeps passing after the source stops emitting it.
  RAMP_ID = "cdp-ramp".freeze

  # ActionView::TestCase#rendered ACCUMULATES across calls in a file, so a refute
  # read off it passes vacuously against the union of every earlier render. Use
  # the return value, always.
  def render_topup = render(partial: "modals/wallet_topup")
  def render_hub   = render(partial: "modals/onramp_hub")

  SURFACES = {
    "wallet-topup" => :render_topup,
    "onramp-hub"   => :render_hub
  }.freeze

  # logged_in? reaches the views as a controller helper_method (studio-engine's
  # Studio::ErrorHandling), which an ActionView::TestCase does not install. Bind
  # it per-example so both halves of cdp_ramp_modal_available? are steerable.
  def with_context(flag:, logged_in:)
    was = ENV["ENABLE_CDP_RAMP"]
    flag ? ENV["ENABLE_CDP_RAMP"] = "true" : ENV.delete("ENABLE_CDP_RAMP")
    view.singleton_class.define_method(:logged_in?) { logged_in }
    yield
  ensure
    was.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = was
    view.singleton_class.remove_method(:logged_in?)
  end

  # --- the kill-switch: flag OFF ----------------------------------------------

  SURFACES.each do |name, renderer|
    test "#{name} reaches no cdp-ramp modal when the flag is off" do
      html = with_context(flag: false, logged_in: true) { send(renderer) }

      # The rendered markup is the whole proof: the id appears nowhere a click
      # could carry it, so no path reaches the unregistered modal.
      refute_includes html, RAMP_ID,
                      "#{name} still hands a click to cdp-ramp with ENABLE_CDP_RAMP off, " \
                      "and the host registers no such modal — the click opens an empty card"
      refute_includes html, "Coinbase",
                      "#{name} still names the uncleared onramp with the kill-switch thrown"
    end
  end

  # --- the second half: registered ungated, opened on a logged-out layout ------

  SURFACES.each do |name, renderer|
    test "#{name} reaches no cdp-ramp modal when the layout rendered logged out" do
      # Flag ON — this is production TODAY. #{name} is registered ungated so it
      # survives an in-session signup; cdp-ramp is registered under logged_in?
      # and therefore was not emitted on this page at all.
      html = with_context(flag: true, logged_in: false) { send(renderer) }

      refute_includes html, RAMP_ID,
                      "#{name} renders on a layout that emitted no cdp-ramp template, " \
                      "so this rail opens a modal id that does not exist on the page"
    end
  end

  # --- the control: the rail must still ship when the modal IS registered ------
  #
  # Without this the refutes above are satisfied by a surface that lost its
  # Coinbase rail entirely, or by a render that quietly returned nothing.

  SURFACES.each do |name, renderer|
    test "#{name} still offers the Coinbase rail when the modal is registered" do
      html = with_context(flag: true, logged_in: true) { send(renderer) }

      assert_includes html, RAMP_ID,
                      "with the modal registered the rail must still be reachable, " \
                      "or the flag-off assertions above prove only that it is gone"
      assert_includes html, "Coinbase"
    end
  end

  # --- the auth modal's funding step -------------------------------------------
  #
  # modals/auth/_usdc_funding is the third opener, and the session half of the
  # predicate matters MOST here: the auth modal is registered UNGATED (it is the
  # signup surface), and this step is reached right after an in-session signup —
  # on a page whose layout rendered logged-out and emitted no cdp-ramp template.
  # It is kept out of SURFACES above because it is a <template> fragment with its
  # own copy fallback rather than a single-root modal card.

  test "the auth funding step reaches no cdp-ramp modal when the flag is off" do
    html = with_context(flag: false, logged_in: true) { render partial: "modals/auth/usdc_funding" }

    refute_includes html, RAMP_ID, "the funding step still hands a click to an unregistered modal"
    assert_includes html, "Purchases temporarily offline",
                    "the flag-off branch must still say something, not render blank"
  end

  test "the auth funding step reaches no cdp-ramp modal on a logged-out layout" do
    # Flag ON — production today — but the page registered no cdp-ramp template.
    html = with_context(flag: true, logged_in: false) { render partial: "modals/auth/usdc_funding" }

    refute_includes html, RAMP_ID,
                    "the auth modal is registered ungated, so its Buy CTA outlived the modal"
  end

  test "the auth funding step still offers the buy when the modal is registered" do
    html = with_context(flag: true, logged_in: true) { render partial: "modals/auth/usdc_funding" }

    assert_includes html, RAMP_ID,
                    "with the modal registered the CTA must still be reachable"
    assert_includes html, "Buy USDC with Coinbase"
  end

  # --- the host contract, which the guards must not break ---------------------
  #
  # Both partials mount inside a <template x-if>, which keeps exactly ONE child.
  # Wrapping a rail in a server-side conditional is an easy way to leave a second
  # root or an empty one behind, and a dropped sibling raises nothing.

  SURFACES.each do |name, renderer|
    test "#{name} renders a single root element with the flag off" do
      html  = with_context(flag: false, logged_in: true) { send(renderer) }
      roots = Nokogiri::HTML5.fragment(html).element_children

      assert_equal 1, roots.length,
                   "a second root element would be dropped silently by the host's template x-if"
    end
  end
end
