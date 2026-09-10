require "test_helper"

# The burn controls on the /admin/free_entries row.
#
# These are the only DESTRUCTIVE buttons on the page, so what they must get right
# is not "do they appear" but WHEN they appear and what they claim. Three rules,
# each with a way to get it wrong that renders perfectly fine:
#
#   1. They key off UNCONSUMED, not `owed`. Those point in opposite directions —
#      owed is what we still have to give, unconsumed is what we can still take
#      back — so a row can legitimately show Mint and Burn together, and keying
#      burn off `owed` would offer a claw-back on a user holding nothing.
#   2. They stay hidden on a COLD cache, for the same reason Mint does: the
#      counts are unverified, and this button destroys property.
#   3. The row's "nothing actionable" dash must not render beside them. It used
#      to key off `owed <= 0` alone, which was true before burn existed and is a
#      visible contradiction now.
#
# The test env runs :null_store (reads always nil), so a cache-first row would be
# permanently "loading" and rules 1 and 3 could never render. Each test injects a
# real MemoryStore and writes the key the controller reads — the pattern from
# free_entries_render_no_rpc_test.
class AdminFreeEntriesBurnButtonsTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)
    @holder = users(:sam)
    @holder.update_columns(seeds: 250, slug: "sam-burn-view")
  end

  def tokens_key
    Solana::Vault.entry_tokens_cache_key(@holder.solana_address)
  end

  # Renders the page with the holder's on-chain token list pre-warmed. `minted`
  # is the TOTAL on chain (what `owed` subtracts) and `unconsumed` how many of
  # those are still spendable (what burn offers).
  def render_row(minted:, unconsumed:, seeds: 250)
    @holder.update_columns(seeds: seeds)
    store = ActiveSupport::Cache::MemoryStore.new
    tokens = Array.new(minted) { |i| { consumed: i >= unconsumed, source: 0, created_at: 1_000 + i } }

    Rails.stub :cache, store do
      store.write(tokens_key, tokens)
      log_in_as(@admin)
      get admin_free_entries_path
    end
    assert_response :success
  end

  test "a holder with spendable tokens gets Burn 1 and Burn all" do
    render_row(minted: 3, unconsumed: 3)

    assert_match(/Burn 1/, response.body)
    assert_match(/Burn all 3/, response.body,
      "Burn all must name the count it will destroy — an unlabelled 'Burn all' " \
      "gives the operator nothing to check the confirm dialog against")
    assert_select "form[action=?]", admin_burn_free_entries_path(user_slug: @holder.slug, count: 1)
  end

  # ── The confirm attribute, pinned at THIS tier ──────────────────────────
  #
  # Deleting the whole `data:` hash from both burn buttons used to leave every
  # test in this file green: the confirm on the app's only irreversible action
  # was pinned ONLY by the e2e lane, so a red or skipped lane silently un-pinned
  # it. The browser still owns whether Turbo INTERCEPTS the submit
  # (e2e/admin_free_entry_burn_confirm.spec.js); this owns whether the attribute
  # is rendered at all, which is the half a string can see.
  test "both burn buttons render a turbo-confirm naming the irreversibility" do
    render_row(minted: 3, unconsumed: 3)

    confirms = css_select("form[action*='/burn'] button[data-turbo-confirm]")
      .map { |b| b["data-turbo-confirm"] }
    assert_equal 2, confirms.length,
      "Burn 1 and Burn all must EACH carry data-turbo-confirm — one unguarded " \
      "button is one click from an irreversible burn"
    assert confirms.all? { |c| c.match?(/cannot be undone/i) },
      "every burn confirm must say the action cannot be undone: #{confirms.inspect}"
  end

  test "the Burn all confirm and its submitted count are the SAME number" do
    render_row(minted: 4, unconsumed: 3)

    # Interpolated, not `?`-substituted: that substitution is an assert_select
    # feature, and css_select would read a second argument as the ROOT node.
    path = admin_burn_free_entries_path(user_slug: @holder.slug, count: 3)
    form = css_select("form[action='#{path}']").first
    assert form,
      "Burn all must POST the count it displays — sending none lets the controller " \
      "fall through to the LIVE count and destroy more than the operator agreed to"

    confirm = form.css("button[data-turbo-confirm]").first["data-turbo-confirm"]
    assert_match(/ALL 3/, confirm,
      "the confirmed number and the submitted count must not be able to disagree")
  end

  test "a single spendable token gets Burn 1 only" do
    render_row(minted: 1, unconsumed: 1)

    assert_match(/Burn 1/, response.body)
    refute_match(/Burn all/, response.body,
      "'Burn all 1' beside 'Burn 1' is two buttons for one action")
  end

  test "a holder whose tokens are all spent gets no burn control" do
    render_row(minted: 2, unconsumed: 0)

    refute_match(/Burn/, response.body,
      "every token is already redeemed — there is nothing left to claw back")
  end

  test "burn is offered on unconsumed even when nothing is owed" do
    # 250 seeds = 2 levels earned, 3 tokens already minted → owed 0. The user
    # still holds 3 spendable tokens. Keying burn off `owed` would hide the
    # control on exactly the row an operator over-granted.
    render_row(minted: 3, unconsumed: 3, seeds: 250)

    refute_match(/Mint \d/, response.body, "nothing is owed, so Mint must be absent")
    assert_match(/Burn all 3/, response.body,
      "burn keys off what the user HOLDS, not off what we still owe them")
  end

  test "a cold cache offers no burn control" do
    store = ActiveSupport::Cache::MemoryStore.new # never written → cold
    Rails.stub :cache, store do
      log_in_as(@admin)
      get admin_free_entries_path
    end

    assert_response :success
    assert_match(/syncing…/, response.body)
    refute_match(/Burn/, response.body,
      "never aim an irreversible action at a count that has not been verified")
  end

  test "the nothing-actionable dash never renders beside a live burn button" do
    # The dash means "this row has no buttons". Admins get no "Act as", so before
    # burn existed `owed <= 0` really did imply an empty cell. An admin holding
    # spendable tokens now breaks that implication.
    # The admin fixture carries no wallet, and users_with_wallet only lists
    # rows that have one — so without this the row never renders and the
    # assertion below would skip, proving nothing about the contradiction it
    # exists to catch.
    admin_holder = @admin
    admin_holder.update_columns(seeds: 250, slug: "alex-burn-view",
                                web3_solana_address: "7BgBvyjrZX1YKz4oh9mjb8ZScatkkwb8DzFx7LoiVkM3")
    assert admin_holder.reload.solana_address.present?
    assert admin_holder.admin?, "the dash only renders for admins — a non-admin gets Act as"
    key = Solana::Vault.entry_tokens_cache_key(admin_holder.solana_address)

    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      store.write(key, [{ consumed: false, source: 0, created_at: 1 },
                        { consumed: false, source: 0, created_at: 2 },
                        { consumed: false, source: 0, created_at: 3 }])
      log_in_as(@admin)
      get admin_free_entries_path
    end

    assert_response :success
    row = css_select("tr").find { |tr| tr.to_s.include?("Burn 1") }
    assert row, "the admin's own row should offer a burn — it holds spendable tokens"
    refute_includes row.to_s, "—",
      "the dash claims the row has nothing to do while a Burn button sits beside it"
  end
end
