# frozen_string_literal: true

require "test_helper"

# [component] The gear sidebar's LEAD LINE.
#
# The panel used to lead with "Settings" (or "Admin Menu" for an admin) — a
# label naming the thing the reader is already looking at. It now leads with a
# status line in a fixed priority:
#
#   1. a free entry on the wallet -> the free-entry badge
#   2. else an open quest         -> "Quest: Send a Message"
#   3. else                       -> the username alone
#
# WHAT MAKES THIS WORTH PINNING RATHER THAN EYEBALLING. The priority is the
# spec, and it is split across TWO clocks, which is exactly the arrangement that
# looks right in a screenshot and is wrong in the one state that matters. Rungs
# 2 and 3 are decided server-side in one expression, so at most one can paint.
# Rung 1 outranks them CLIENT-side, through the entryTokenBadge scope, because a
# mint arrives on a window event rather than a reload. So a token holder who
# also has an open quest is the case a naive implementation gets wrong: the
# server renders the quest line, and only the pre-set display:none keeps it from
# painting underneath the badge that outranks it.
#
# CACHE STORE. The test env runs :null_store (reads always nil), so the
# cache-first display_entry_token_count would be permanently "loading" and the
# free-entry rung could never render. Each render injects a real, COLD
# MemoryStore and writes the same key the controller reads — the injected-store
# pattern from entry_token_badge_placement_test.rb.
class GearSidebarStatusTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:sam) # web3_solana_address fixture -> solana_connected?
  end

  # Park the user at a quest rung by writing the timestamp columns User#next_quest
  # derives from. The ladder is join -> username -> chat -> newsletter -> invite.
  QUEST_STATE = {
    join:       { contest_entered: false },
    username:   { contest_entered: true },
    chat:       { contest_entered: true, username_changed_at: -> { Time.current } },
    newsletter: { contest_entered: true, username_changed_at: -> { Time.current },
                  first_chat_message_at: -> { Time.current } },
    invite:     { contest_entered: true, username_changed_at: -> { Time.current },
                  first_chat_message_at: -> { Time.current },
                  joined_email_list_at: -> { Time.current }, left_email_list_at: nil }
  }.freeze

  # Renders the contests index with the entry-token cache pre-warmed to `tokens`
  # and the user parked on `quest`. Yields the response body.
  def render_sidebar(tokens:, quest:)
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      log_in_as_onchain(@user) # rewrites web3_solana_address; read it back after
      attrs = QUEST_STATE.fetch(quest).transform_values { |v| v.respond_to?(:call) ? v.call : v }
      @user.update!(attrs)
      assert_equal quest, @user.reload.next_quest,
        "the fixture did not land on the :#{quest} rung — the ladder moved under this test"
      store.write(
        Solana::Vault.entry_tokens_cache_key(@user.web3_solana_address),
        Array.new(tokens) { { consumed: false } }
      )
      get contests_path
      assert_response :success
      yield response.body
    end
  end

  # The status line renders into BOTH panels (desktop + mobile), so every
  # element below appears twice. Slice the FIRST one and read it as the pair.
  def status_block(body)
    at = body.index('data-gear-status="true"')
    assert at, "the gear sidebar must lead with a status line"
    body[at, 1400]
  end

  def hidden?(block, marker)
    at = block.index(marker)
    assert at, "expected #{marker} in the status line"
    # The server pre-sets display:none on the rung that does not match the
    # load-time count, so neither half flashes before Alpine boots. The style
    # rides the same element as the marker, ahead of the data attribute.
    block[[at - 220, 0].max...at].include?('style="display: none;"')
  end

  # ── RUNG 1: a free entry on the wallet ──────────────────────────────────
  test "[component] a free entry on the wallet leads the panel" do
    render_sidebar(tokens: 2, quest: :invite) do |body|
      block = status_block(body)

      assert_includes block, 'data-free-entry-chip="true"'
      assert_includes block, "legendary-badge", "the badge keeps the house prize treatment"
      assert_includes block, 'x-data="entryTokenBadge({ initialCount: 2 })"'
      assert_includes block, "count === 1 ? 'Free Entry' : 'Free Entries'",
        "'2 Free Entrys' is what a bare plural suffix would have produced"
      refute hidden?(block, 'data-free-entry-chip="true"'),
        "a token holder's badge must not be pre-hidden"
      assert hidden?(block, 'data-gear-status-fallback="true"'),
        "the lower rungs must be pre-hidden while the badge holds the line"
    end
  end

  # ── RUNG 2: an open quest ───────────────────────────────────────────────
  test "[component] an open quest leads the panel when there is no free entry" do
    render_sidebar(tokens: 0, quest: :chat) do |body|
      block = status_block(body)

      assert_includes block, 'data-gear-status-quest="true"'
      assert_includes block, "Quest: Send a Message"
      refute_includes block, 'data-gear-status-name="true"',
        "the username must not render beside an open quest — it is the rung BELOW it"
      assert hidden?(block, 'data-free-entry-chip="true"'),
        "without the server pre-set there is a pre-Alpine flash of a badge promising nothing"
      refute hidden?(block, 'data-gear-status-fallback="true"')
    end
  end

  test "[component] the quest line is actionable, carrying the dropped row's destination" do
    render_sidebar(tokens: 0, quest: :chat) do |body|
      block = status_block(body)
      quest = block[block.index('data-gear-status-quest="true"') - 400, 700]

      assert_match(/<a [^>]*href="[^"]+"/, quest,
        "the 'Send a message' ROW was dropped because this line carries it; " \
        "inert text would lose the affordance rather than move it")
    end
  end

  test "[component] the username quest opens the modal the dropped row opened" do
    render_sidebar(tokens: 0, quest: :username) do |body|
      block = status_block(body)

      assert_includes block, "Quest: Customize Username"
      assert_includes block, "$store.modals.open('username')"
    end
  end

  # ── RUNG 3: the username alone ──────────────────────────────────────────
  #
  # THIS RUNG ONLY EXISTS BECAUSE :invite IS EXCLUDED. User#next_quest never
  # returns nil — it rests on :invite, which the model documents as "terminal,
  # ongoing". A status line keyed on "next_quest is truthy" would make this
  # branch dead code for every account that finished the ladder, which is the
  # whole population the operator asked to show a username to.
  test "[component] a finished ladder and no free entry leaves the username alone" do
    render_sidebar(tokens: 0, quest: :invite) do |body|
      block = status_block(body)

      assert_includes block, 'data-gear-status-name="true"'
      assert_includes block, @user.display_name
      refute_includes block, "Quest:",
        ":invite is terminal and ongoing — it is not an open quest to nudge"
      refute_includes block, 'data-gear-status-quest="true"'
    end
  end

  test "[component] :invite is deliberately absent from the quest label map" do
    # Stated as a property of the map rather than only through a render, so the
    # reason survives someone "completing" the hash for tidiness.
    assert_nil ApplicationHelper::GEAR_QUEST_LABELS[:invite],
      "adding :invite here makes the username rung unreachable"
    assert_equal %i[join username chat newsletter],
      ApplicationHelper::GEAR_QUEST_LABELS.keys,
      "the four COMPLETABLE rungs of User#next_quest, and only those"
  end

  # ── THE PRECEDENCE ITSELF ───────────────────────────────────────────────
  test "[component] a free entry outranks an open quest when both are true" do
    render_sidebar(tokens: 1, quest: :chat) do |body|
      block = status_block(body)

      # BOTH are in the markup — that is the design, not a bug: the badge rung
      # is decided client-side so it can promote itself on a mint. What must
      # hold is which one PAINTS at load.
      assert_includes block, 'data-free-entry-chip="true"'
      assert_includes block, "Quest: Send a Message"

      refute hidden?(block, 'data-free-entry-chip="true"'),
        "the free entry outranks the quest — the badge is what paints"
      assert hidden?(block, 'data-gear-status-fallback="true"'),
        "INVERT THE PRECEDENCE AND THIS IS THE ASSERTION THAT REDDENS: with the " \
        "two pre-set styles swapped the quest line paints over the badge"
    end
  end

  test "[component] the two rungs are exact complements, so neither can double-paint" do
    render_sidebar(tokens: 0, quest: :chat) do |body|
      block = status_block(body)

      assert_includes block, 'x-show="count > 0"'
      assert_includes block, 'x-show="!(count > 0)"',
        "the lower rungs must be the EXACT complement of the badge's condition — " \
        'a hand-written "count === 0" drifts on any non-integer the event delivers'
    end
  end

  test "[component] both panels carry their own status scope" do
    render_sidebar(tokens: 2, quest: :chat) do |body|
      # body_html and the status line both render into the desktop AND mobile
      # panels. Two independent Alpine scopes, both subscribed to
      # 'entry-tokens-updated' — which is why the count is never synced by a
      # single-element querySelector.
      assert_equal 2, body.scan('data-gear-status="true"').length
      assert_equal 2, body.scan('data-free-entry-chip="true"').length
    end
  end

  # ── THE ACCESSIBLE NAME ─────────────────────────────────────────────────
  #
  # The name used to come from `title` through _sidebar_panel's labelledby
  # branch, which needs BOTH id and title. Dropping the title drops the <h3> it
  # points at, and with it the name — silently, since nothing errors and the
  # panel still looks right.
  test "[component] the panel keeps an accessible name without a title" do
    render_sidebar(tokens: 0, quest: :invite) do |body|
      panel = body[body.index('id="gear-sidebar"'), 1200]

      assert_includes panel, 'aria-label="Settings menu"',
        "with no title there is no heading to point at — the explicit label IS the name"
      refute_includes panel, "aria-labelledby",
        "labelledby would point at an id no heading renders"
      refute_includes panel, "gear-sidebar-title"
    end
  end

  test "[component] the label the panel dropped is gone from the markup" do
    render_sidebar(tokens: 0, quest: :invite) do |body|
      refute_match(%r{<h3[^>]*>\s*Settings\s*</h3>}, body,
        "the panel no longer names the thing the reader is looking at")
      refute_includes body, "Admin Menu"
    end
  end

  # ── THE ROWS THAT LEFT ──────────────────────────────────────────────────
  test "[component] the quest-backed rows the status line now carries are gone" do
    render_sidebar(tokens: 0, quest: :chat) do |body|
      gear = body[body.index('id="gear-sidebar"'), 9000]

      refute_includes gear, "Send a message",
        "the header status line carries this nudge now"
    end
  end

  test "[component] NFL Totals left the gear sidebar" do
    render_sidebar(tokens: 0, quest: :invite) do |body|
      gear = body[body.index('id="gear-sidebar"'), 9000]

      refute_includes gear, "NFL Totals"
      # ...and the page is NOT stranded: the footer links it on every page, for
      # signed-in and logged-out visitors alike. Pinned in
      # NflTeamTotalsNavigationTest, which owns that concern.
      assert_select "footer a[href=?]", nfl_team_totals_path
    end
  end

  test "[component] the rows an ordinary member keeps are still there" do
    # The complement of the removals, and the reason it is worth an assertion:
    # "drop the traditional sidebar items" is the kind of instruction that is
    # easy to over-apply. These five are not quests and have no other home.
    render_sidebar(tokens: 0, quest: :invite) do |body|
      gear = body[body.index('id="gear-sidebar"'), 9000]

      ["My Profile", "My Contests", "How to Play", "Proof of Reserves", "Refresh Wallet"]
        .each { |row| assert_includes gear, row, "#{row} is not a quest and has no other home" }
    end
  end
end
