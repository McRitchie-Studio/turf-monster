require "test_helper"

# [component] The agent API keys card: every state it renders, and the wiring
# that lets it update in place.
class ApiKeysSectionTest < ActionView::TestCase
  setup { @user = users(:jordan) }

  def mint(name: "Claude")
    ApiKey.mint!(user: @user, name: name, geo_country: "US", geo_state: "CO", age_result: "not_required")
  end

  # ActionView::TestCase#rendered ACCUMULATES across calls, so read the return
  # value: a refute against `rendered` would be judged on the union.
  def render_section(blocked_reason: nil, **locals)
    html = render(partial: "accounts/api_keys_section",
                  locals: { user: @user, blocked_reason: blocked_reason, **locals })
    Nokogiri::HTML5.fragment(html)
  end

  def form(doc)
    doc.at_css("form[data-api-key-form]")
  end

  # --- the frame ---------------------------------------------------------------

  test "the card is one turbo frame, the id every card response answers with" do
    doc = render_section

    assert_equal 1, doc.element_children.size
    assert_equal "turbo-frame", doc.element_children.first.name
    assert_equal "api_keys_card", doc.element_children.first["id"]
  end

  # --- the list ----------------------------------------------------------------

  test "with no keys there is no list and the form is open, with no add-another link" do
    doc = render_section

    assert_nil doc.at_css("[data-api-key-list]")
    assert_nil doc.at_css("[data-api-key-add]")
    assert_match(/adding: true/, form(doc).parent["x-data"])
  end

  test "a key is listed by name and prefix, never by its secret" do
    key = mint(name: "Claude")
    html = render_section.to_html

    assert_includes html, "#{key.prefix}…"
    assert_includes html, "Claude"
    assert_includes html, "Never used"
    assert_not_includes html, key.raw_token
    assert_not_includes html, key.raw_token[ApiKey::PREFIX_LENGTH..]
    assert_not_includes html, key.token_digest
  end

  test "a revoked key is not listed and an expired one is marked" do
    revoked = mint
    revoked.revoke!
    expired = mint
    expired.update_column(:expires_at, 1.day.ago)
    doc = render_section

    assert_nil doc.at_css(%([data-api-key-row="#{revoked.id}"]))
    assert_match(/Expired/, doc.at_css(%([data-api-key-row="#{expired.id}"])).text)
  end

  test "a used key says when" do
    key = mint
    key.update_column(:last_used_at, 3.hours.ago)

    assert_match(/Last used about 3 hours ago/, render_section.text)
  end

  # --- revoke ------------------------------------------------------------------

  test "revoke DELETEs that key through the frame, behind a confirm" do
    key = mint
    revoke = render_section.at_css(%([data-api-key-row="#{key.id}"] form))

    assert_equal account_api_key_path(key), revoke["action"]
    assert_equal "delete", revoke.at_css('input[name="_method"]')["value"]
    assert revoke["data-turbo-confirm"].present?
    # Inside the frame and not opted out of Turbo: that is what makes the
    # response swap the card instead of loading a page.
    assert revoke.ancestors("turbo-frame").any?
    assert_nil revoke["data-turbo"]
    assert_nil revoke["target"]
  end

  test "the revoke button swaps to a spinner on Turbo's submit events, not on click" do
    mint
    revoke = render_section.at_css("[data-api-key-row] form")
    button = revoke.at_css("button")

    assert_match(/busy: false/, revoke["x-data"])
    assert_equal "busy = true", revoke["@turbo:submit-start"]
    assert_equal "busy = false", revoke["@turbo:submit-end"]
    assert_nil button["@click"], "a click handler would spin even when the confirm is declined"

    idle, working = button.css("> span")
    assert_equal "!busy", idle["x-show"]
    assert_equal "Revoke", idle.text.strip
    assert_equal "busy", working["x-show"]
    assert working.key?("x-cloak")
    assert working.at_css(".cta-spinner")
    assert_match(/Revoking/, working.text)
  end

  # --- the create form ---------------------------------------------------------

  test "the form posts through the frame and requires a name" do
    create = form(render_section)
    input = create.at_css('input[name="name"]')

    assert_equal account_api_keys_path, create["action"]
    assert_equal "post", create["method"]
    assert create.ancestors("turbo-frame").any?
    assert_nil create["data-turbo"]
    assert_equal "Name", create.at_css('label[for="api_key_name"]').text.strip
    assert input.key?("required")
    assert_equal ApiKey::NAME_MAX_LENGTH.to_s, input["maxlength"]
    assert_no_match(/optional|label/i, create.text)
  end

  test "the create button shows a spinner while the request runs" do
    create = form(render_section)
    idle, working = create.at_css('button[type="submit"]').css("> span")

    assert_match(/busy: false/, create.parent["x-data"])
    # Each handler now also drives the throttle message (see the 429 test
    # below), so the busy assignment is one statement of two.
    assert_equal "busy = true", create["@turbo:submit-start"].split(";").first.strip
    assert_equal "busy = false", create["@turbo:submit-end"].split(";").first.strip
    assert_equal "Create key", idle.text.strip
    assert working.at_css(".cta-spinner")
    assert_match(/Creating/, working.text)
  end

  test "with keys the form waits, closed, behind an add-another link" do
    mint
    doc = render_section
    link = doc.at_css("[data-api-key-add]")

    assert_equal "Add another API key", link.text.strip
    assert_equal "!adding", link["x-show"]
    assert_match(/adding = true/, link["@click"])
    assert_match(/adding: false/, form(doc).parent["x-data"])
    assert_equal "adding", form(doc)["x-show"]
    assert form(doc).key?("x-cloak"), "x-show owns display; cloak covers the first paint"
    # The link and the form share one Alpine scope, or the toggle cannot reach it.
    assert_equal link.parent, form(doc).parent
  end

  test "a refused submit comes back open, with the error, the typed name, and no key on screen" do
    mint
    doc = render_section(form_error: "Name can't be blank", form_name: "typed")
    error = doc.at_css("[data-api-key-error]")
    input = doc.at_css('input[name="name"]')

    assert_match(/adding: true/, form(doc).parent["x-data"])
    assert_equal "Name can't be blank", error.text
    assert_equal "alert", error["role"]
    assert_equal "true", input["aria-invalid"]
    assert_equal error["id"], input["aria-describedby"]
    assert_equal "typed", input["value"]
    assert_nil doc.at_css("[data-api-key-created]")
  end

  test "an untouched form carries no error markup" do
    doc = render_section

    assert_nil doc.at_css("[data-api-key-error]")
    assert_nil doc.at_css('input[name="name"]')["aria-invalid"]
  end

  # --- blockers ----------------------------------------------------------------

  test "each blocker replaces the form with its own explanation" do
    { impersonating: /acting as another user/, frozen: /is frozen/,
      geo: /aren't available where you are/, age: /Verify your age/ }.each do |reason, copy|
      doc = render_section(blocked_reason: reason)

      assert_nil form(doc), "#{reason} must not offer the form"
      assert_nil doc.at_css("[data-api-key-add]"), "#{reason} must not offer add-another"
      assert_match copy, doc.at_css(%([data-api-key-blocked="#{reason}"])).text
    end
  end

  test "the age blocker opens the birthday card and re-fetches the frame when it reports success" do
    blocked = render_section(blocked_reason: :age).at_css('[data-api-key-blocked="age"]')
    handler = blocked["@age-verified.window"]

    assert_includes blocked.at_css("button")["@click"], "open('birthday'"
    assert blocked.key?("x-data"), "without a component the listener is never bound"
    assert_includes handler, "closest('turbo-frame')"
    assert_includes handler, account_api_keys_path
    assert_no_match(/location|Turbo\.visit/, handler, "the card updates in place; the page does not reload")
  end

  test "a blocked player still sees and can revoke the keys they hold" do
    key = mint

    assert render_section(blocked_reason: :geo).at_css(%([data-api-key-row="#{key.id}"] form))
  end

  test "at the cap the form gives way to an explanation" do
    ApiKey::MAX_ACTIVE_PER_USER.times { mint }
    doc = render_section

    assert_nil form(doc)
    assert_nil doc.at_css("[data-api-key-add]")
    assert doc.at_css('[data-api-key-blocked="limit"]')
  end

  # --- the one-time reveal -----------------------------------------------------

  test "a new key is printed once and handed to the engine copy button, with a ready curl line" do
    key = mint
    doc = render_section(new_key: key)
    created = doc.at_css("[data-api-key-created]")
    secret = created.at_css("[data-api-key-secret]")

    assert_equal key.raw_token, secret.at_css("[data-api-key-value]").text
    assert_equal key.raw_token, secret.at_css("button[data-copy-text]")["data-copy-text"]
    # A 44-character key has to wrap on a phone, in an element of its own, or it
    # pushes the Copy button off screen.
    assert_includes secret.at_css("[data-api-key-value]")["class"].split, "break-all"

    curl = created.at_css("[data-api-key-curl] button[data-copy-text]")["data-copy-text"]
    assert_equal %(curl -H "Authorization: Bearer #{key.raw_token}" http://test.host/api/v1/me), curl
    # The full key is printed exactly once; everything else shows the prefix.
    assert_equal 1, created.css("code").count { |code| code.text.include?(key.raw_token) }
    assert_includes created.at_css("[data-api-key-curl] code").text, "Bearer #{key.prefix}…"
  end

  test "while a new key is on screen the list shows it and no form competes" do
    key = mint
    doc = render_section(new_key: key)

    assert doc.at_css(%([data-api-key-row="#{key.id}"]))
    assert_nil form(doc)
    assert_nil doc.at_css("[data-api-key-add]")
    # The way on for a card restored without its reveal: outside the temporary
    # block, hidden while the reveal is in the frame, a frame navigation.
    after = doc.at_css("[data-api-key-add-after-reveal]")
    assert_nil after.ancestors.find { |node| node.key?("data-turbo-temporary") }
    assert after.key?("x-cloak")
    assert_equal "!revealed", after["x-show"]
    assert_match(/revealed: true/, after["x-data"])
    assert_includes after["x-init"], "querySelector('[data-api-key-created]')"
    link = after.at_css("a")
    assert_equal "Add another API key", link.text
    assert_equal account_api_keys_path(adding: 1), link["href"]
    assert_nil link["data-turbo-frame"], "it must stay inside the card's frame"
    # Dismissing is a frame navigation back to the plain card.
    done = doc.at_css("[data-api-key-created] a.btn")
    assert_equal account_api_keys_path, done["href"]
    assert_nil done["data-turbo-frame"]
  end

  # Turbo snapshots the page on the way out and Back restores the snapshot
  # without a request. It drops data-turbo-temporary elements first, so the
  # attribute has to sit on an element that CONTAINS every copy of the raw key.
  test "the reveal is temporary to Turbo, and nothing outside it carries the key" do
    key = mint
    doc = render_section(new_key: key)
    created = doc.at_css("[data-api-key-created]")

    assert created.key?("data-turbo-temporary")
    created.remove
    assert_not_includes doc.to_html, key.raw_token
    # What the snapshot keeps: the card and the key's row.
    assert doc.at_css(%(turbo-frame#api_keys_card [data-api-key-row="#{key.id}"]))
  end

  # --- refusals said in the card ---------------------------------------------------

  test "a card error is announced inside the frame, above the list" do
    key = mint
    doc = render_section(card_error: "We couldn't revoke that key. Please try again.")
    error = doc.at_css("turbo-frame#api_keys_card [data-api-key-card-error]")

    assert_equal "alert", error["role"]
    assert_equal "We couldn't revoke that key. Please try again.", error.text
    assert doc.at_css(%([data-api-key-row="#{key.id}"])), "the keys are still listed under it"
    assert form(doc), "and the card still offers its form"
  end

  test "with no card error there is no error markup" do
    assert_nil render_section.at_css("[data-api-key-card-error]")
  end

  # rack-attack answers a throttled mint in JSON before any controller runs, so
  # there is no card to swap in: the form reads the status and says so itself.
  test "the form reads a 429 off the response and has a message waiting for it" do
    doc = render_section
    message = form(doc).at_css("[data-api-key-throttled]")

    assert_match(/throttled: false/, form(doc).parent["x-data"])
    assert_equal "throttled", message["x-show"]
    assert message.key?("x-cloak"), "hidden until Alpine says otherwise"
    assert_equal "alert", message["role"]
    assert_match(/too many keys/i, message.text)
    assert_match(/throttled = false/, form(doc)["@turbo:submit-start"])
    assert_match(/throttled = \$event\.detail\.fetchResponse\?\.response\.status === 429/,
                 form(doc)["@turbo:submit-end"])
    assert_match(/busy = false/, form(doc)["@turbo:submit-end"])
  end

  test "outside the reveal there is no after-reveal link" do
    mint

    assert_nil render_section.at_css("[data-api-key-add-after-reveal]")
  end

  test "form_open renders the form open although keys exist" do
    mint

    assert_match(/adding: false/, form(render_section).parent["x-data"])
    assert_match(/adding: true/, form(render_section(form_open: true)).parent["x-data"])
  end

  test "the name error stands down while the throttle message is up" do
    doc = render_section(form_error: "Name can't be blank", form_name: " ")

    assert_equal "!throttled", doc.at_css("[data-api-key-error]")["x-show"]
  end

  test "a key reloaded from the database reveals nothing" do
    key = mint
    doc = render_section(new_key: ApiKey.find(key.id))

    assert_nil doc.at_css("[data-api-key-created]")
    assert_not_includes doc.to_html, key.raw_token
  end
end
