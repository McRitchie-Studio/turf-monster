require "test_helper"
require "minitest/mock"

# [integration] The account and wallet controls that left Alpine: each renders
# its controller's hooks and its initial state in the markup, and no Alpine
# inside the converted region except the buttons that open an engine modal
# through $store.modals, which stays the engine's. Every controller here is
# static (registered in turf_stimulus.js and preloaded), so its markup is
# pressable from first paint; these tests pin the safe state it starts in.
# The API keys card is pinned in test/views/api_keys_section_test.rb.
class EntryStimulusPagesTest < ActionDispatch::IntegrationTest
  ALPINE = /\A(?:x-|@|:)/
  # An engine modal opener: still Alpine, bound to the engine's $store.modals.
  MODAL_OPENER = /\A\$store\.modals\.open\(/

  setup do
    @user = users(:alex)
    log_in_as(@user)
  end

  # HTML5: the HTML4 parser drops an attribute named @click, which would blind
  # assert_no_alpine to the shorthand.
  def page = Nokogiri::HTML5(response.body)

  def root_for(identifier)
    assert_response :success
    page.at_css(%([data-controller~="#{identifier}"])).tap { |root| assert root, "no #{identifier} controller on the page" }
  end

  def assert_no_alpine(root)
    carriers = [ root, *root.css("*") ].select do |node|
      node.attribute_nodes.any? { |attribute| attribute.name.match?(ALPINE) && !(attribute.name == "@click" && attribute.value.match?(MODAL_OPENER)) }
    end
    assert_empty carriers.map { |node| node.to_html[0, 120] }
    assert_empty root.css("script").reject { |script| script["type"] == "application/json" }
    assert_empty [ root, *root.css("*") ].flat_map(&:attribute_nodes).map(&:name).grep(/\Aon[a-z]+\z/)
  end

  def resets_before_cache(root, identifier)
    assert_includes root["data-action"], "turbo:before-cache@document->#{identifier}#reset"
  end

  test "the referral card starts with its popover closed and its button at rest" do
    get account_path
    root = root_for("referral-share")

    assert_no_alpine root
    resets_before_cache(root, "referral-share")
    assert_includes root["data-action"], "click@window->referral-share#outside"
    assert_includes root["data-action"], "keydown.esc@window->referral-share#closeInfo"
    url = root["data-referral-share-url-value"]
    assert_match %r{\Ahttps?://}, url
    assert_equal url, root.at_css('[data-action="click->referral-share#copy"]').text.strip

    popover = root.at_css('[data-referral-share-target="popover"]')
    assert popover.key?("hidden")
    assert_equal "transition ease-out duration-150", popover["data-enter"]
    assert_equal "opacity-0", popover["data-leave-end"]
    button = root.at_css('[data-referral-share-target="button"]')
    assert_equal "referral-share#copy", button["data-action"]
    assert_includes button["class"].split, "btn-primary"
    assert_nil root.at_css('[data-referral-share-target="copyLabel"]')["hidden"]
    assert root.at_css('[data-referral-share-target="copiedLabel"]').key?("hidden")
    assert_equal "referral-share#toggleInfo", root.at_css('[data-referral-share-target="toggle"]')["data-action"]
  end

  test "the newsletter card shows the state the server knows, the other hidden" do
    [ false, true ].each do |subscribed|
      @user.update_columns(joined_email_list_at: subscribed ? 1.day.ago : nil, left_email_list_at: nil)
      get account_path
      root = root_for("newsletter-state")
      known = @user.reload.subscribed_to_newsletter?
      assert_equal subscribed, known

      assert_no_alpine root
      resets_before_cache(root, "newsletter-state")
      assert_includes root["data-action"], "newsletter-state-changed@window->newsletter-state#update"
      assert_equal known.to_s, root["data-newsletter-state-subscribed-value"]
      assert_equal !known, root.at_css('[data-newsletter-state-target="subscribed"]').key?("hidden")
      assert_equal known, root.at_css('[data-newsletter-state-target="unsubscribed"]').key?("hidden")
      openers = root.css("button").map { |button| button["@click"] }
      assert_equal [ "$store.modals.open('unsubscribe-confirm')", "$store.modals.open('newsletter-subscribe')" ], openers
    end
  end

  test "the email field's change notice starts hidden and knows the address on the account" do
    get account_path
    root = root_for("email-change-notice")

    assert_no_alpine root
    resets_before_cache(root, "email-change-notice")
    assert_equal @user.email, root["data-email-change-notice-initial-value"]
    field = root.at_css('input[data-email-change-notice-target="field"]')
    assert_equal "email-change-notice#check", field["data-action"]
    assert_equal @user.email, field["value"]
    assert root.at_css('[data-email-change-notice-target="notice"]').key?("hidden")
  end

  test "the API keys card carries no Alpine but its engine modal opener" do
    get account_path
    assert_response :success

    assert_no_alpine page.at_css("turbo-frame#api_keys_card")
  end

  test "the withdraw card starts closed with its submit disabled, and the balance starts drawn" do
    managed = User.create!(name: "Cash Out Cathy", username: "co-#{SecureRandom.hex(2)}",
                           email: "co-#{SecureRandom.hex(2)}@example.test", email_verified_at: Time.current)
    grant_managed_wallet!(managed)
    log_in_as(managed)
    vault = Object.new
    vault.define_singleton_method(:sync_balance) { |_addr| { balance: 50_000_000, balance_dollars: BigDecimal("50") } }
    Solana::Vault.stub(:new, vault) { get wallet_path }

    card = root_for("withdraw-card")
    assert_no_alpine card
    resets_before_cache(card, "withdraw-card")
    assert_equal "cash-out", card["id"]
    assert_equal "false", card["data-withdraw-card-frozen-value"]
    assert_equal "Withdraw", card.at_css('[data-withdraw-card-target="toggle"]').text.strip
    assert_equal "withdraw-card#toggle", card.at_css('[data-withdraw-card-target="toggle"]')["data-action"]
    panel = card.at_css('[data-withdraw-card-target="panel"]')
    assert panel.key?("hidden")
    assert_equal "transition ease-in-out duration-150", panel["data-enter"]
    assert card.at_css('[data-withdraw-card-target="submit"]').key?("disabled")
    %w[amount destination].each do |field|
      assert_equal "withdraw-card#validate", card.at_css(%([data-withdraw-card-target="#{field}"]))["data-action"]
    end
    assert_equal withdraw_wallet_path, card.at_css("form")["action"]

    balance = root_for("usdc-balance")
    assert_no_alpine balance
    assert_equal admin_usdc_balance_path, balance["data-usdc-balance-url-value"]
    assert_match(/\A\d+\.\d{2}\z/, balance.at_css('[data-usdc-balance-target="amount"]').text.strip)
  end

  test "a frozen account's withdraw card has no toggle and never opens" do
    managed = User.create!(name: "Frozen Fran", username: "ff-#{SecureRandom.hex(2)}",
                           email: "ff-#{SecureRandom.hex(2)}@example.test", email_verified_at: Time.current)
    grant_managed_wallet!(managed)
    managed.freeze_for_payment_risk!(reason: "test")
    log_in_as(managed)
    vault = Object.new
    vault.define_singleton_method(:sync_balance) { |_addr| { balance: 0, balance_dollars: BigDecimal("0") } }
    Solana::Vault.stub(:new, vault) { get wallet_path }

    card = root_for("withdraw-card")
    assert_equal "true", card["data-withdraw-card-frozen-value"]
    assert_nil card.at_css('[data-withdraw-card-target="toggle"]')
    assert card.at_css('[data-withdraw-card-target="panel"]').key?("hidden")
  end
end
