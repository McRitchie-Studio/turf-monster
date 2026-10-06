# The /turf-monster-v2 hero laptop's screen: a contest's live page exactly as a
# SIGNED-OUT visitor sees /contests/<slug>/live, rendered from the live page's
# own partials (pages/_laptop_live composes them).
#
# SIGNED OUT BY CONSTRUCTION. It renders through ContestsController.renderer,
# a request with no session, so every current_user / logged_in? read inside
# the real navbar, leaderboard and chat partials resolves to a guest: no
# balance, wallet, username, admin controls or "Add 2nd Entry", whoever is
# viewing the marketing page. The one session value set is a fixed geo region
# (GEO_STATE), so the navbar's geo pill shows Turf Monster's home state rather
# than anything derived from the viewer's IP.
#
# STATIC AND CLEAN. Every <script> and every turbo-cable-stream-source is
# removed from the rendered HTML, and so is the leaderboard's "Contest JSON"
# debug block, so the snapshot runs no code and opens no cable
# subscription; the caller also marks it x-ignore, aria-hidden and inert.
#
# NAMES. A player with no username would be labelled by User#display_name's
# fallbacks, an email prefix or a truncated wallet. Those users are relabelled
# "Player N" (N = their rank) on the in-memory records only, before rendering;
# nothing is saved.
class LaptopLiveSnapshot
  GEO_STATE = "CO".freeze
  STRIPPED = "script, turbo-cable-stream-source".freeze

  # The snapshot is x-ignore, so Alpine never decides its x-show switches.
  # These are the leaderboard's, resolved to what the real page shows a guest
  # at a 1280px window: its column measures 616px, so dkFull (>= 600) and wide
  # (>= 450) are true, and nothing is expanded, opened, or in dev mode. True
  # reveals (x-cloak removed); false hides (display: none). An expression not
  # listed here is left exactly as rendered.
  STATIC_X_SHOW = {
    "dkFull" => true, "!dkFull" => false, "picksOpen || wide" => true,
    "expanded" => false, "!expanded" => true, "$store.devMode" => false
  }.freeze

  def self.render(showcase, host:, https:)
    new(showcase).render(host: host, https: https)
  end

  def initialize(showcase)
    @showcase = showcase
  end

  def render(host:, https:)
    anonymize!
    session = { geo_state: GEO_STATE, "geo_state" => GEO_STATE }
    renderer = ContestsController.renderer.new(http_host: host, https: https, "rack.session" => session)
    html = renderer.render(partial: "pages/laptop_live", locals: { showcase: @showcase })
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css(STRIPPED).each(&:remove)
    # The leaderboard partial ends with a collapsible "Contest JSON" debug block
    # (components/json_debug) that serializes every entry's user (id, name).
    # It is out of view on the screen, but its text would still be in this
    # page's HTML, so it goes too.
    doc.css(".json-debug").each { |node| (node.ancestors("details").first || node).remove }
    resolve_x_show(doc)
    resolve_focus_class(doc)
    collapse_navbar(doc)
    rotate_strip(doc)
    doc.to_html.html_safe # rubocop:disable Rails/OutputSafety -- our own partials' render, scripts removed
  end

  private

  # The games strip marks the game being watched with
  #   :class="focus === '<slug>' ? 'tt-chip-focused' : ''"
  # which lights that chip's glow ring (contests/_live_page_styles). Alpine
  # never runs here, so the binding is resolved against the slug the live page
  # opens on: exactly one chip glows, the rest stay flat.
  FOCUS_CLASS = /\Afocus === '([^']+)' \? '([^']+)' : ''\z/

  # The navbar's COLLAPSED state, the one a reader sees once they have
  # scrolled: navCollapse() writes --nav-p from 0 (expanded) to 1 (collapsed)
  # on the header and adds the scrolled classes, and the logo, title and
  # padding all size off --nav-p. Written here as the end state, so the
  # snapshot gets the short bar and keeps its height for the game and the
  # leaderboard.
  SCROLLED_NAV_CLASSES = "shadow-lg border-b border-subtle is-scrolled".freeze

  def collapse_navbar(doc)
    header = doc.at_css("header[data-navbar-root]")
    return unless header

    header["style"] = "--nav-p: 1; #{header['style']}".strip
    header["class"] = [header["class"], SCROLLED_NAV_CLASSES].compact.join(" ")
  end

  # THE STRIP MID-ROTATION. On the live page the strip overflows, so its
  # carousel appends a copy of every chip (the seamless loop) and scrolls
  # through them. This draws one frame of that rotation: the same copy is
  # appended, and the track is offset so the FOCUSED chip's copy sits in slot
  # FOCUS_SLOT, the middle-right of the strip, where it is clear of the phone in
  # the hero. Chronological order is kept, and the chip that is lit is still
  # the one the live page opens on. Chips are a fixed 168px with an 8px gap
  # (contests/_live_game_chip, gap-2), so the offset needs no measuring. A strip
  # that fits its width does not rotate on the live page and is left alone.
  CHIP_PITCH = 176
  STRIP_WIDTH = 1248 # the 1280px canvas less contests/live's px-4
  FOCUS_SLOT = 4

  def rotate_strip(doc)
    track = doc.at_css('[x-ref="track"]')
    return unless track

    slots = track.element_children.to_a
    return if slots.size * CHIP_PITCH <= STRIP_WIDTH

    focus = slots.index { |slot| slot.at_css(".tt-chip-focused") } || 0
    slots.each { |slot| track.add_child(slot.dup) }
    offset = ((slots.size + focus) - FOCUS_SLOT) * CHIP_PITCH
    track["style"] = "transform: translateX(-#{offset}px); #{track['style']}".strip
  end

  def resolve_focus_class(doc)
    doc.traverse do |node|
      next unless node.element? && node[":class"]

      match = FOCUS_CLASS.match(node[":class"].strip)
      next unless match
      next unless match[1] == @showcase.focus_slug

      node["class"] = [node["class"], match[2]].compact.join(" ")
    end
  end

  def resolve_x_show(doc)
    doc.css("[x-show]").each do |node|
      shown = STATIC_X_SHOW[node["x-show"].strip]
      next if shown.nil?

      if shown
        node.remove_attribute("x-cloak")
      else
        node["style"] = "display: none; #{node['style']}".strip
      end
    end
  end

  def anonymize!
    @showcase.entries.each_with_index do |entry, i|
      user = entry.user
      next if user.nil? || user.username.present?

      user.username = "Player #{i + 1}"
    end
    @showcase.messages.each do |message|
      message.user.username = "A player" if message.user && message.user.username.blank?
    end
  end
end
