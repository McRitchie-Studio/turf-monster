# The /turf-monster-v2 hero laptop's screen: a contest's live page exactly as a
# SIGNED-OUT visitor sees /contests/<slug>/live, rendered from the live page's
# own partials (pages/_laptop_live composes them).
#
# THE CONTEST IS FICTIONAL. It renders LaptopFictionalShowcase: a made-up
# contest ("Turf Monster Showcase") on a made-up slate, built from unsaved
# in-memory records, so no real contest, game or player ever reaches the
# laptop and the render is the same bytes on any date. The only database reads
# a render makes are the signed-out navbar's own (its geo setting and the
# no-session user lookup), none of them contest data.
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
# THE FEATURED GAME IS SIMULATED. The game the live page opens on is drawn
# from LaptopScoreSimulation's opening frame (3-7, in progress), and #frames
# renders every later frame of that simulation through the same partials and
# the same clean-up, for the page's own score script to swap in. Nothing is
# written.
#
# KICKOFFS AS A WEEKDAY AND A TIME. The live page prints kickoffs in UTC and
# lets its script rewrite them in the reader's zone. Here every kickoff is
# written once, in NextSlateDrop::ZONE, as "Sun 2:25 PM", and handed to the
# page as plain text the script does not touch; a time that would print a
# calendar date ("Jan 5", "Sun, Jan 5") is removed, so the laptop never shows a
# date that could go stale.
#
# THE BOARD (LaptopShowcaseEntrants::Script): Mason and Turf, unsaved,
# readonly records drawn by the real leaderboard partial, with their avatar
# images swapped in after the render (#showcase_avatars). Every simulated
# touchdown swaps the lead.
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

  # The one time format the laptop prints: the weekday and the clock time,
  # never a date. contests/_live_script's formatKickoffs also writes a date for
  # "kickoff-date" and "played-on"; those nodes are dropped (#localize_times).
  KICKOFF_FORMAT = "%a %-l:%M %p".freeze

  def self.render(showcase, host:, https:)
    new(showcase, host: host, https: https).render
  end

  attr_reader :simulation

  def initialize(showcase, host:, https:)
    @host = host
    @https = https
    focus_game = showcase.games.values.flatten.find { |game| game.slug == showcase.focus_slug }
    @simulation = focus_game && LaptopScoreSimulation.new(focus_game)
    @showcase = @simulation ? with_game(showcase, @simulation.opening.game) : showcase
    @base_showcase = @showcase
  end

  # The showcase entrants join here, not in #initialize: only the render reads
  # the board, and a cached page (LaptopSnapshotCache) builds this object for
  # its #simulation alone.
  def render
    @showcase = @showcase.with(entries: script ? script.entries_at(0) : [])
    doc = clean(renderer.render(partial: "pages/laptop_live", locals: { showcase: @showcase, board_wired: !script.nil? }))
    showcase_avatars(doc)
    script_pill_points(doc)
    collapse_navbar(doc)
    rotate_strip(doc)
    doc.to_html.html_safe # rubocop:disable Rails/OutputSafety -- our own partials' render, scripts removed
  end

  # EVERY TOUCHDOWN OF THE SIMULATION, as the three things a real score sends
  # the live page (Contest::LiveBroadcast.goal_scored): the featured game's
  # focus tile and its strip chip at the new score, and the goal-feed node the
  # page's script turns into the banner and the row animations. Each is drawn
  # by the live page's own partial and cleaned exactly as the snapshot is.
  #
  # The opening frame is not here: it is the snapshot the page loads with, and
  # the page's script keeps a copy of it to loop back to. That saves the page a
  # second copy of the largest frame.
  def frames
    return [] unless @simulation

    contest = @showcase.contest
    @simulation.frames.drop(1).map do |frame|
      game = frame.game
      tile = renderer.render(partial: "contests/live_focus",
                             locals: { active: [game], upcoming: [], completed: [], contest: contest, focus_slug: game.slug })
      chip = renderer.render(partial: "contests/live_game_chip", locals: { game: game })
      feed = renderer.render(partial: "contests/goal_feed_item",
                             locals: { event: "goal", goal: frame.goal, team: frame.team, player: nil, game: game })
      parts = { index: frame.index, tile: inert(clean(tile)), chip: inert(clean(chip)), feed: inert(clean(feed)) }
      parts[:board] = board_frame(contest, frame.index) if script
      parts
    end
  end

  # The scripted showcase board (LaptopShowcaseEntrants::Script), or nil when
  # the showcase has no featured game to simulate. Built from the showcase as
  # loaded, before #render swaps its entries.
  def script
    return @script if defined?(@script)

    @script = LaptopShowcaseEntrants::Script.build(@base_showcase, @simulation)
  end

  private

  # THE BOARD AT ONE FRAME: the live page's own leaderboard partial over the
  # showcase entrants at that frame's totals, cleaned and inert like every
  # frame. The driver swaps it into the board wrapper, which carries the live
  # page's id, so the live script re-ranks it exactly as it does a broadcast
  # (contests/_live_script #syncBoard): the slide, the wash, the rank badge,
  # the score pop.
  def board_frame(contest, index)
    html = renderer.render(partial: "contests/turf_totals_leaderboard",
                           locals: { compact: true, viewer: nil, contest: contest, entries: script.entries_at(index),
                                     matchups: @showcase.matchups, onchain_contest: nil })
    doc = clean(html)
    showcase_avatars(doc)
    script_pill_points(doc, script.entries_at(index))
    inert(doc)
  end

  # A scripted pick has points while its game is still being played, which the
  # board would draw as the multiplier; so each pill of a showcase row shows
  # its points, and the row's pills add up to its total.
  def script_pill_points(doc, entries = nil)
    return unless script

    (entries || @showcase.entries).each do |entry|
      row = doc.at_css(%([data-entry-slug="#{entry.slug}"]))
      next unless row

      entry.selections.each do |selection|
        team = selection.slate_matchup.team
        next unless team

        row.css(%([title^="#{team.name} — "])).each do |pill|
          pill["title"] = "#{team.name} — #{format_points(selection.points)} pts"
          mono = pill.at_css("span.font-mono")
          mono.content = format_points(selection.points) if mono
        end
      end
    end
  end

  def format_points(value)
    value = value.to_f.round(1)
    value == value.to_i ? value.to_i.to_s : value.to_s
  end

  # The showcase entrants (LaptopShowcaseEntrants) are unsaved users with no
  # attachment, so components/avatar drew them as initials; each row's disc
  # becomes its image here, at the avatar's own size and shape.
  def showcase_avatars(doc)
    doc.css(%([data-entry-slug^="#{LaptopShowcaseEntrants::SLUG_PREFIX}"])).each do |row|
      image = LaptopShowcaseEntrants.image_for(row["data-entry-slug"])
      disc = row.at_css(".relative.flex-shrink-0 > div.rounded-full")
      next unless image && disc

      name = row.at_css(".font-bold.truncate")&.text.to_s.strip
      img = Nokogiri::XML::Node.new("img", doc.document)
      img["src"] = ActionController::Base.helpers.asset_path(image)
      img["alt"] = name
      img["class"] = "w-14 h-14 rounded-full object-cover"
      img["data-test"] = "showcase-avatar"
      disc.replace(img)
    end
  end

  def renderer
    @renderer ||= begin
      session = { geo_state: GEO_STATE, "geo_state" => GEO_STATE }
      ContestsController.renderer.new(http_host: @host, https: @https, "rack.session" => session)
    end
  end

  def clean(html)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css(STRIPPED).each(&:remove)
    # The leaderboard partial ends with a collapsible "Contest JSON" debug block
    # (components/json_debug) that serializes every entry's user (id, name).
    # It is out of view on the screen, but its text would still be in this
    # page's HTML, so it goes too.
    doc.css(".json-debug").each { |node| (node.ancestors("details").first || node).remove }
    resolve_x_show(doc)
    resolve_focus_class(doc)
    localize_times(doc)
    doc
  end

  # The showcase with one game swapped for its simulated copy, in place in
  # whichever phase list holds it.
  def with_game(showcase, game)
    games = showcase.games.transform_values do |list|
      list.map { |g| g.slug == game.slug ? game : g }
    end
    showcase.with(games: games)
  end

  # A frame is swapped into the x-ignore snapshot after Alpine has started,
  # and whether Alpine walks a node added under x-ignore is its own business.
  # So a frame carries no Alpine at all: its one x-show is already resolved
  # (the featured tile is the one shown) and its bindings are inert here.
  ALPINE_ATTRIBUTE = /\A(x-|@|:)/

  def inert(doc)
    doc.traverse do |node|
      next unless node.element?

      node.attribute_nodes.each { |attr| node.remove_attribute(attr.name) if attr.name.match?(ALPINE_ATTRIBUTE) }
    end
    doc.to_html
  end

  # Every <time> becomes plain text: a kickoff is written as its weekday and
  # time in NextSlateDrop::ZONE, and anything else (a date) is removed. The
  # datetime and data-role go with it, so the live script under the laptop
  # (formatKickoffs) finds nothing to rewrite in the reader's zone, and the
  # laptop reads the same everywhere.
  def localize_times(doc)
    zone = Time.find_zone!(NextSlateDrop::ZONE)
    doc.css("time").each do |node|
      at = begin
        Time.iso8601(node["datetime"].to_s)
      rescue ArgumentError
        nil
      end
      if node["data-role"] == "kickoff" && at
        span = Nokogiri::XML::Node.new("span", doc.document)
        span["class"] = node["class"] if node["class"]
        span.content = at.in_time_zone(zone).strftime(KICKOFF_FORMAT)
        node.replace(span)
      else
        node.remove
      end
    end
  end

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
end
