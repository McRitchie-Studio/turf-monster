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
    "cosign-rejected"  => []
  }.freeze

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

      blocks = modal_registration_sources(@body, id)

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
      next unless modal_registration_sources(@body, id).empty?

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

  test "no trigger drives the gem's page-scoped store" do
    # dsModals is the engine section's private host. Driving it from here would
    # rebuild the mirror this section exists to replace — and it would LOOK fine,
    # because dsModals is defined on this page.
    section = @body[@body.index('id="host-modals"')..] || ""
    refute_includes section, "dsModals",
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
      gated_off = CAPABILITY_GATED.key?(id) && modal_registration_sources(@body, id).empty?

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
        found   = sources.any? { |f| File.exist?(f) && File.read(f).include?("props.#{key}") }

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

        refute_empty modal_registration_sources(body, id),
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

  private

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
    idx ? CGI.unescapeHTML(body[idx..]) : ""
  end

  # The prop keys the RENDERED trigger for one id passes, sorted; nil when the
  # page renders no trigger for it at all. Read off the decoded page, never off
  # the partial — the source says what the card WOULD pass, and the whole defect
  # class here is markup that says something else.
  def rendered_trigger_props(body, id)
    args = decoded_section(body)[/\$store\.modals\.open\('#{Regexp.escape(id)}'(?:,\s*\{(.*?)\})?\s*\)/m, 1]
    args&.scan(/([a-zA-Z]+):/)&.flatten&.sort
  end
end
