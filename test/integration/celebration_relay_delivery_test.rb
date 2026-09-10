require "test_helper"

# [integration] The relay on the two DELIVERED documents the redirect leg needs.
#
# WHAT THIS TIER OWNS, and no tier below it can. The unit tests drive the codec
# and the handlers; the component test runs what the partials emit. All three run
# in node against source, so all three stay green when the relay is delivered to
# the wrong document, or to the right one too late. And "the wrong document" is
# not hypothetical here — the flow this serves already lost a real user's
# approved entry to exactly that mistake, when the intent handlers were rendered
# by the contest board and the wallet returned to a page the board never touches.
#
# The redirect leg spans TWO documents and the relay has to be on BOTH:
#
#   1. studio-engine's CALLBACK page, where complete() runs. This is where the
#      payload is written down, and it is a view this app does not own. If the
#      relay is not there, nothing is stashed and the landing page has nothing to
#      drain — the exact silence reported from QA iPhone Safari on 2026-09-09.
#   2. The CONTEST page the callback navigates to, where the drain runs and the
#      painter must already be registered.
#
# ORDER MATTERS ON THE FIRST ONE. studio-engine's callback dispatches from a bare
# inline script during body parse, and complete() — which does the stashing — is
# called synchronously inside that dispatch. A relay emitted below it would be
# defined after the only moment it was needed.
class CelebrationRelayDeliveryTest < ActionDispatch::IntegrationTest
  # The route the board hands Phantom as redirect_link.
  CALLBACK = "/auth/phantom/callback".freeze

  # The store the landing page drains, and the registration that gives it
  # something to drain WITH. Anchored on the assignment and the call rather than
  # on a bare mention, because both partials discuss the relay in prose that is
  # delivered too — an index on the loose name finds a comment and passes
  # vacuously.
  STORE_AT       = "W.tmCelebrationRelay = {".freeze
  REGISTERED_AT  = "tmCelebrationRelay.define('contest_entry'".freeze

  test "the callback document can write a celebration down before it navigates away" do
    get CALLBACK
    assert_response :success,
                    "the route a wallet is told to return to must render for an anonymous visitor"
    body = response.body

    store_at = body.index(STORE_AT)
    assert store_at,
           "the callback document does not carry the celebration relay — complete() runs here, " \
           "so there is nowhere to write the payload and the landing page will paint nothing"

    engine_call_at = body.index("studio.walletOps.resume(params")
    assert engine_call_at,
           "studio-engine's callback no longer dispatches through walletOps.resume(params, …)"
    assert store_at < engine_call_at,
           "the relay is defined AFTER the engine already resumed the intent — complete() stashes " \
           "inside that call, so the store must exist before it, not after"
  end

  test "the callback document also carries the painter's own half" do
    # The stash and the paint are written in the SAME partial, and this document
    # is where the stash happens. Losing the intent here loses the entry itself
    # (its handlers live there too), which is why they travel together.
    get CALLBACK
    assert_response :success

    assert response.body.index(REGISTERED_AT),
           "the contest_entry painter is not registered on the callback document"
  end

  test "the contest page a redirect entry lands on carries both halves" do
    # THE LANDING. studio-engine's callback ends with a hard navigation to the
    # redirect the server named, and this is that page: it has to hold the relay
    # to drain the slot AND the painter to paint it. Either one missing is the
    # same silent screen.
    get contest_path(contests(:one))
    assert_response :success
    body = response.body

    relay_at   = body.index(STORE_AT)
    painter_at = body.index(REGISTERED_AT)

    assert relay_at, "the landing page cannot drain a celebration it does not carry the relay for"
    assert painter_at, "the landing page carries no painter for contest_entry"
    assert relay_at < painter_at,
           "the painter registers at parse time — a relay emitted after it registers nothing"
  end

  test "the seeds constant travels with the painter rather than a hardcoded fallback" do
    # StateFanout falls back to a literal 100 when nobody passes seedsPerLevel.
    # The board passes its own on the inline leg; the relay leg lands on a page
    # that may have no board, so the constant ships from the layout.
    get contest_path(contests(:one))
    assert_response :success

    assert_includes response.body, "window.tmSeedsPerLevel = #{User::SEEDS_PER_LEVEL};",
                    "the delivered document must carry the model's constant, not leave the " \
                    "fanout to its own literal"
  end
end
