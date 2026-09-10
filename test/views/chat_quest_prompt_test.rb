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

  # @quest_step is what contests#show sets for an entrant; the panel gates the
  # deck on it because the quest card is the only thing that can ever dispatch
  # quest-chat-active. Pass nil to render the panel as contests#live does.
  def render_panel(user, quest_step: :chat)
    view.define_singleton_method(:current_user) { user }
    view.define_singleton_method(:logged_in?) { user.present? }
    @quest_step = quest_step
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
    assert_equal "A light it up 🏳️", deck.last
  end

  # NO source-grep test for the REST behaviour lives here any more. The one that
  # did (assert_match on the literal state-machine lines) ran green against both
  # the broken and the fixed component — grepping a rendered <script> proves the
  # text is present, never that it runs, and it pinned an implementation line so
  # a correct fix would have failed it for the wrong reason. Resting is now
  # covered where it can actually be observed: e2e/quest_chat_prompts.spec.js.

  # contests#live renders the chat panel but NO quest card, so nothing there can
  # dispatch quest-chat-active. Building the deck anyway cost a fallback query
  # per render for a deck that could never play.
  test "no quest card on the page means no deck is built" do
    html = render_panel(@entrant, quest_step: nil)

    assert_empty rendered_deck(html)
    # The composer itself still renders — only the nudge is absent.
    assert_match(/id="contest-chat-input"/, html)
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

  # The composer must carry a STABLE accessible name. The placeholder is the only
  # name a bare textarea has, and this feature rewrites it character by character
  # — so a screen reader would otherwise read a name that changes every 55ms, and
  # read nothing at all in the moment between two lines.
  test "the composer has an accessible name independent of the placeholder" do
    html = render_panel(@entrant)

    assert_match(/aria-label="Message the contest"/, html)
  end
end
