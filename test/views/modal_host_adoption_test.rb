# frozen_string_literal: true

require "test_helper"

# [component] Adoption of studio-engine's modal host, after this app stopped
# shadowing it with a 518-line fork of its own.
#
# WHAT WAS DELETED, and why it survived so long. studio-engine is a NON-ISOLATED
# Rails engine, so an app view at the same virtual path SHADOWS the engine's.
# This app had one at app/views/studio/modals/_host.html.erb. Both files rendered
# the same class names and the same store, so nothing on a page or in a markup
# assertion could tell the two apart — the duplication was invisible by
# construction, and the fork drifted behind the engine's focus and stale-entry
# guards for months while looking identical.
#
# THE FORK WAS THE RICH ONE, which is why this is a behaviour-preservation job
# and not a deletion. It carried two things the engine host did not: a per-modal
# card WIDTH map, and an app-wide registration for the cosign-rejected card.
# studio-engine 0.65.0 opened a seam for each, and this test pins that BOTH
# survived the move:
#
#   window.StudioModals.CARD_WIDTHS   app/views/shared/_modal_card_widths
#   modals/_host_extras               app/views/modals/_host_extras
#
# ASSERT BY RESOLUTION, NOT BY PATH. See ResolvedModalHost (test/support) for why
# a File.read of a fixed path cannot answer "which host renders", and for why the
# resolved identifier must never be asserted to contain "/gems/".
class ModalHostAdoptionTest < ActionDispatch::IntegrationTest
  WIDTH_REGISTRY = Rails.root.join("app/views/shared/_modal_card_widths.html.erb")
  HOST_EXTRAS    = Rails.root.join("app/views/modals/_host_extras.html.erb")

  # Every layout in this app, so the drift guards below are derived rather than
  # listed. A third layout that mounts the host is exactly the case a hardcoded
  # pair of filenames would miss.
  LAYOUTS = Dir[Rails.root.join("app/views/layouts/*.html.erb").to_s].freeze

  # ── The shadow is gone ────────────────────────────────────────────────

  test "the modal host renders from outside this app" do
    identifier = ResolvedModalHost.identifier

    assert_not ResolvedModalHost.shadowed_by_app?,
               "studio/modals/host resolved to #{identifier}, inside this app's " \
               "app/views — the fork is back and it shadows the engine's host again"
  end

  test "the fork is gone from disk" do
    # A render assertion cannot answer this: the fork and the engine host produce
    # the same markup, which is precisely what let the duplication survive.
    assert_not File.exist?(ResolvedModalHost::SHADOW_PATH),
               "#{ResolvedModalHost::SHADOW_PATH} is back — the engine owns the host now"
  end

  # ── Seam 1: per-modal card widths ─────────────────────────────────────

  test "the resolved host reads a width registry rather than a static class" do
    source = ResolvedModalHost.source

    assert_includes source, "modalCardWidth(c.id)",
                    "cardClasses() must resolve the width per modal id; without this " \
                    "call the registry is printed on the page and read by nobody"

    # Exactly ONE max-w-* ever lands on the card. A static class alongside a bound
    # one leaves the winner to stylesheet source order, which is not something a
    # view gets to decide. Carried over from the fork's own guarantee.
    card = source[/<div class="bg-surface rounded-xl[^"]*"/]
    assert card.present?, "could not locate the modal card element — did it move?"
    assert_not_includes card, "max-w-",
                        "the width belongs to cardClasses(), not to a static class"
  end

  test "wallet-setup keeps a NON-DEFAULT width on every path that mounts the host" do
    # OPERATOR CALL, 2026-08-18: this card a step bigger, to give the explainer
    # video room — at max-w-sm the player is small enough that the thing it is
    # teaching cannot be read.
    #
    # ASSERTED AGAINST THE DEFAULT, not against a literal. A registry that
    # silently resolves to the engine default is the failure mode this seam has,
    # and "max-w-md is present" would pass just as happily if the default were
    # also max-w-md. Read both and compare.
    #
    # READ AS CODE, via RenderedCardWidths. The plain-substring version of this
    # test SURVIVED deleting the registration: the engine host documents the seam
    # with a worked `// window.StudioModals.CARD_WIDTHS = { 'wallet-setup':
    # 'max-w-md' };` example inside its own inline script, and a JS comment in an
    # inline script is rendered HTML like any other text. See that module.
    default = ResolvedModalHost.source[/DEFAULT_CARD_WIDTH\s*=\s*'([\w-]+)'/, 1]
    assert default.present?, "the engine host no longer names a default card width"

    each_host_render do |label, body|
      # THE GUARD ON THE GUARD. If the statement scan matches nothing, every
      # assertion below reads nil and this test fails for the wrong reason —
      # or, worse, a laxer version of it passes for the wrong reason. Both the
      # app's registration and the engine's merge are real statements, so a page
      # mounting the host carries at least two.
      assert_operator RenderedCardWidths.statements(body).length, :>=, 2,
                      "#{label}: found no CARD_WIDTHS assignments to read — the scan is " \
                      "matching nothing, so nothing below proves anything"

      registered = RenderedCardWidths.width_for(body, "wallet-setup")

      assert registered.present?,
             "#{label} mounts the modal host but registers no width for wallet-setup — " \
             "the card silently falls back to #{default} there"
      assert_not_equal default, registered,
                       "#{label} registers wallet-setup at the DEFAULT width (#{default}), " \
                       "so the registry is doing nothing"
    end
  end

  test "every layout that mounts the host registers the widths above it" do
    # The registration has to be on window BEFORE the host's own inline script
    # merges it, so it cannot ride along inside the host. That makes "a layout
    # mounted the host and forgot this" a real and silent failure: every card
    # falls back to the default and it reads as a styling regression.
    # MATCH THE WHOLE ERB TAG, opening delimiter included. The app layout
    # documents the host in a JS comment as an ESCAPED literal (`<%%= render
    # "studio/modals/host" %>`, 400 lines above the real one), and a bare
    # `render "..."` needle finds that comment first — which reported the real
    # render site as sitting above the widths and failed this test for a
    # sentence in a comment.
    host_tag  = %(<%= render "studio/modals/host")
    width_tag = %(<%= render "shared/modal_card_widths")

    offenders = LAYOUTS.filter_map do |path|
      markup = File.read(path)
      host_at = markup.index(host_tag)
      next if host_at.nil?

      width_at = markup.index(width_tag)
      next if width_at && width_at < host_at

      relative = Pathname(path).relative_path_from(Rails.root)
      "#{relative} (#{width_at.nil? ? 'missing' : 'rendered below the host'})"
    end

    assert_empty offenders,
                 "these layouts mount the modal host without registering the card " \
                 "widths above it, so every modal falls back to the default width:\n  " \
                 "#{offenders.join("\n  ")}"
  end

  # ── Seam 2: app-wide registrations (modals/_host_extras) ──────────────

  test "cosign-rejected registers on every path that mounts the host" do
    each_host_render do |label, body|
      assert_includes body, "$store.modals.current().id === 'cosign-rejected'",
                      "#{label} lost the cosign-rejected registration — the entry board " \
                      "opens that id, and an unregistered id renders an EMPTY card"
      assert_includes body, "Transaction not signed",
                      "#{label} registered the id but rendered no card body"
    end
  end

  test "cosign-rejected is registered through the seam, not per callsite" do
    # THE POINT OF THE SEAM. The block each layout passes to the host is
    # per-callsite, so a card registered there must be repeated in every layout
    # and a card added to only one renders EMPTY in the other — which has
    # happened here before (see the age-verify note in layouts/modal_preview).
    # If a layout starts carrying its own copy, this seam has quietly stopped
    # being the single source.
    # COMMENTS STRIPPED FIRST. Both layouts DISCUSS cosign-rejected in an ERB
    # comment above the host render ("cosign-rejected lives there"), and a raw
    # File.read that happened to see it quoted would fail this test for a
    # sentence. Match the ERB comment form exactly as ERB does — <%# through the
    # FIRST %> — then look for the registration statement rather than a bare
    # quoted id, so what is asserted is a real x-if keyed on the modal.
    duplicated = LAYOUTS.select do |path|
      File.read(path).gsub(/<%#.*?%>/m, "")
          .include?("$store.modals.current().id === 'cosign-rejected'")
    end

    assert_empty duplicated.map { |p| Pathname(p).relative_path_from(Rails.root).to_s },
                 "cosign-rejected is registered in a layout block as well as in " \
                 "modals/_host_extras — two registrations, free to drift"
    assert File.exist?(HOST_EXTRAS),
           "#{HOST_EXTRAS} is the only registration left; deleting it silently " \
           "removes the card from both render paths"
  end

  # ── The block slot still carries the layout's own registrations ───────

  test "the host's block slot renders the layout's own cards" do
    assert_includes about_page, "$store.modals.current().id === 'email-change-pending'",
                    "the layout's block registrations stopped reaching the card"
  end

  # SPLIT FROM THE ASSERTION ABOVE, and the split is the point. These two shared a
  # test until mutation showed the leak assertion could never be the one to fire:
  # the only locally reachable way to cause the leak is to mount the host WITHOUT a
  # block, and that trips the registration assertion first — so the leak assertion
  # sat behind a guard that failed before it, and a laxer version of it would have
  # been credited for coverage it never had. One assertion per failure mode, so
  # each is independently reachable.
  #
  # THE TRAP ITSELF. The host takes its slot as a BLOCK, and block_given? is ALWAYS
  # true inside a compiled Rails partial — it inherits the LAYOUT's yield — so the
  # engine's `yield if block_given?` guard carries no information and falls through
  # to view_flow[:layout], printing the whole page body inside the modal card. It
  # only fires during the LAYOUT pass, which is exactly how a modal host is mounted,
  # so a partial-render test cannot see it. This runs against a real page for that
  # reason.
  test "the host's block slot does not leak the page into the card" do
    assert_equal 1, about_page.scan("About Turf Totals").size,
                 "the page's own content appears twice — the host's yield fell " \
                 "through to view_flow[:layout] and printed the page inside the card"
  end

  private

  # The two paths that mount the host, rendered for real. Yielded as
  # (label, body) so a failure names which one broke.
  def each_host_render
    yield "layouts/application (/about)", about_page
    yield "layouts/modal_preview (/admin/modals/preview)", modal_preview_page
  end

  def about_page
    @about_page ||= begin
      get about_path
      assert_response :success
      response.body
    end
  end

  def modal_preview_page
    @modal_preview_page ||= begin
      log_in_as users(:alex)
      get admin_modal_preview_path(modal_id: "wallet-setup")
      assert_response :success
      response.body
    end
  end
end
