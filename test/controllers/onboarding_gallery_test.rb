require "test_helper"

# The onboarding modal's rendered states, and the /admin/modals FLOWS section
# that presents them as ordered sequences.
class OnboardingGalleryTest < ActionDispatch::IntegrationTest
  # Same failure mode as the wallet-setup modal: a double quote inside the
  # double-quoted x-data closes the attribute early and Alpine mounts the whole
  # component as a SILENT no-op — the markup still renders, so every
  # assert_includes below still passes while the modal is dead in a browser. It
  # has bitten twice already (auth modal PR #30, then the wallet modal), so every
  # new step-machine modal gets this guard.
  test "the onboarding x-data attribute contains no double quotes" do
    source = Rails.root.join("app/views/modals/_onboarding.html.erb").read
    # Anchored on the attribute's own SHAPE — it opens `{` and closes `}"` at
    # end of line — rather than on whichever attribute happens to follow it.
    # The old locator required `class=` to come next, and went red the moment
    # a data- attribute and an x-init joined the root element: a passing
    # invariant reported as a failure. The `}"` anchor cannot be satisfied by an
    # inner brace (those are followed by a comma or a newline, never a quote),
    # so this still captures the WHOLE attribute, which is what makes the
    # assertion below meaningful.
    x_data = source[/x-data="(\{.*?\})"\s*\n/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside the double-quoted x-data closes it early and " \
                        "silently kills the modal in the browser (markup assertions won't catch it)"
  end

  # The welcome step was RETIRED on 2026-08-15 (operator call): the chain greets
  # with the first-name ask. This is the negative pin — the card, its username
  # line and the step machine that walked to it must all be gone, so a partial
  # revert that leaves one of them behind is caught here rather than in a
  # browser.
  test "the retired welcome step leaves nothing behind" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    assert_not_includes response.body, "You&#39;re in"
    assert_not_includes response.body, "continueFromWelcome"
    assert_not_includes response.body, "asksFirstName"
    assert_not_includes AdminController::MODAL_VARIANTS.map { |v| v[:key] }, "onboarding-welcome"
  end

  # No props: the modal asks one question now, so there is nothing to pass it.
  # The empty hash IS the assertion — the card has to render on its own.
  test "the first-name card renders the field, save, and BOTH skip affordances" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    assert_includes response.body, "What should we call you?"
    assert_includes response.body, 'id="onboarding-first-name"'
    assert_includes response.body, "Save and continue"
    # Focused on open (operator call). Alpine, not the HTML autofocus attribute:
    # browsers honour that at parse time, and this modal mounts from a
    # <template x-if> long afterwards. e2e proves the focus actually lands.
    assert_includes response.body, "$el.focus({ preventScroll: true })"
    # Skippable was an explicit operator call: the link AND the × both skip, so
    # closing the card is never a dead end that loses the rest of the chain.
    #
    # The × label is BOUND rather than static since the entry gate started
    # opening this same card in a required mode, where the × only closes — so
    # assert the binding, and that this (chain) caller is the Skip side of it.
    assert_includes response.body, "Skip for now"
    assert_includes response.body, %(:aria-label="required ? 'Close' : 'Skip'")
    assert_includes response.body, %(@click="required ? $store.modals.close() : skip()")
    assert_includes response.body, "/onboarding/skip_first_name"
  end

  # --- the typed placeholder --------------------------------------------------

  test "the card ships the sampled name list and types it into the placeholder" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success

    # The list rides a data- attribute rather than the x-data expression, and
    # that is not decoration: x-data is a DOUBLE-QUOTED attribute, so a JSON
    # array — which is all double quotes — cannot live inside it without closing
    # it early and killing the modal. Parse what actually rendered, so an
    # escaping change surfaces here rather than as a silent no-op in a browser.
    raw = response.body[/data-placeholder-names='([^']*)'/m, 1]
    assert raw.present?, "the name pool must render onto the root element"
    names = JSON.parse(CGI.unescapeHTML(raw))
    assert_equal OnboardingHelper::QB_FIRST_NAMES, names

    assert_includes response.body, "startPlaceholder(JSON.parse($el.dataset.placeholderNames"
    assert_includes response.body, ':placeholder="placeholderText"',
                    "the placeholder must be BOUND — a static one cannot animate"
  end

  test "the placeholder yields to the user, and knows autofocus is not engagement" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success

    # Real typing dismisses it; a blur is recorded; a focus AFTER that blur
    # dismisses it too. A bare focus must not, because this field is autofocused
    # on mount — treating that as engagement would kill the animation before it
    # drew a character.
    assert_includes response.body, '@input="dismissPlaceholder()"'
    assert_includes response.body, '@blur="markPlaceholderBlurred()"'
    assert_includes response.body, '@focus="refocusPlaceholder()"'
    assert_includes response.body, "refocusPlaceholder() { if (this._phBlurred) this.dismissPlaceholder(); }"

    # Reduced motion gets the hint without the animation.
    assert_includes response.body, "prefers-reduced-motion: reduce"
  end

  # --- the chain's progress pill ----------------------------------------------

  # Filled segments in ONE modal's rendered pill.
  #
  # Scoped to that modal's <template> on purpose: the preview layout registers
  # EVERY modal in the page, so counting across the whole body counts every
  # pill in the app at once (it returned 7 the first time). The class string is
  # the engine partial's own (studio/modals/blocks/_progress_pill), so this
  # counts what a user actually sees rather than trusting the `current:`
  # argument we passed.
  def filled_pill_segments(body, modal_id)
    node = Nokogiri::HTML(body).css("template").find { |t|
      t["x-if"].to_s.include?("=== '#{modal_id}'")
    }
    assert node, "no <template> registration found for #{modal_id.inspect}"
    node.to_html.scan(%r{h-1\.5 flex-1 rounded-full bg-primary}).length
  end

  test "the chain's three cards read 1, 2 and 3 of 3 in order" do
    # Operator's call, 2026-08-19. Asserted TOGETHER in one test because the
    # numbers only mean anything as a sequence — renumbering one card in
    # isolation is exactly the change that would leave the chain reading 1, 2, 2.
    log_in_as users(:alex)

    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    assert_equal 1, filled_pill_segments(response.body, "onboarding"), "first name is step 1 of 3"

    # Renamed to `birthday` on 2026-08-26 when this app adopted the engine's
    # card. The pill also moved OUT of the card (the engine block has no yield
    # slot) to card top level, which is where steps 1 and 3 already put theirs —
    # so this assertion reads the same three segments in the same place.
    get admin_modal_preview_path(modal_id: "birthday", props: {}.to_json)
    assert_response :success
    assert_equal 2, filled_pill_segments(response.body, "birthday"), "the age gate is step 2 of 3"

    get admin_modal_preview_path(modal_id: "wallet-setup", props: {}.to_json)
    assert_response :success
    assert_equal 3, filled_pill_segments(response.body, "wallet-setup"), "wallet setup is step 3 of 3"
  end

  test "the chain's three modals are registered in the PREVIEW layout too" do
    # The root cause of the empty age-verify card: the app layout and the
    # preview layout each keep their OWN registration list, so a modal added to
    # one renders blank in the other — and blank is indistinguishable from a
    # modal that simply has little in it. The gallery happily listed and opened
    # a card the preview layout could not draw.
    #
    # SCOPED TO THE CHAIN on purpose. The same audit found SEVEN more gallery
    # modals unregistered in the preview layout (cosign-rejected, quest-success,
    # free-entry-earned, newsletter-subscribe, newsletter-success,
    # unsubscribe-confirm, unsubscribe-goodbye) and one — cosign-rejected —
    # missing from BOTH layouts, i.e. unreachable anywhere. Registering seven
    # unrelated modals is its own change with its own blast radius (some need
    # factories or stores the preview layout does not load, the way `username`
    # does), so it is a follow-up, not a passenger on this one. Widen this test
    # to the full manifest when that task lands.
    preview = Rails.root.join("app/views/layouts/modal_preview.html.erb").read
    # `birthday` replaced `age-verify` in the adoption; `age-gate` JOINED the
    # list, because the birthday card swaps to it on the server's underage
    # verdict — and an unregistered swap target is exactly the empty card this
    # test was written about, on the one path a person cannot retry out of.
    %w[onboarding birthday age-gate wallet-setup].each do |id|
      assert_includes preview, "$store.modals.current().id === '#{id}'",
                      "modal #{id.inspect} is in the gallery but not registered in modal_preview.html.erb, " \
                      "so its preview renders an empty card"
    end
  end

  test "the modal hands the remaining steps to the chain driver" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    # The modal must not know what comes after it — it reports and closes.
    assert_includes response.body, "onboarding-step-done"
  end

  test "the gallery lists both flows with their steps in order" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success

    assert_includes response.body, "Flows"
    assert_includes response.body, "Onboarding (after first auth)"
    assert_includes response.body, "Wallet setup"
    assert_includes response.body, "Play flow"
    # A mistyped step key would render this instead of a step.
    assert_not_includes response.body, "MISSING VARIANT"
  end

  test "every flow step resolves to a real registered variant" do
    # MODAL_FLOWS references MODAL_VARIANTS by key; a typo would silently render
    # a blank step in the gallery, so fail loudly here instead.
    AdminController::MODAL_FLOWS.each do |flow|
      flow[:steps].each do |step|
        variant = AdminController::MODAL_VARIANTS.find { |v| v[:key] == step[:key] }
        assert variant, "flow #{flow[:key]} references unknown variant key #{step[:key].inspect}"
        assert variant[:modal_id].present?, "variant #{step[:key]} has no modal_id to open"
      end
    end
  end

  test "the flows cover every step OnboardingFlow can resolve" do
    # The showroom must not fall behind the chain: a step added to the service
    # with no gallery step means a state nobody can review.
    #
    # Map service steps onto the modal ids the flows actually open.
    flow_modal_ids = AdminController::MODAL_FLOWS.flat_map { |f|
      f[:steps].map { |s| AdminController::MODAL_VARIANTS.find { |v| v[:key] == s[:key] }[:modal_id] }
    }.uniq
    expected = { first_name: "onboarding", age: "birthday", wallet: "wallet-setup" }

    assert_equal OnboardingFlow::STEPS.sort, expected.keys.sort,
                 "OnboardingFlow::STEPS changed — update this map AND the gallery flows"
    expected.each do |step, modal_id|
      assert_includes flow_modal_ids, modal_id,
                      "chain step #{step} opens #{modal_id}, which no gallery flow shows"
    end
  end
end
