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
  # Both registrations of the `onboarding` id — skippable and required. See the
  # note in layouts/application for why the card is registered twice, and
  # test_helper's modal_registration_sources for why the slice is raw and
  # nesting-aware (the engine card contains an inner <template x-if="error">).
  def onboarding_card_sources(body)
    modal_registration_sources(body, "onboarding")
  end

  test "the onboarding x-data attributes contain no double quotes" do
    # ASKED OF THE RENDER, NOT OF A FILE. This used to read
    # app/views/modals/_onboarding.html.erb off disk. That file is gone — this
    # app renders the engine's studio/modals/onboarding/first_name now — and
    # re-pointing the read at the gem's copy would have been the wrong repair
    # twice over: it asserts against studio-engine's source instead of against
    # what this app ships, and a consumer test that pins a path inside the gem
    # RED-SEALS the gem's own release the moment that path moves.
    #
    # The rendered body is the better question anyway. It is what a browser
    # actually receives, it covers BOTH registered branches, and it is the only
    # form that can catch a bad value THIS APP interpolates into the attribute —
    # first_name_modal_locals passes a subtext straight into the card, and a
    # double quote in that string would kill the modal just as dead as one in
    # the gem's own JS.
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success

    cards = onboarding_card_sources(response.body)
    assert_equal 2, cards.length,
                 "expected BOTH first-name registrations to render (skippable + required); " \
                 "found #{cards.length}. A missing branch means one of the two callers gets " \
                 "the wrong card, not a blank one, which is far harder to see."

    cards.each_with_index do |card, i|
      # Anchored on the attribute's own SHAPE — it opens `{` and closes `}"` at
      # end of line — rather than on whichever attribute happens to follow it.
      # The `}"` anchor cannot be satisfied by an inner brace (those are followed
      # by a comma or a newline, never a quote), so this captures the WHOLE
      # attribute, which is what makes the assertion below meaningful.
      x_data = card[/x-data="(\{.*?\})"\s*\n/m, 1]
      assert x_data.present?,
             "could not locate the x-data attribute on registration #{i} — did the root element change?"
      assert_not_includes x_data, '"',
                          "a double quote inside the double-quoted x-data closes it early and " \
                          "silently kills the modal in the browser (markup assertions won't catch it)"
    end
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
    # A fourth assertion here checked MODAL_VARIANTS carried no onboarding-welcome
    # key. It went with the registry on 2026-09-09; the three above are what
    # actually prove the step left nothing in the rendered card.
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
    # RESOLVED SERVER-SIDE NOW, not bound. The engine's card decides both
    # affordances at RENDER time from its `required` local — it OMITS the skip
    # button rather than hiding it, and writes a literal aria-label — because a
    # skip control hidden with x-show is still in the DOM, and still clickable,
    # until Alpine mounts. So this asserts the SKIPPABLE branch's resolved
    # output, and the required branch's is asserted in first_name_entry_gate_test.
    skippable = onboarding_card_sources(response.body).find { |c| c.include?("Skip for now") }
    assert skippable, "no registration rendered the Skip affordance at all"
    assert_includes skippable, %(aria-label="Skip")
    assert_includes skippable, %(@click="skip()")
    assert_includes skippable, "/onboarding/skip_first_name"

    # THE HEADING, PINNED TO ITS VALUE. The gem supplies this string as a
    # DEFAULT, so nothing else in this app states it any more — and a gem that
    # reworded its own default would silently reword turf's card. The adoption
    # deliberately leans on that default because it is character-identical to
    # the markup it replaced; this is the assertion that keeps that true.
    assert_includes response.body, "What should we call you?"
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
    # DOUBLE-QUOTED AND ENTITY-ESCAPED, which is a real difference from the card
    # this replaced. turf's own card emitted the attribute in SINGLE quotes with
    # raw JSON inside, because its JSON array would otherwise have closed the
    # double-quoted x-data beside it. The engine renders the attribute normally
    # and lets Rails escape the quotes to &quot;. Both are correct; only one of
    # them matches a single-quote regex, and reading the value back through
    # unescapeHTML is what keeps this assertion about the POOL rather than about
    # the escaping style.
    raw = response.body[/data-placeholder-names="([^"]*)"/m, 1]
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
  #
  # ONE MODAL ID CAN HAVE SEVERAL REGISTRATIONS. `onboarding` has two since this
  # app adopted the engine's card (skippable + required — see the note in
  # layouts/application), so this counts every matching registration and
  # requires them to AGREE. Taking the first would quietly measure one branch
  # while the other drifted, and the pill is exactly the sort of local that gets
  # passed to one render call and forgotten on its sibling.
  def filled_pill_segments(body, modal_id)
    nodes = Nokogiri::HTML(body).css("template").select { |t|
      t["x-if"].to_s.include?("=== '#{modal_id}'")
    }
    assert nodes.any?, "no <template> registration found for #{modal_id.inspect}"
    counts = nodes.map { |n| n.to_html.scan(%r{h-1\.5 flex-1 rounded-full bg-primary}).length }
    assert_equal 1, counts.uniq.length,
                 "the #{nodes.length} registrations of #{modal_id.inspect} render different " \
                 "progress pills (#{counts.inspect}) — they are the same step and must agree"
    counts.first
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
    # SCOPED TO THE CHAIN on purpose, and the follow-up it once named has
    # landed. The same audit found SEVEN more gallery modals unregistered in
    # the preview layout (cosign-rejected, quest-success, free-entry-earned,
    # newsletter-subscribe, newsletter-success, unsubscribe-confirm,
    # unsubscribe-goodbye). All seven are now resolved, but by two different
    # routes, neither of them "register them here":
    #   - cosign-rejected reaches BOTH layouts from ONE entry in
    #     modals/_host_extras (2026-08-28, defork-turf-modal-host) — see below.
    #   - the other six were DELETED from the gallery
    #     (2026-09-06, /tasks/drop-dead-gallery-cards). They only ever drew
    #     blank cards here, and studio-engine's own /style#modals cards every
    #     one of them, so the gallery lost no review surface by dropping them.
    # The whole-manifest version of this property now lives in
    # test/controllers/modal_gallery_manifest_test.rb. This test stays chain-
    # scoped because the onboarding chain is what it was written to regress.
    #
    # COSIGN-REJECTED IS OFF THAT LIST as of 2026-08-28
    # (defork-turf-modal-host). It is registered ONCE, in
    # app/views/modals/_host_extras.html.erb, which studio-engine's host renders
    # inside its card on every path through it — so it now reaches BOTH layouts
    # from a single entry. Do NOT "fix" it by adding it to a layout block:
    # modal_host_adoption_test.rb fails on a second registration, because two
    # copies are free to drift and that is the disease this test names.
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

  # THE COPY THIS APP PASSES, which the gem would otherwise default away.
  # studio-engine's card ships a SHORTER subtext ("...we use it to address you in
  # emails."). Turf has always named what the emails are about, and the entry-gate
  # variant has always said why it is asking at that moment. Rendering the gem's
  # default would have dropped both clauses in an adoption whose whole job was to
  # change nothing a user sees — the exact "specimens show STRUCTURE, never
  # VALUES" failure the modal-lifecycle module records.
  test "both cards keep turf's own subtext rather than the gem's default" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success

    cards = onboarding_card_sources(response.body)
    skippable = cards.find { |c| c.include?("Skip for now") }
    required  = cards.find { |c| !c.include?("Skip for now") }
    assert skippable, "no skippable registration rendered"
    assert required, "no required registration rendered"

    assert_includes skippable, "contests and payouts",
                    "the chain card must keep turf's fuller subtext, not the gem's default"
    assert_includes required, "One last thing before your entry",
                    "the entry-gate card must say WHY it is asking now — that clause is what " \
                    "makes the missing Skip link read as intent rather than as a bug"

    # And the gem's shorter default must not be what shipped.
    assert_not_includes response.body,
                        "Just your first name — we use it to address you in emails.",
                        "that is studio-engine's DEFAULT subtext; this app passes its own"
  end

  test "the modal hands the remaining steps to the chain driver" do
    log_in_as users(:alex)
    get admin_modal_preview_path(modal_id: "onboarding", props: {}.to_json)
    assert_response :success
    # The modal must not know what comes after it — it reports and closes.
    assert_includes response.body, "onboarding-step-done"
  end



  # RESCUED FROM THE GALLERY, and it got stronger in the move. This pinned
  # OnboardingFlow::STEPS against MODAL_FLOWS — "a step added to the service with
  # no gallery step means a state nobody can review". The gallery is gone, but
  # the invariant is not about a showroom: it is that the CHAIN DRIVER opens a
  # modal for every step the service can resolve. That driver is the thing that
  # actually walks a user through, so pinning against it is what the original
  # test was reaching for.
  test "the chain driver opens a modal for every step OnboardingFlow resolves" do
    driver = File.read(Rails.root.join("app/views/layouts/application.html.erb"))
    expected = { first_name: "onboarding", age: "birthday", wallet: "wallet-setup" }

    assert_equal OnboardingFlow::STEPS.sort, expected.keys.sort,
                 "OnboardingFlow::STEPS changed — update this map AND the chain driver"

    expected.each do |step, modal_id|
      assert_includes driver, "open('#{modal_id}'",
                      "chain step #{step} resolves to #{modal_id}, which the layout's chain " \
                      "driver never opens — the step would strand the user"
    end
  end
end
