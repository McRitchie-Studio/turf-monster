require "test_helper"

# Regression — chore: adopt studio-engine 0.20 modal blocks (adopt-engine-twenty-defork).
#
# TM stopped forking the generic modal blocks and now renders studio-engine's
# studio/modals/... partials: card_header, cta_redirect, progress_pill, shell,
# the five modal templates, the shared email_field (with the live validator),
# the free_entry_earned celebration block, and the wallet-brand sprite in the
# Connect-Wallet picker.
#
# 2026-08-25 (adopt-engine-solana-blocks): two thirds of the Solana success
# cluster followed. onchain_success and solana_tx_link were byte-identical to
# the engine blocks in RENDERED markup, so TM's copies are deleted. Still forked:
# entry_confirmed (kickoff countdown + $store.solanaModal drive) and the modal
# host (inline cosign-rejected).
#
# These assert the swap at the render boundary — the ENGINE partials render,
# the removed forks are gone, and the kept Solana forks still resolve their
# now-adopted card_header dependency (the "kept fork renders an adopted block"
# seam that would crash the success card AFTER a live on-chain entry).
class EngineModalDeforkTest < ActionDispatch::IntegrationTest
  # --- Logged-out signin (auth modal + auth card + wallet-connect picker) -------

  test "auth email field renders studio-engine's email_field with the live validator" do
    get signin_path
    assert_response :success

    # validator: true wraps the field in emailValidator() and paints the
    # right-edge indicator with the engine's canonical `.spinner` primitive.
    assert_includes response.body, 'x-data="emailValidator()"'
    assert_includes response.body,
      %q(<span x-show="status === 'loading'" x-cloak class="spinner text-secondary")
    # The deleted fork painted the indicator with `.cta-spinner` — must be gone
    # from the email field (bare .cta-spinner still lives on other buttons).
    assert_not_includes response.body,
      %q(<span x-show="status === 'loading'" x-cloak class="cta-spinner text-secondary")
  end

  test "connect-wallet picker renders the engine wallet-brand sprite, not app PNGs" do
    get signin_path
    assert_response :success

    assert_includes response.body, 'id="se-wallet-phantom"'
    assert_includes response.body, 'id="se-wallet-solflare"'
    assert_includes response.body, 'id="se-wallet-backpack"'
    assert_includes response.body, "'#se-wallet-' + brandIcon("

    # The former app-served install icons are dropped.
    assert_not_includes response.body, "/wallet-phantom.png"
    assert_not_includes response.body, "/wallet-solflare.png"
    assert_not_includes response.body, "/wallet-backpack.png"
  end

  # --- Logged-in modal host (free-entry celebration + template gallery) ---------

  test "free-entry-earned renders the studio-engine block with turf's reward copy" do
    log_in_as(users(:alex))
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    # Engine block's confetti fallback chain (fork fired only fireFreeEntryConfetti).
    assert_includes response.body, "window.fireFreeEntryConfetti || window.fireSuccessConfetti"
    # Turf's reward copy, threaded in as the block's `subtitle` local.
    assert_includes response.body, "Free Entry Token"
    assert_includes response.body, "will arrive in 48 hours"
  end

  test "modal templates render from studio-engine (non-production gallery)" do
    log_in_as(users(:alex))
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success
    # The wizard template's rendered host slot is present (templates render
    # unless Rails.env.production?); its partial now resolves under studio/.
    assert_includes response.body, "$store.modals.current().id === 'template-wizard'"
  end

  # --- Kept Solana forks resolve their adopted card_header dependency -----------

  test "onchain-tx entry-confirmed (kept fork) resolves the adopted engine card_header" do
    log_in_as_onchain(users(:sam))
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    # entry_confirmed is a KEPT fork that now renders studio/modals/blocks/
    # card_header + cta_redirect. If the repoint were missed, this page would
    # raise ActionView::MissingTemplate (the card_header fork was deleted).
    assert_includes response.body, "Entry Confirmed"
    assert_includes response.body, "Good Luck"
    # The Solana tx link is now the ENGINE's block, rendered by the kept card.
    # The cluster query is what the deleted fork used to guarantee: the test env
    # is devnet, so a link WITHOUT it would point at mainnet and find nothing.
    assert_includes response.body, "explorer.solana.com"
    # Assert the CONCATENATION TAIL, not the bare query string. Several other
    # views hardcode "?cluster=devnet" in plain hrefs, so a bare substring match
    # goes green off one of those with this link on mainnet — proved by mutation
    # while control-checking this change. Only the engine block's Alpine :href
    # builds the URL by concatenation, so this shape is unique to it.
    assert_includes response.body, %q[) + '?cluster=devnet'"],
      "the adopted engine tx link must carry the devnet cluster the fork used to " \
      "compute inline — without it the explorer resolves against mainnet"
  end

  # --- Static guard: no deleted-fork render paths linger ------------------------

  test "no deleted fork partials are referenced by any app view or controller" do
    deleted = [
      %r{["']modals/blocks/card_header["']},
      %r{["']modals/blocks/cta_redirect["']},
      %r{["']modals/blocks/progress_pill["']},
      %r{["']modals/blocks/shell["']},
      %r{["']modals/templates/(?:action|form|status|success|wizard)["']},
      %r{["']modals/free_entry_earned["']},
      %r{["']shared/email_field["']},
      # Deleted 2026-08-25. The leading quote is what keeps these from matching
      # the ENGINE paths, which read "studio/modals/blocks/..." — a slash, not a
      # quote, sits before "modals" there.
      %r{["']modals/blocks/solana_tx_link["']},
      %r{["']modals/blocks/onchain_success["']}
    ]
    roots = [Rails.root.join("app/views/**/*.erb"), Rails.root.join("app/controllers/**/*.rb")]
    offenders = []
    roots.each do |glob|
      Dir[glob].each do |path|
        body = File.read(path)
        deleted.each do |re|
          offenders << "#{path.sub(Rails.root.to_s + '/', '')}: /#{re.source}/" if body.match?(re)
        end
      end
    end
    assert_empty offenders,
      "Deleted-fork render paths still referenced (re-forked?):\n  " + offenders.join("\n  ")
  end

  # --- the safety the deleted fork used to provide structurally ----------------

  ENGINE_CLUSTER_BLOCKS = %w[
    studio/modals/blocks/solana_tx_link
    studio/modals/blocks/onchain_success
  ].freeze

  test "every engine solana-block callsite passes the explorer cluster param" do
    # THIS GUARD IS THE TRADE. The deleted fork computed the cluster inline from
    # Solana::Config.devnet?, so no callsite COULD forget it. The engine block
    # takes cluster_param as a local DEFAULTING TO "" — mainnet — so a callsite
    # that omits it renders a link that resolves, looks correct, and finds
    # nothing, which reads to a user as "my transaction is missing". The fork's
    # guarantee was structural and untested; this one is asserted. Without it the
    # adoption is a net loss of safety.
    callsites = 0
    offenders = []

    Dir[Rails.root.join("app/views/**/*.erb")].each do |path|
      body = File.read(path)

      ENGINE_CLUSTER_BLOCKS.each do |partial|
        quoted = %r{["']#{Regexp.escape(partial)}["']}
        mentions = body.scan(quoted).size
        next if mentions.zero?

        # Count mentions BEFORE matching render calls, and require the two to
        # agree. A callsite written in a shape this regex cannot parse would
        # otherwise be skipped silently — the guard would pass while the
        # callsite it exists to check goes unread.
        calls = body.scan(%r{render[^%]*?#{quoted.source}(.*?)%>}m)
        assert_equal mentions, calls.size,
          "#{path}: #{mentions} quoted mention(s) of #{partial} but #{calls.size} " \
          "parsable render call(s) — one is in a shape this guard cannot see"

        calls.each do |(args)|
          callsites += 1
          next if args.include?("cluster_param:")

          offenders << "#{path.sub(Rails.root.to_s + '/', '')} -> #{partial}"
        end
      end
    end

    # A zero here means the scan matched nothing at all, and every assertion
    # below it would pass no matter what the app did.
    assert_operator callsites, :>=, 2,
      "expected at least the entry-confirmed and onchain-tx callsites, found #{callsites}"

    assert_empty offenders,
      "these callsites omit cluster_param and so link to MAINNET on a devnet " \
      "deploy:\n  " + offenders.join("\n  ")
  end
end
