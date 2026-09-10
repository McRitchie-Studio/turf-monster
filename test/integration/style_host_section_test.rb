# frozen_string_literal: true

require "test_helper"

# [component] Turf's own section of the living style guide.
#
# WHY THIS TIER EXISTS AT ALL. The section's whole value is that its triggers
# open the app's REAL modals rather than a mirror of them, and the way that goes
# wrong is silent: a trigger that names an id nothing registers opens an empty
# panel, and a trigger that passes a prop the card does not read simply shows the
# default state while looking correct. Neither fails loudly, so both are asserted
# here against the ids the LAYOUT registers and the props the PARTIALS read.
class StyleHostSectionTest < ActionDispatch::IntegrationTest
  # Every id this section triggers, and the prop keys it passes with each.
  # Keyed to the production partial, not to any specimen — the retired engine
  # mirrors passed `currentAddress` to wallet-changed (which reads oldAddress)
  # and offered wallet-setup a `detected` prop that exists only on the mirror.
  TRIGGERS = {
    "wallet-setup"     => %w[returnUrl],
    "wallet-changed"   => %w[oldAddress newAddress providerLabel],
    "buy-entry-token"  => [],
    # BOTH keys, and flow is the one a partial-only review cannot find: it is
    # read by an isBuy getter in shared/_alpine_factories, strictly, with no
    # default — so a step passed alone renders the cash-out arm under a card
    # labelled "buy". props.flow appears ZERO times in _cdp_ramp itself.
    "cdp-ramp"         => %w[flow step],
    "cosign-rejected"  => [],

    # ─── batch 2, the cheap five (2026-09-09) ────────────────────────────────
    # NO PROPS, AND THAT IS A MEASUREMENT. shared/_alpine_factories swaps to
    # quest-success with seeds_earned, seeds_total and seeds_level, and
    # modals/_quest_success reads NONE of them — its x-data is empty and the
    # seeds bar is server-rendered from display_seeds_data. Declaring any of the
    # three here would fail half (b) below, which is the correct answer.
    "quest-success"       => [],
    # The one key the standalone celebration reads. The retired mirror gated the
    # bar on a firstJoin boolean and the CTA on a questOpen boolean; the real
    # card gates the bar on seeds_earned being positive and decides the CTA
    # server-side from current_user.next_quest, which no prop can move.
    "newsletter-success"  => %w[seeds_earned],
    "unsubscribe-goodbye" => [],
    # The shortfall arithmetic, all three read by the partial. NOT `address`:
    # the mirror took one because a specimen has no session, and the real card
    # reads $store.session.address.
    "wallet-deposit"      => %w[neededCents usdcCents usdtCents],
    # FOUR DISPLAY PROPS, and the partial reads six. onConfirm and onCancel are
    # functions confirmSolanaNetworkIntent uses to settle a promise; a guide has
    # nothing to settle and the card guards both, so they are left off. Also NOT
    # `action`, which the opener passes to BUILD its message string and which
    # modals/_network_guard never reads.
    "network-guard"       => %w[title message networkLabel environmentLabel],

    # ─── batch 3, the middle five (2026-09-09) ───────────────────────────────
    # BOTH ADDRESSES, because the card carries NO fallbacks:
    # modals/_email_change_pending renders bare x-text on props.currentEmail and
    # props.newEmail, so a prop left out paints an EMPTY span where an address
    # belongs. The retired mirror defaulted both to sample addresses, which is
    # the convenience that hides an omitted prop instead of exposing it.
    "email-change-pending" => %w[currentEmail newEmail],
    # NO lobbyUrl, AND THE OMISSION IS THE POINT. blocks/_cta_redirect forks on
    # its destination: truthy runs window.location.href when the drain ends,
    # null fires a no-op and a click falls through to closing the card.
    # modals/_it_begins wires that destination straight to props.lobbyUrl, so a
    # lobbyUrl passed HERE would navigate the guide to a contest page eight
    # seconds after the card opened, leaving it a dead spinner on the way out
    # (go sets redirecting true and never resets it). Declaring the key would
    # fail half (a) against a trigger that correctly passes nothing.
    "it-begins"            => [],
    # ONE OF THE TWO KEYS THE CARD READS, and the one its caller sends.
    # solana_utils.js's 429 interceptor is the only opener and passes
    # secondsLeft alone; props.message is read with a default of "You are going
    # a bit fast." that no caller in this app overrides, so the default is the
    # line every real 429 shows and the trigger leaves it off rather than
    # rendering copy nobody has met.
    "rate-limit-general"   => %w[secondsLeft],
    # THE ONLY PROP IS A CALLBACK. props.onSubmit is a function questNewsletter
    # passes so the CALLER owns the subscribe request; a guide has no request to
    # own, the card guards the call, and submit closes either way — the same
    # reason network-guard is opened without onConfirm and onCancel.
    "newsletter-email"     => [],
    # READS NO PROPS AT ALL: its endpoint is server-rendered into the x-data
    # from newsletter_unsubscribe_path, and its one production opener calls
    # open with an id and no second argument.
    "unsubscribe-confirm"  => [],

    # ─── batch 3, the heavy five (2026-09-09) ────────────────────────────────
    # auth is carded TWICE — the credentials face and the funding face — because
    # props.step drives eight faces from one id. This is the UNION of what both
    # triggers pass, which is what the markup half compares against.
    "auth"             => %w[step submitting],
    "onramp-hub"       => %w[returnModal],
    # NO PROPS. An earlier draft passed returnModal, which NOTHING reads: the
    # card writes it as a literal when it swaps to the hub and never
    # dereferences one. Half (b) below missed it because the string
    # "props.returnModal" appears in an ERB COMMENT in that partial — a comment
    # saying the prop is written elsewhere and not read here. The guard was
    # satisfied by prose DENYING the thing it asserts, which is why (b) now
    # strips comments before it looks.
    "wallet-topup"     => []
  }.freeze

  # Ids carded MORE THAN ONCE, and how many EXTRA cards each contributes beyond
  # its first. Not a loophole — a second card must earn it by showing a face the
  # first cannot reach with the same trigger.
  EXTRA_FACES = { "auth" => 1 }.freeze

  # Cards driven through the LEGACY PROXY rather than by opening an id with a
  # props hash. modals/_onchain_tx reads zero props — every field comes off
  # $store.solanaModal — so opening it with a props hash paints an EMPTY card.
  # It has no TRIGGERS entry because there are no props to declare.
  PROXY_DRIVEN = { "onchain-tx" => "Alpine.store('solanaModal').show(" }.freeze

  # One card's hidden reference prose, as style/_modal_specimen renders it.
  REFERENCE_SPAN = %r{<span x-ref="ref" class="hidden">.*?</span>}m

  # Where a prop may legitimately be READ. The partial is the obvious place; the
  # Alpine factory is the one that made the first version of this test blind.
  PROP_SOURCES = [
    "app/views/modals/_%s.html.erb",
    "app/views/shared/_alpine_factories.html.erb"
  ].freeze

  # Ids whose registration is capability-gated. Their card is rendered DISABLED
  # rather than triggered, so requiring a live registration would fail on any
  # stack with the capability off.
  #
  #   helper - the predicate the LAYOUT gates the registration on.
  #   flag   - the AppFlags reader behind it, so a test can turn the capability
  #            ON and meet the other branch. Stubbing the FLAG rather than the
  #            helper keeps the real predicate (logged_in? && ...) in the path.
  #   badge  - the exact disabled label the card must carry while it is off, and
  #            must NOT carry once it is on.
  CAPABILITY_GATED = {
    "cdp-ramp" => {
      helper: :cdp_ramp_modal_available?,
      flag:   :cdp_ramp?,
      badge:  "requires ENABLE_CDP_RAMP"
    }
  }.freeze

  setup do
    log_in_as(users(:alex))
    get admin_style_path
    follow_redirect! while response.redirect?
    assert_response :success
    @body = response.body
  end

  test "the host section renders inside the gem's container" do
    assert_includes @body, 'id="host-modals"',
                    "the engine renders the section element; if this is missing the seam did not resolve"
    assert_includes @body, "app/views/style/host/_modals.html.erb",
                    "the gem's intro line names the file that contributed the section"
  end

  test "every trigger opens an id that is REGISTERED ON THE RENDERED PAGE" do
    # THIS ASSERTION USED TO READ SOURCE FILES AND IT PROVED NOTHING. It grepped
    # layouts/application.html.erb for `current().id === '<id>'` — a string that
    # is in the file whether or not its enclosing `<% if %>` ever renders. It
    # passed on cdp-ramp while that card opened an EMPTY panel, because the id is
    # registered behind cdp_ramp_modal_available? and the flag is off by default.
    #
    # modal_registration_sources scans the RENDERED body and counts <template>
    # nesting for exactly this failure. Asserting against @body is what makes the
    # guard bite.
    TRIGGERS.each_key do |id|
      gate = CAPABILITY_GATED[id]

      if gate && !ApplicationController.helpers.respond_to?(gate[:helper])
        next
      end

      blocks = app_registration_sources(@body, id)

      if gate
        # Capability off: the card must be rendered DISABLED, not triggered.
        next if blocks.empty?
      end

      refute_empty blocks,
                   "#{id} is triggered from the host section but has NO registration on the " \
                   "rendered page — the host would open an EMPTY panel"
    end
  end

  test "a capability-gated card is disabled rather than silently dead" do
    # The honest state for a capability that is off. Without this, "no
    # registration" and "correctly greyed out" look identical to the test above.
    section = decoded_section(@body)

    CAPABILITY_GATED.each do |id, gate|
      next unless app_registration_sources(@body, id).empty?

      # This assert also KEEPS THE REFUTE BELOW HONEST. A refute over an empty
      # string passes for free, so if decoded_section ever came back blank the
      # guard would go silently vacuous — the exact way a test stops biting
      # without anyone noticing. Proving the badge is IN the slice first means
      # the slice is provably being read.
      assert_includes section, gate[:badge],
                      "#{id} has no registration on this stack, so its card must carry a " \
                      "disabled label saying why rather than offering a dead trigger"

      # THE OTHER HALF OF "DISABLED", and the half the badge cannot stand in for.
      # The badge is driven by `disabled:`, the trigger by `openable:`, and they
      # are SEPARATE locals on style/_modal_specimen — so a card can render the
      # badge and a live trigger at the same time. That combination is the exact
      # round-1 defect of /tasks/turf-owns-modal-section: a clickable card
      # opening an id nothing registered, i.e. an empty panel, under a badge
      # still saying the flag is off. Measured on this file at 3ef5bcf0 with
      # `openable: true`: role=button 4 to 5, three rendered triggers, ZERO
      # registrations, badge still present, whole suite green.
      refute_includes section, "$store.modals.open('#{id}'",
                      "#{id} has no registration on this stack, so its card must render NO " \
                      "trigger — a clickable card here opens an EMPTY panel, and the " \
                      "disabled badge beside it makes that look intentional"
    end
  end

  # THE GUARD THAT MAKES EVERY OTHER GUARD IN THIS FILE REACH EVERY CARD.
  #
  # Every other assertion here iterates TRIGGERS, so a card added WITHOUT an
  # entry was unguarded end to end: its id was never checked for a registration,
  # its props were never compared against the partial, and nothing anywhere
  # noticed it existed. MEASURED on this file at 4ec5a35d, the batch-2 merge, by
  # adding a sixth card whose id was a typo nothing registers and giving it no
  # TRIGGERS entry — the whole suite stayed GREEN while the page carried a card
  # that opens an EMPTY panel. Found by mutation testing during the batch-2
  # review and recorded there as scope for the next batch.
  #
  # The fix is to stop trusting the constant as the census. The set of cards the
  # PAGE renders is asserted against the set this file declares, in both
  # directions, so a card cannot be added invisibly and a declared card cannot
  # quietly vanish.
  test "the cards RENDERED in the section are exactly the cards this test declares" do
    section = triggerable_section(@body)

    # (a) THE IDS. A card added with no entry renders a trigger whose id nothing
    # declares, and lands here. A declared id whose card was deleted goes
    # missing from the page, and lands here too.
    rendered = section.scan(/\$store\.modals\.open\('([^']+)'/).flatten.uniq.sort
    expected = (TRIGGERS.keys - gated_off_ids(@body)).sort

    assert_equal expected, rendered,
                 "the section renders triggers for #{rendered.inspect} while this test declares " \
                 "#{expected.inspect} — an undeclared card is checked by NOTHING in this file, " \
                 "including whether the id it opens is registered at all"

    # (b) THE CARDS. Half (a) can only see a card that renders a TRIGGER, and a
    # DISABLED card renders none — so an undeclared card would slip past (a) by
    # being disabled.
    #
    # THE SUPPRESSING LOCAL IS `disabled:`, NOT `openable:`, and this comment
    # used to name the wrong one. Measured against the gem's
    # style/_modal_specimen, which computes `clickable = !(disabled &&
    # !openable)`: `openable: false` ALONE leaves a card fully clickable, so a
    # card hidden from half (a) is one passing `disabled: true`. The two locals
    # are only jointly suppressing — `disabled: true` WITH `openable: true`
    # renders a trigger again, which is the gem's documented preview case and
    # which no card in this section uses (cdp-ramp passes them as exact
    # opposites of one predicate).
    #
    # style/_modal_specimen prints exactly one hidden reference span per card,
    # gated on nothing, so counting those counts cards whether or not they are
    # clickable.
    #
    # ONE CARD PER DECLARED ID WAS THE ASSUMPTION, and batch 3 broke it honestly
    # in two ways, so the expected count is DERIVED rather than equal to
    # TRIGGERS.size:
    #   EXTRA_FACES — one id may be carded more than once when props select
    #     genuinely different faces of it. `auth` is carded twice, credentials
    #     and funding, because props.step drives eight faces from one id and the
    #     funding face is chosen by a SERVER helper no prop can reach.
    #   PROXY_DRIVEN — a card may render no `$store.modals.open` trigger at all.
    #     onchain-tx reads zero props and is driven through $store.solanaModal,
    #     so it has no id in TRIGGERS to be counted by.
    # Both are declared above, so an UNdeclared extra card still lands here.
    expected_cards = TRIGGERS.size + EXTRA_FACES.values.sum + PROXY_DRIVEN.size

    assert_equal expected_cards, decoded_section(@body).scan(REFERENCE_SPAN).size,
                 "the section renders a different number of specimen cards than the " \
                 "#{expected_cards} this test declares (#{TRIGGERS.size} ids + " \
                 "#{EXTRA_FACES.values.sum} extra face(s) + #{PROXY_DRIVEN.size} proxy-driven) — " \
                 "half (a) above sees only cards that render a trigger, so a disabled card added " \
                 "here is caught by this half alone"
  end

  test "no trigger drives the gem's page-scoped store" do
    # dsModals is the engine section's private host. Driving it from here would
    # rebuild the mirror this section exists to replace — and it would LOOK fine,
    # because dsModals is defined on this page.
    refute_includes decoded_section(@body), "dsModals",
                    "a host specimen must drive the app's real $store.modals, never dsModals"
  end

  test "the props in the RENDERED trigger match the declared set, and the code reads them" do
    # TWO HALVES, because the first version had neither. It iterated TRIGGERS and
    # grepped the partial, never touching @body — so nothing asserted that the
    # markup passes those keys at all, and a mutation "proving" this guard only
    # ever reddened by editing the constant.
    TRIGGERS.each do |id, keys|
      passed = rendered_trigger_props(@body, id)

      # A DISABLED card renders no trigger at all — which is the point of
      # disabling it, and is asserted by the capability test above. There is
      # then no markup to compare against, so half (a) does not apply; half (b)
      # still does, because the declared keys are what the card WILL pass on a
      # stack where the capability is on.
      gated_off = CAPABILITY_GATED.key?(id) && app_registration_sources(@body, id).empty?

      unless gated_off
        # (a) the MARKUP and the constant must agree, in both directions. nil
        # here means NO trigger rendered at all, which is a different failure
        # from an empty prop set and must not be flattened into one: two of
        # these cards legitimately pass {}.
        assert_equal keys.sort, passed,
                     "the rendered trigger for #{id} passes #{passed.inspect} but this test " \
                     "declares #{keys.sort.inspect} — one of them is wrong"
      end

      # (b) every key must be read SOMEWHERE the code actually looks.
      #
      # KNOW WHAT THIS HALF DOES NOT PROVE, because its name invites the wrong
      # reading. It is a PRESENCE check — does the string `props.<key>` occur in
      # either source — and any occurrence satisfies it. MEASURED at 3ef5bcf0:
      # replacing the isBuy getter's `this.props.flow === "buy"` (the read that
      # actually picks the buy arm, _alpine_factories:1001) with a constant left
      # this whole file GREEN, because an unrelated step-advance path at :1194
      # also names c.props.flow. So half (b) catches a prop nothing reads at all;
      # it does not catch a prop read in the wrong place, and it is not what
      # holds the arm. The flag-ON test below is — it reads the trigger off the
      # rendered page and requires flow to be THERE. Tightening this grep to
      # match today's exact expression was considered and rejected: it would
      # redden on an innocent refactor while still proving nothing about what
      # the page does.
      keys.each do |key|
        sources = PROP_SOURCES.map { |f| Rails.root.join(f.include?("%s") ? format(f, id.tr("-", "_")) : f) }
        found   = sources.any? do |f|
          next false unless File.exist?(f)

          # COMMENTS STRIPPED FIRST. A prop named only in prose is not read by
          # anything, and _wallet_topup's header names props.returnModal purely
          # to say it is NOT dereferenced there — which satisfied this guard
          # while the trigger passed a prop nothing consumed.
          File.read(f).gsub(/<%#.*?%>/m, "").include?("props.#{key}")
        end

        assert found,
               "#{id} is opened with #{key}, but props.#{key} is read in none of " \
               "#{sources.map(&:basename).join(', ')} — that is specimen drift"
      end
    end
  end

  test "with the capability ON the gated card registers and passes its declared props" do
    # THE BRANCH THAT ACTUALLY RUNS IN PRODUCTION, and nothing exercised it.
    # ENABLE_CDP_RAMP is off in dev, test and QA, so every assertion above meets
    # the gated-OFF page and the ON page is asserted by nobody — while ON is
    # where the card is clickable and where its props decide which arm of the
    # modal opens. Measured at 3ef5bcf0: dropping `flow` from the cdp-ramp
    # trigger left the whole suite green, because half (a) of the prop-match
    # test short-circuits on gated_off and never reaches this card.
    CAPABILITY_GATED.each do |id, gate|
      AppFlags.stub(gate[:flag], true) do
        log_in_as(users(:alex))
        get admin_style_path
        follow_redirect! while response.redirect?
        assert_response :success
        body = response.body

        refute_empty app_registration_sources(body, id),
                     "with #{gate[:flag]} ON, #{id} must be REGISTERED on the rendered page — " \
                     "the card is clickable here, so without it the click opens an EMPTY panel"

        assert_equal TRIGGERS.fetch(id).sort, rendered_trigger_props(body, id),
                     "with #{gate[:flag]} ON the rendered #{id} trigger must pass exactly " \
                     "#{TRIGGERS.fetch(id).sort.inspect} — flow is read by an isBuy getter " \
                     "strictly and with no default, so a step passed WITHOUT it renders the " \
                     "cash-out arm under a card labelled buy"

        refute_includes decoded_section(body), gate[:badge],
                        "#{id} is registered and clickable here, so its card must not still " \
                        "carry the #{gate[:badge].inspect} badge"
      end
    end
  end

  # THE FILTER'S OWN GUARD, and the reason no id list and no count is written
  # into this file or into style/host/_modals.html.erb.
  #
  # app_registration_sources exists to narrow registrations to this app's host,
  # and NOTHING here proved it was still narrowing anything. Every other
  # assertion in this file passes identically whether the filter bites or is a
  # no-op, so the day the gem retires its last same-string specimen the filter
  # goes inert and every sentence explaining it goes quietly false — which is
  # exactly what happened to the four ids this file used to name.
  #
  # IF THIS GOES RED, THE ANSWER IS PROBABLY NOT TO FIX THE FILTER. It means the
  # gem stopped registering any of this section's ids, so the hazard is gone:
  # re-measure, then either delete the filter and its rationale together or
  # record why it is kept. Deleting one and leaving the other is the failure
  # mode this whole task existed to clean up.
  test "the dsModals filter still has ids to filter, and they survive it" do
    colliding = colliding_ids(@body)

    refute_empty colliding,
                 "no id this section triggers is ALSO registered by the gem's dsModals host on " \
                 "this page, so app_registration_sources is filtering nothing — the comment " \
                 "above it describes a hazard that no longer exists. Re-measure and either " \
                 "retire the filter with its rationale or record why it stays"

    colliding.each do |id|
      dropped = modal_registration_sources(@body, id) - app_registration_sources(@body, id)

      assert dropped.all? { |block| block.include?("dsModals") },
             "the filter dropped a registration for #{id} that does NOT belong to the gem's " \
             "page-scoped host — it must narrow to this app's host, never past it"

      refute_empty app_registration_sources(@body, id),
                   "#{id} is registered on BOTH hosts here and the filter dropped EVERY " \
                   "registration — this app's own must survive, or every guard reading it " \
                   "reports an empty panel on a card that works"
    end
  end

  # THE NEWSLETTER CARDS' CLAIM ABOUT THE ENGINE, ASSERTED RATHER THAN WRITTEN.
  #
  # Three cards in this section used to say the engine owns no newsletter — one
  # of them "and no endpoint", one "and no seeds" — and every half of it was
  # false. The prose now states the opposite, which needs the same protection
  # the collision census got: a measured sentence with nothing holding it is one
  # gem release away from being a false one again.
  #
  # IT IS A REAL CONSUMER CONTRACT, not only prose insurance.
  # config/initializers/studio.rb REPLACES the engine's newsletter row by
  # matching `section[:key] == :newsletter` in Studio.default_profile_sections;
  # if the engine dropped the newsletter the map would match nothing, no-op in
  # silence, and this app's row would vanish from /profile.
  test "the engine really does own the newsletter these cards say it owns" do
    assert Studio::Newsletter.respond_to?(:serves?),
           "the newsletter cards say the engine owns Studio::Newsletter; the resolved engine " \
           "does not define it, so re-measure those cards before this reads as true"

    assert_equal({ controller: "studio/profiles", action: "subscribe_newsletter" },
                 Rails.application.routes.recognize_path("/profile/newsletter", method: :post),
                 "the newsletter-email card names POST profile/newsletter as the engine's")

    assert_equal({ controller: "studio/profiles", action: "unsubscribe_newsletter" },
                 Rails.application.routes.recognize_path("/profile/newsletter", method: :delete),
                 "the unsubscribe-confirm card names DELETE profile/newsletter as the engine's " \
                 "endpoint, which is the exact half its old prose denied")
  end

  private

  # The ids this section triggers that the GEM also registers on this same page,
  # derived rather than declared. A size difference can only come from the
  # dsModals reject below, so it is precisely the collision set.
  def colliding_ids(body)
    TRIGGERS.keys.select do |id|
      modal_registration_sources(body, id).size > app_registration_sources(body, id).size
    end
  end

  # Registrations on THIS APP'S host only.
  #
  # WHY THE RAW HELPER IS NOT ENOUGH HERE. The guide renders the gem's own
  # Modals section on the SAME page and BEFORE this one (style/index.html.erb
  # renders "style/modals" then "style/host"), and SOME of the ids this section
  # triggers are ALSO specimen ids in that section, spelled identically.
  # modal_registration_sources matches `<template x-if="[^"]*id === '<id>'`, and
  # `[^"]*` happily spans `$store.dsModals.current().`, so the gem's page-scoped
  # mirror satisfies a bare refute_empty. Delete this app's own registration for
  # one of those ids from layouts/application and the raw helper still returns a
  # block: the guard would go green while the card opened an EMPTY panel, which
  # is the precise failure the guard exists to catch.
  #
  # WHICH IDS THOSE ARE IS DELIBERATELY NOT WRITTEN DOWN HERE, and that is the
  # correction this comment carries. It used to name four — quest-success,
  # unsubscribe-goodbye, wallet-deposit and network-guard — and every one of
  # them stopped colliding the moment studio-engine retired the matching
  # specimens. Nothing failed; the sentence simply went on reading as a live
  # measurement. `colliding_ids` DERIVES the set from the rendered page and the
  # test named "the dsModals filter still has ids to filter" asserts it is
  # non-empty and prints it on failure, so the census maintains itself and the
  # next retirement reddens a test instead of rotting a comment.
  #
  # The two hosts are separate Alpine stores, so the collision is harmless at
  # runtime and only ever a hazard to a test. Filtering on the OPENING TAG is
  # what makes the assertion name the right host.
  def app_registration_sources(body, id)
    modal_registration_sources(body, id).reject do |block|
      block[/\A<template x-if="[^"]*"/].to_s.include?("dsModals")
    end
  end

  # The host section onward, HTML-DECODED.
  #
  # WHY DECODED. style/_modal_specimen marks open_expr html_safe today, so a
  # trigger lands in the markup with its quotes literal. If that ever changes it
  # renders as open(&#39;cdp-ramp&#39;, ...) — still a live trigger, still a
  # click that opens the modal — and a raw-string assertion would stop matching
  # it. That failure is silent in the dangerous direction: the refute above
  # would PASS on a page rendering exactly the trigger it exists to forbid.
  def decoded_section(body)
    idx = body.index('id="host-modals"')
    return "" unless idx

    # BOUNDED AT THE NEXT SECTION, because the host section is NOT the last one
    # on this page: style/index.html.erb renders theme, modals, host, tricks,
    # tasks in that order, so a slice to end-of-document carries Tricks and
    # Tasks along with the section it claims to be. Nothing in those two renders
    # a modal specimen or names a store today, which is the only reason the
    # unbounded version was ever right — and a card-counting assertion cannot
    # rest on that staying true. The search starts at the ATTRIBUTE, so the host
    # section's own opening tag is already behind it.
    nxt = body.index("<section id=", idx)
    CGI.unescapeHTML(body[idx...(nxt || body.length)])
  end

  # decoded_section with the hidden REFERENCE PROSE stripped out.
  #
  # The reference is rendered page CONTENT — style/_modal_specimen prints it
  # into a hidden span so the Copy button can read it back — so a card whose
  # prose quotes an open() call is indistinguishable, to a scanner, from a card
  # that carries one. Every assertion that hunts for triggers reads this, which
  # is what lets the prose describe a trigger without becoming one.
  def triggerable_section(body)
    decoded_section(body).gsub(REFERENCE_SPAN, "")
  end

  # The capability-gated ids whose capability is OFF on this stack. Their card
  # renders a disabled badge and NO trigger, so they are absent from the
  # rendered-id set by design rather than by omission.
  def gated_off_ids(body)
    CAPABILITY_GATED.keys.select { |id| app_registration_sources(body, id).empty? }
  end

  # The prop keys the RENDERED trigger for one id passes, sorted; nil when the
  # page renders no trigger for it at all. Read off the decoded page, never off
  # the partial — the source says what the card WOULD pass, and the whole defect
  # class here is markup that says something else.
  # THE KEY PATTERN ALLOWS AN UNDERSCORE, and it has to. It was [a-zA-Z]+, which
  # on `{ seeds_earned: 25 }` matches only the letters abutting the colon and
  # reports the key as "earned" — a mismatch against a correctly declared
  # `seeds_earned` that reads as specimen drift while the markup is right. Every
  # prop the section passed before 2026-09-09 was camelCase, so nothing had ever
  # exercised it; modals/_newsletter_success reads props.seeds_earned.
  # EVERY trigger for an id, unioned — not just the first.
  #
  # It read only the first match until 2026-09-09, which left a SECOND card for
  # an already-declared id passing whatever it liked: measured, adding a bogus
  # key to the tokens-picker trigger alone left this file green. auth is carded
  # twice on purpose (credentials and funding faces), so "first trigger wins"
  # silently exempted half of it. The TRIGGERS comment already called the
  # declared set a union; this is the code catching up to the comment.
  def rendered_trigger_props(body, id)
    triggers = triggerable_section(body)
               .scan(/\$store\.modals\.open\('#{Regexp.escape(id)}'(?:,\s*\{(.*?)\})?\s*\)/m)
               .flatten.compact
    return nil if triggers.empty?

    triggers.flat_map { |args| args.scan(/([a-zA-Z_]+):/).flatten }.uniq.sort
  end

  test "the proxy-driven card drives the proxy, and is still registered" do
    # THE TRAP: opening onchain-tx the way every other card is opened renders an
    # EMPTY card. It reads zero props — message, errorMessage, ctaLabel,
    # recoveryLabel and the rest all come off $store.solanaModal — so a props
    # hash reaches nothing. The trigger looks like its neighbours and behaves
    # nothing like them, which is exactly the kind of thing a reader copies.
    section = decoded_section(@body)

    PROXY_DRIVEN.each do |id, call|
      assert_includes section, call,
                      "#{id} is driven through the legacy proxy — its trigger must call " \
                      "#{call}…, not $store.modals.open, which would paint an empty card"

      refute_includes section, "$store.modals.open('#{id}'",
                      "#{id} reads no props; opening it with a props hash renders an empty card"

      # Registration is asserted for it like any other card — the proxy is a
      # compatibility layer OVER $store.modals, so the id still has to be
      # registered in turf's own layout host or the real host paints nothing.
      refute_empty app_registration_sources(@body, id),
                   "#{id} is triggered from the host section but turf's layout registers no " \
                   "such modal — the host would open an EMPTY panel"
    end
  end

  test "no card traps the page — every triggered card can be closed" do
    # THE CLASS THIS GUARDS, and it shipped once. The on-chain card is opened
    # through solanaModal.show(), which pins props.dismissible=false; the gem
    # host gates BOTH escape and backdrop-click on that flag, and the processing
    # arm renders no close control of its own. In the app that is right — an
    # accidental click must not orphan a signed-but-unconfirmed transaction, and
    # every production show() is followed by success() or error(), each of which
    # flips the flag back. A SPECIMEN has nothing following it, so the card
    # became the repo's first orphan show() and only a page reload escaped it.
    #
    # Asserted at the TRIGGER, because that is the only place a specimen can fix
    # it: a trigger that pins dismissible false must re-arm it in the same
    # expression. Written for the class rather than for onchain-tx, since the
    # next proxy-driven card will reach for the same show().
    section = decoded_section(@body)

    section.scan(/@click="([^"]*solanaModal[^"]*)"/).flatten.each do |trigger|
      next unless trigger.include?(".show(")

      assert_match(/dismissible\s*=\s*true/, trigger,
                   "a specimen opening the on-chain card with solanaModal.show() must re-arm " \
                   "dismissible in the same trigger — show() pins it false, the processing arm " \
                   "has no close control, and nothing follows a specimen to flip it back, so " \
                   "the card traps the page until reload. Trigger was: #{trigger}")
    end
  end
end
