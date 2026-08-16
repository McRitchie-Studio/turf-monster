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
    x_data = source[/<div x-data="(.*?)"\s*\n\s*class=/m, 1]
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
    expected = { first_name: "onboarding", age: "age-verify", wallet: "wallet-setup" }

    assert_equal OnboardingFlow::STEPS.sort, expected.keys.sort,
                 "OnboardingFlow::STEPS changed — update this map AND the gallery flows"
    expected.each do |step, modal_id|
      assert_includes flow_modal_ids, modal_id,
                      "chain step #{step} opens #{modal_id}, which no gallery flow shows"
    end
  end
end
