require "test_helper"

# [component] The Quest 2 nudge as it actually renders — contests/_chat_panel.
#
# The mission "Send Your First Message" (contests/_quest_chat) points at the
# contest composer with a southwest arrow, and the composer answers with two
# cues: a glow around the input, and a placeholder that types out sample
# messages the viewer could plausibly send. Both hang off ONE event the quest
# card dispatches — quest-chat-active — so this pins the whole seam: the
# listener name, the bound class, the bound placeholder, and the per-viewer deck
# that rides along in data-chat-prompts.
class ChatQuestPromptTest < ActionView::TestCase
  tests ContestsHelper

  setup do
    @contest = contests(:one)
    @entrant = users(:sam)
    @outsider = users(:jordan)
    entry = @contest.entries.create!(user: @entrant, status: :active)
    entry.selections.create!(slate_matchup: slate_matchups(:m1))
  end

  def render_panel(user)
    view.define_singleton_method(:current_user) { user }
    view.define_singleton_method(:logged_in?) { user.present? }
    render partial: "contests/chat_panel", locals: { contest: @contest }
  end

  # The deck lives in a data-* attribute, so it survives HTML escaping. Read it
  # back the way the browser does rather than matching on &quot;-mangled JSON.
  def rendered_deck(html)
    raw = html[/data-chat-prompts="([^"]*)"/, 1]
    JSON.parse(CGI.unescapeHTML(raw.to_s))
  end

  test "the composer binds the quest glow and the typed placeholder" do
    html = render_panel(@entrant)

    assert_match(/:class="\{ 'chat-input-glow': questGlow \}"/, html)
    assert_match(/:placeholder="typing \? typed : 'Message the contest…'"/, html)
    # The plain attribute stays too: Alpine binds on its first tick, and a
    # composer that paints blank until then reads as broken.
    assert_match(/\splaceholder="Message the contest…"/, html)
  end

  test "the panel listens on the event the quest card actually dispatches" do
    html = render_panel(@entrant)

    assert_match(/@quest-chat-active\.window="questChatActive\(\)"/, html)
    assert_match(/questChatActive\(\) \{/, html, "the listener needs the method behind it")
    # quest-chat-active is dispatched by questCard#_maybePingChat. If that name
    # ever moves, this pair is what catches it.
    assert_includes File.read(Rails.root.join("app/views/shared/_alpine_factories.html.erb")),
                    'CustomEvent("quest-chat-active")'
  end

  test "the deck rendered is this viewer's own, built from their picks" do
    deck = rendered_deck(render_panel(@entrant))

    assert_equal ContestsHelper::CHAT_PROMPT_LIMIT, deck.length
    assert_equal ["Hey everyone 👋", "Good luck, everyone ⚔️"], deck.first(2)
    # The line the composer RESTS on is the personal one, so it is the line that
    # actually has to survive the round trip through the data attribute.
    assert_equal "A are about to light it up 🏳️", deck.last
  end

  # The typewriter stops after the last line and leaves it in the placeholder.
  # The deck IS the pass count, so the rest condition has to key off the deck's
  # own length — a hard-coded 3 here would drift the moment the deck resizes.
  test "the typewriter rests on the last line rather than looping" do
    html = render_panel(@entrant)

    assert_match(/rest = this\._promptIdx >= this\._prompts\.length - 1;/, html)
    assert_match(/if \(rest\) \{ this\._promptTimer = null; return; \}/, html)
    # Resting must NOT run through stopPrompts — that clears `typing`, which
    # would swap the finished line back to the static placeholder.
    refute_match(/if \(rest\) \{ this\.stopPrompts/, html)
    # And nothing may wrap the index back to zero, or it would loop forever.
    refute_match(/_promptIdx = \(this\._promptIdx \+ 1\) % /, html)
  end

  test "a viewer who cannot post gets no composer and an empty deck" do
    # jordan holds a fixture entry on this contest; drop it so they read as the
    # logged-in NON-entrant, which is the case the composer gates on.
    entries(:two).destroy!

    html = render_panel(@outsider)

    assert_includes html, "Enter the contest to join the chat."
    assert_empty rendered_deck(html), "no composer, nothing to type into it"
    # The class NAME still appears in the inline script's comments; what must be
    # absent is the BINDING, which only the composer carries.
    refute_match(/:class="\{ 'chat-input-glow'/, html)
  end

  test "the glow is retired the moment the first message earns its seeds" do
    html = render_panel(@entrant)

    # send() flips both cues off on the seeds-earning response — without this
    # the composer keeps glowing at a player whose mission is already done.
    assert_match(/if \(data\.seeds_earned\) \{\s*\n\s*this\.questDone\(\);/, html)
    assert_match(/questDone\(\) \{\s*\n\s*this\.questGlow = false;\s*\n\s*this\.stopPrompts\(\);/, html)
  end
end
