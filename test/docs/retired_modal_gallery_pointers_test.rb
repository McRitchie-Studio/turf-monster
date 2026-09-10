# frozen_string_literal: true

require "test_helper"

# [component] The successor to modal_deprecation_list_agreement_test, which was
# deleted with /admin/modals on 2026-09-09.
#
# WHAT THE DELETED TEST DID, AND WHY IT IS OWED A REPLACEMENT. AUTH.md carries
# the last surviving copy of the uncarded-modal deprecation list — the five ids
# that held the gallery open longest. The controller's copy and the banner's
# copy died with their files; the prose did not. The old test pinned that list
# against the gallery's own registry, so a name that gained a card and was never
# struck from the prose went red. The gallery is gone, the list is discharged,
# and the prose now makes a NEW claim in the old one's place: that all five have
# cards in TURF's section of the living style guide. That claim is exactly as
# falsifiable as the old one, and until this file it was pinned by nothing.
#
# THE DRIFT THIS CATCHES is a card deleted from app/views/style/host/_modals.html.erb
# without AUTH.md being revisited. Nothing else notices: style_host_section_test
# pins the section against its OWN trigger table, so deleting a card and its
# table row together is green there and leaves AUTH.md quietly lying.
#
# WHY THE FIVE IDS ARE A CONSTANT HERE rather than parsed out of the prose. The
# list is now a HISTORICAL RECORD — it closed on 2026-09-09 and cannot gain a
# name. A constant states that directly, survives any rewording of the bullet,
# and cannot silently parse to a short list the way a regex over prose can. The
# doc-side half below asserts the bullet still NAMES all five, so a rewrite that
# drops one is caught without any sentence being load-bearing.
class RetiredModalGalleryPointersTest < ActionDispatch::IntegrationTest
  DOC = Rails.root.join("docs/AUTH.md")

  # The five ids that were still uncarded when the gallery was retired. Closed
  # set, historical; see the note above.
  LAST_UNCARDED = %w[
    wallet-setup
    wallet-changed
    cdp-ramp
    buy-entry-token
    cosign-rejected
  ].freeze

  # Fact-bearing anchor (a state plus its date) rather than a turn of phrase, so
  # the bullet can be rewritten around it. If it ever goes, the floor below
  # fails LOUD with the remedy rather than passing on an empty slice.
  BULLET_ANCHOR = "RETIRED on 2026-09-09"

  # A CAPABILITY-GATED CARD IS STILL A CARD, and this file learned that the hard
  # way: its first run reported cdp-ramp missing from a section that cards it
  # perfectly well. style/_modal_specimen takes `openable:` and `disabled:` as
  # separate locals, so an id whose registration is gated renders a greyed card
  # carrying the reason INSTEAD OF a trigger. Demanding a live trigger from all
  # five would fail on every stack with the flag off, which is every stack but
  # QA and production. The model (and the badge string) is
  # test/integration/style_host_section_test.rb's CAPABILITY_GATED — that file
  # owns the gating behaviour; this one only needs to not mistake it for absence.
  GATED_BADGES = { "cdp-ramp" => "requires ENABLE_CDP_RAMP" }.freeze

  setup do
    log_in_as(users(:alex))
    get admin_style_path
    follow_redirect! while response.redirect?
    assert_response :success
    @body = response.body
  end

  # --- the doc's half ---------------------------------------------------------

  # ASSERTS THE SET, NOT MEMBERSHIP, and that distinction was measured. The first
  # cut of this test asserted each id appeared somewhere in the bullet, and a
  # mutation that DELETED cosign-rejected from the list still went green: the
  # bullet's own tail explains separately how cosign-rejected left, so the name
  # was still in the slice. Comparing the parsed list to the constant makes a
  # dropped name, an added name and a typo all red, and it does not care what
  # else the bullet says.
  test "the AUTH.md list still names exactly the ids it is the last record of" do
    assert_equal LAST_UNCARDED.sort, documented_ids.sort,
                 "docs/AUTH.md's retired-gallery list no longer reads as the five ids this file " \
                 "pins. That bullet is the last surviving copy of the list — the controller's " \
                 "and the banner's died with their files — so a name dropped there is gone from " \
                 "the repo. Restore it, or change LAST_UNCARDED and say why in the same commit."
  end

  # --- reality's half ---------------------------------------------------------

  test "every id the bullet lists has a card in turf's style-guide section" do
    section = host_section

    LAST_UNCARDED.each do |id|
      trigger = "$store.modals.open('#{id}'"
      badge   = GATED_BADGES[id]

      carded = section.include?(trigger) || (badge.present? && section.include?(badge))

      assert carded,
             "docs/AUTH.md says all five of the last uncarded modals have cards in turf's own " \
             "section of the style guide, and `#{id}` has neither a trigger there nor " \
             "#{badge ? "its #{badge.inspect} badge" : "a gated-card badge"}. Either the card was " \
             "removed from app/views/style/host/_modals.html.erb — in which case that id has no " \
             "review surface again and AUTH.md has to say so — or the section stopped rendering it."
    end
  end

  # --- the controls -----------------------------------------------------------
  #
  # Both halves above are assert_includes over a slice, and a slice that came
  # back as the WHOLE PAGE would satisfy them for free. These prove it did not.

  test "the section slice is bounded, and the card predicate can say no" do
    section = host_section

    # (a) Bounded. The engine renders its own Templates cards on this same page,
    # OUTSIDE turf's section. A slice that swallowed them would pass anything.
    assert_includes @body, "template-form",
                    "precondition: the engine's Templates specimens should be on /admin/style; " \
                    "without them this control proves nothing about the slice's upper bound"
    refute_includes section, "template-form",
                     "the host-section slice reached past its own section into the engine's " \
                     "Templates cards — every assertion in this file is scoped by that slice, " \
                     "so an unbounded one makes all of them vacuous"

    # (b) Discriminating. `onboarding` is a LIVE registered id — the chain's
    # first-name step, mounted in layouts/application — with no card in turf's
    # section, so the predicate above is asked about a real modal and answers no.
    #
    # THIS CONTROL HAS ALREADY DONE ITS JOB ONCE. It pointed at wallet-topup
    # until 2026-09-09, when 226cd008 carded wallet-topup here (openable: true)
    # and turned this line red — which is the failure it exists to produce, and
    # is why the message below tells the next reader to re-point rather than to
    # delete. Pick another registered-but-uncarded id when that happens again.
    refute_includes section, "$store.modals.open('onboarding'",
                     "onboarding gained a card in turf's section — good news, but this control " \
                     "relied on its absence to prove the predicate above can return false. " \
                     "Re-point it at another id that layouts/application registers and this " \
                     "section does not card."
  end

  # --- what makes the prose's tense correct -----------------------------------

  test "the constants the swept prose calls retired really are gone" do
    %i[MODAL_VARIANTS MODAL_FLOWS].each do |name|
      refute AdminController.const_defined?(name, false),
             "AdminController::#{name} is defined again. Several comments and both of " \
             "docs/AUTH.md and docs/UI_PATTERNS.md now describe it in the PAST TENSE as " \
             "retired with /admin/modals on 2026-09-09. Reintroducing it under the old name " \
             "makes that prose wrong everywhere at once — rename it, or sweep the prose back."
    end
  end

  private

  # The ids AUTH.md lists as the last five uncarded modals.
  #
  # SCOPED TO THE CLAIM, not to the bullet. The parenthetical is taken as the one
  # ending immediately before the sentence making the assertion this file exists
  # to pin, so the ids and the claim about them cannot drift apart. A bullet-wide
  # scan is what let the deletion mutation through (see the test above), and a
  # whole-file scan would be looser still — every one of these ids appears
  # elsewhere in AUTH.md.
  #
  # BOTH ANCHORS FAIL LOUD. Reword either and this raises with the remedy rather
  # than parsing to a short list and quietly asserting less.
  CLAIM_ANCHOR = "all have cards on the guide now"

  def documented_ids
    text = DOC.read

    assert_includes text, BULLET_ANCHOR,
                    "docs/AUTH.md no longer contains #{BULLET_ANCHOR.inspect} — the retirement " \
                    "this whole file describes is not stated in the doc any more. If the page " \
                    "came back, this file is the wrong guard; if it was reworded, re-point " \
                    "BULLET_ANCHOR."

    parenthetical = text[/\(([^()]*)\)\s*#{Regexp.escape(CLAIM_ANCHOR)}/m, 1]
    assert parenthetical.present?,
           "could not find a parenthesised id list ending just before #{CLAIM_ANCHOR.inspect} " \
           "in docs/AUTH.md. That sentence is where the doc claims the five have cards, and " \
           "this file reads the ids out of it — re-point CLAIM_ANCHOR at the rewritten sentence."

    ids = parenthetical.scan(/`([a-z0-9-]+)`/).flatten
    assert ids.any?,
           "the id list parsed to nothing — the backticks around the ids are how they are " \
           "recognised, and zero ids is a broken parse, not an empty list"
    ids
  end

  # Turf's section of the rendered style guide, HTML-decoded.
  #
  # DECODED for the reason style/_modal_specimen forces on its sibling in
  # test/integration/style_host_section_test.rb: an open_expr that stops being
  # marked html_safe renders as open(&#39;wallet-setup&#39;, ...) — still a live
  # trigger, still the card being reviewed — and a raw-string search would stop
  # matching it. That failure is silent in the dangerous direction here: every
  # assertion above would start reporting a card MISSING that is on the page.
  def host_section
    idx = @body.index('id="host-modals"')
    assert idx, "no id=\"host-modals\" on /admin/style — turf's section did not render at all, " \
                "so this file has nothing to audit. That is a seam failure, not a doc failure; " \
                "test/integration/style_host_section_test.rb owns it."

    nxt = @body.index("<section id=", idx)
    CGI.unescapeHTML(@body[idx...(nxt || @body.length)])
  end
end
