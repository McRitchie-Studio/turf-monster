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

  test "the welcome step renders the username and a continue CTA" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding",
                                 props: { step: "welcome", username: "keen-persimmon",
                                          steps: %w[welcome first_name age wallet] }.to_json)
    assert_response :success
    assert_includes response.body, "You&#39;re in"
    assert_includes response.body, "keen-persimmon"
    assert_includes response.body, "continueFromWelcome()"
  end

  test "the first-name step renders the field, save, and BOTH skip affordances" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding",
                                 props: { step: "first-name", steps: %w[first_name age wallet] }.to_json)
    assert_response :success
    assert_includes response.body, "What should we call you?"
    assert_includes response.body, 'id="onboarding-first-name"'
    assert_includes response.body, "Save and continue"
    # Skippable was an explicit operator call: the link AND the × both skip, so
    # closing the card is never a dead end that loses the rest of the chain.
    assert_includes response.body, "Skip for now"
    assert_includes response.body, 'aria-label="Skip"'
    assert_includes response.body, "/onboarding/skip_first_name"
  end

  test "the modal hands the remaining steps to the chain driver" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: { step: "welcome" }.to_json)
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
    # welcome + first_name are both the `onboarding` modal, so map service steps
    # onto the modal ids the flows actually open.
    flow_modal_ids = AdminController::MODAL_FLOWS.flat_map { |f|
      f[:steps].map { |s| AdminController::MODAL_VARIANTS.find { |v| v[:key] == s[:key] }[:modal_id] }
    }.uniq
    expected = { welcome: "onboarding", first_name: "onboarding",
                 age: "age-verify", wallet: "wallet-setup" }

    assert_equal OnboardingFlow::STEPS.sort, expected.keys.sort,
                 "OnboardingFlow::STEPS changed — update this map AND the gallery flows"
    expected.each do |step, modal_id|
      assert_includes flow_modal_ids, modal_id,
                      "chain step #{step} opens #{modal_id}, which no gallery flow shows"
    end
  end
end
