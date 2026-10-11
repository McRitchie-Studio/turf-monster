require "test_helper"

# [integration] The landed-entry prompt end to end over HTTP: a paid entry an
# app gate refused is asked about at the player's next login, the player's two
# answers, and the operator's replace. LedgerVault is the chain: one ticket
# means nothing was paid again.
class LandedEntryPromptTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport
  include ActiveJob::TestHelper

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @admin = users(:alex)
    [@admin, @user].each { |u| u.update_column(:slug, u.send(:name_slug)) }
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    @entry = @contest.entries.create!(user: @user, status: :cart)
    fixture_matchups.each { |matchup| @entry.selections.create!(slate_matchup: matchup) }
    land!
  end

  def chain(&block) = on_chain(@vault, &block)
  def prompt = css_select("[data-landed-entry-prompt='#{@entry.slug}']")

  # Paid on chain, then the contest filled before the app could activate it.
  def land!
    @vault.fail_next_enter = :lost
    @vault.chain_unreadable = true
    assert_raises(Entries::ManagedEntry::PendingConfirmation) do
      chain { Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: true).call(@entry) }
    end
    @contest.update!(max_entries: 1)
    enter!(users(:jordan), @contest, fixture_matchups)
    @vault.chain_unreadable = false
    assert chain { Entries::PaymentSettlement.call(@entry, vault: @vault) }.landed?
  end

  test "a landed row renders the prompt on login, with the reason, the deadline and both answers" do
    log_in_as @user
    follow_redirect! while response.redirect?

    assert_equal 1, prompt.size
    assert_includes prompt.text, @contest.name
    assert_includes prompt.text, "the contest filled before we could finish your entry"
    assert_includes prompt.text, "You will not be charged again"
    assert_select "[data-landed-entry-deadline]", text: @entry.landed_hold_expires_at.in_time_zone("America/New_York").strftime("%a, %b %-d at %-l:%M %p ET")
    assert_select "form[action='#{reauthorize_landed_entry_path(@entry.slug)}'] button", text: "Yes, keep my entry"
    assert_select "form[action='#{decline_landed_entry_path(@entry.slug)}'] button", text: "No, I don't want it"
  end

  test "CONTROL: no prompt for another player, after the hold, or once answered" do
    log_in_as users(:jordan)
    get root_path
    assert_empty prompt

    log_in_as @user
    travel_to(@entry.reload.landed_hold_expires_at) { get root_path }
    assert_empty prompt, "the hold is over: the operator has it now"

    @entry.answer_landed!("declined")
    get root_path
    assert_empty prompt
  end

  test "re-authorize activates the entry from its own ticket, and the prompt is gone" do
    log_in_as @user
    chain { post reauthorize_landed_entry_path(@entry.slug), headers: { "HTTP_REFERER" => root_url } }

    assert_response :see_other
    assert_equal %w[active confirmed reauthorized], @entry.reload.values_at(:status, :payment_state, :landed_answer)
    assert_equal 1, @vault.tickets.size, "nothing was paid again"
    assert_match(/\AYou're in\. .*not charged again\.\z/, flash[:notice])
    get root_path
    follow_redirect! while response.redirect?
    assert_empty prompt
  end

  test "decline keeps the row held for a person, and nothing moves" do
    log_in_as @user
    chain { post decline_landed_entry_path(@entry.slug) }

    assert_response :see_other
    assert_equal %w[cart landed declined], @entry.reload.values_at(:status, :payment_state, :landed_answer)
    assert_equal 1, @vault.tickets.size
  end

  test "a player cannot answer for another player's entry" do
    log_in_as users(:jordan)
    chain { post reauthorize_landed_entry_path(@entry.slug) }

    assert_response :see_other
    assert_nil @entry.reload.landed_answer
  end

  test "an admin impersonating the player sees no prompt and cannot answer" do
    log_in_as @admin
    post admin_impersonate_path(@user.slug)
    get root_path
    assert_empty prompt

    chain { post reauthorize_landed_entry_path(@entry.slug) }
    assert_nil @entry.reload.landed_answer
  end

  test "the operator's replace is refused inside the hold and activates the row after it" do
    log_in_as @admin
    get admin_landed_entries_path
    assert_select "[data-landed-entry-row='#{@entry.slug}']", text: /in hold/

    chain { post admin_replace_landed_entry_path(@entry.slug) }
    assert_equal "landed", @entry.reload.payment_state

    travel_to(@entry.landed_hold_expires_at + 1.minute) do
      get admin_landed_entries_path
      assert_select "[data-landed-entry-row='#{@entry.slug}'] form[action='#{admin_replace_landed_entry_path(@entry.slug)}']"
      chain { post admin_replace_landed_entry_path(@entry.slug) }
    end

    assert_equal %w[active confirmed], @entry.reload.values_at(:status, :payment_state)
    assert_equal @admin.id, @entry.landed_replaced_by_id
    assert_equal 1, @vault.tickets.size
  end

  test "a player is not an operator" do
    log_in_as @user
    travel_to(@entry.landed_hold_expires_at + 1.minute) { chain { post admin_replace_landed_entry_path(@entry.slug) } }

    assert_equal "landed", @entry.reload.payment_state
  end
end
