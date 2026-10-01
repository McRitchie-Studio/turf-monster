require "test_helper"

# [component] The agent API keys card on /account, and the page that shows a
# new key once.
class ApiKeysSectionTest < ActionView::TestCase
  setup { @user = users(:jordan) }

  def mint(**attrs)
    ApiKey.mint!(user: @user, geo_country: "US", geo_state: "CO", age_result: "not_required", **attrs)
  end

  # ActionView::TestCase#rendered ACCUMULATES across calls, so read the return
  # value: a refute against `rendered` would be judged on the union.
  def render_section(blocked_reason: nil)
    html = render(partial: "accounts/api_keys_section", locals: { user: @user, blocked_reason: blocked_reason })
    Nokogiri::HTML5.fragment(html)
  end

  # --- the list ----------------------------------------------------------------

  test "with no keys there is no list, only the form" do
    doc = render_section

    assert_nil doc.at_css("[data-api-key-list]")
    assert doc.at_css("form[data-api-key-form]")
  end

  test "a key is listed by prefix and label, never by its secret" do
    key = mint(name: "Claude")
    html = render_section.to_html

    assert_includes html, "#{key.prefix}…"
    assert_includes html, "Claude"
    assert_includes html, "Never used"
    assert_not_includes html, key.raw_token
    assert_not_includes html, key.raw_token[ApiKey::PREFIX_LENGTH..]
    assert_not_includes html, key.token_digest
  end

  test "each listed key has a revoke control that DELETEs that key, behind a confirm" do
    key = mint
    row = render_section.at_css(%([data-api-key-row="#{key.id}"]))
    form = row.at_css("form")

    assert_equal account_api_key_path(key), form["action"]
    assert_equal "delete", form.at_css('input[name="_method"]')["value"]
    assert form["data-turbo-confirm"].present?
    assert_equal "Revoke", form.at_css("button").text.strip
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

  # --- the mint form -----------------------------------------------------------

  test "the mint form posts to the mint route as a full page load" do
    form = render_section.at_css("form[data-api-key-form]")

    assert_equal account_api_keys_path, form["action"]
    assert_equal "post", form["method"]
    # Turbo will not render a non-redirect success for a form submission, and
    # the response to this POST is the page that shows the key.
    assert_equal "false", form["data-turbo"]
    assert_equal ApiKey::NAME_MAX_LENGTH.to_s, form.at_css('input[name="name"]')["maxlength"]
  end

  test "each blocker replaces the form with its own explanation" do
    { frozen: /on hold/, geo: /aren't available where you are/, age: /Verify your age/ }.each do |reason, copy|
      doc = render_section(blocked_reason: reason)

      assert_nil doc.at_css("form[data-api-key-form]"), "#{reason} must not offer the form"
      assert_match copy, doc.at_css(%([data-api-key-blocked="#{reason}"])).text
    end
  end

  test "the age blocker offers the birthday modal" do
    button = render_section(blocked_reason: :age).at_css('[data-api-key-blocked="age"] button')

    assert_includes button["@click"], "open('birthday'"
  end

  test "a blocked player still sees and can revoke the keys they hold" do
    key = mint

    assert render_section(blocked_reason: :geo).at_css(%([data-api-key-row="#{key.id}"] form))
  end

  test "at the cap the form gives way to an explanation" do
    ApiKey::MAX_ACTIVE_PER_USER.times { mint }
    doc = render_section

    assert_nil doc.at_css("form[data-api-key-form]")
    assert doc.at_css('[data-api-key-blocked="limit"]')
  end

  # --- the reveal page ---------------------------------------------------------

  test "the reveal page hands the raw key to the engine copy button and a ready curl line" do
    @api_key = mint
    html = render(template: "api_keys/create")
    doc = Nokogiri::HTML5.fragment(html)

    secret = doc.at_css("[data-api-key-secret]")
    assert_equal @api_key.raw_token, secret.at_css("button[data-copy-text]")["data-copy-text"]
    assert_equal @api_key.raw_token, secret.at_css("code").text

    curl = doc.css("button[data-copy-text]").map { |b| b["data-copy-text"] }.find { |t| t.start_with?("curl") }
    assert_includes curl, %(Authorization: Bearer #{@api_key.raw_token})
    assert curl.end_with?("/api/v1/me")
    assert_equal account_path, doc.at_css("[data-api-key-created] a.btn")["href"]
  end
end
