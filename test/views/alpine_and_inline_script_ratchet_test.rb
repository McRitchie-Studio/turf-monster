require "test_helper"
require "yaml"

# A ratchet on what keeps this app on Alpine and on inline script: every Alpine
# directive, every Alpine API reference, every inline script block and every
# inline event-handler attribute in the app's own source.
#
# alpine_and_inline_script_ceilings.yml, beside this file, holds one ceiling per
# surface and per kind. A ceiling is the true count, and it only goes down:
#
#   - a surface that gains one fails here: write a Stimulus controller instead;
#   - a surface that loses one fails here until its ceiling is lowered to match,
#     so a removal in one place cannot be spent on an addition later.
#
# Scanned: app/**/*.{erb,rb,js}, after ERB comments, HTML comments and whole-line
# // * and # comments are taken out. The engine gem is not scanned.
#
# Counted, per occurrence:
#
#   x_data .. x_effect  the named directive as an attribute, with or without a
#                       value, argument or modifier, and as a string key of a
#                       helper's html options ("x-data": ...)
#   x_bind              also the :attr="..." shorthand and its ":attr" string key
#   x_on                also the @event="..." shorthand and its "@event" string key
#   x_other             x-ignore, x-collapse, x-teleport, x-id, x-modelable
#   alpine_api          a reference to a member of the Alpine global
#   inline_script       a <script> tag with no src that is not a JSON data block,
#                       plus javascript_tag, tag.script and content_tag :script
#   inline_handler      an on<event> attribute or html-options key, for the
#                       events in HANDLER_EVENTS
#
# Knowingly not seen:
#
#   - a directive name assembled at run time (a partial local such as x_model:
#     that the receiving partial turns into an attribute, a Ruby or JS string
#     built by interpolation or concatenation);
#   - a shorthand with no quote after its = sign, or written flush against the
#     preceding character with no whitespace;
#   - a symbol key (x_data:) that a helper dasherizes;
#   - magics ($store, $dispatch, $refs) on their own: they ride inside counted
#     directive values and inline scripts;
#   - markup the gem renders, and script tags a gem helper emits (importmap);
#   - an inline handler for an event that HANDLER_EVENTS does not list.
#
# Knowingly over-counted: a directive named in rendered prose or inside a
# string or selector (querySelector("[x-show]")), a JS object key named
# on<event>, and a trailing comment after code on the same line.
class AlpineAndInlineScriptRatchetTest < ActiveSupport::TestCase
  CEILINGS_FILE = Pathname(__dir__).join("alpine_and_inline_script_ceilings.yml")
  SOURCES = "app/**/*.{erb,rb,js}".freeze

  NAMED = %w[data show if for model text html bind on init ref cloak transition effect].freeze
  OTHER = %w[ignore collapse teleport id modelable].freeze
  HANDLER_EVENTS = %w[
    click dblclick change input submit reset load error focus blur
    keydown keyup keypress mousedown mouseup mouseover mouseout mouseenter mouseleave mousemove
    touchstart touchend touchmove pointerdown pointerup scroll wheel resize contextmenu
    paste copy drag dragstart dragend dragover dragleave drop toggle select invalid
    animationend transitionend
  ].freeze

  directive = ->(names) { /(?<![\w-])x-(?:#{names.join('|')})(?![\w-])/ }
  shorthand = ->(sigil) { /(?<=\s)#{sigil}[a-z][\w.:-]*=["']|["']#{sigil}[a-z][\w.:-]*["']\s*(?:=>|:)/ }
  handler = "on(?:#{HANDLER_EVENTS.join('|')})"

  PATTERNS = NAMED.to_h { |name| [ "x_#{name}", [ directive.call([ name ]) ] ] }.merge(
    "x_other" => [ directive.call(OTHER) ],
    "alpine_api" => [ /\bAlpine\.[A-Za-z_$]+/ ],
    "inline_script" => [ /\bjavascript_tag\b|\btag\.script\b|\bcontent_tag\(?\s*:script\b/ ],
    "inline_handler" => [ /(?<![\w.$-])#{handler}=|(?<![\w.$-])#{handler}:(?!:)|["']#{handler}["']\s*(?:=>|:)/ ]
  ).tap do |patterns|
    patterns["x_bind"] << shorthand.call(":")
    patterns["x_on"] << shorthand.call("@")
  end.freeze
  KINDS = PATTERNS.keys.freeze

  SCRIPT_TAG = /<script\b((?:<%.*?%>|[^>])*)>/mi
  NOT_INLINE = /\bsrc\s*=|type\s*=\s*["']application\/(?:ld\+)?json["']/i

  MARKUP_COMMENTS = [ /<%#.*?%>/m, /<!--.*?-->/m, %r{^\s*//.*$} ].freeze
  COMMENTS = {
    ".erb" => MARKUP_COMMENTS,
    ".js" => [ %r{^\s*(?://|/\*|\*).*$} ],
    ".rb" => [ /^\s*#.*$/ ]
  }.freeze

  # First match wins; a path that matches none is marketing.
  SURFACES = {
    "admin" => %w[
      app/views/admin/ app/views/schema/ app/views/seeds_lab/ app/views/style/ app/views/test/
      app/views/toast_test/ app/views/benchmarks/ app/views/wallet_probe/ app/views/transaction_logs/
      app/views/slates/
      app/views/live/_dev_score_tools.html.erb
      app/javascript/slate_simulator.js app/javascript/lock_contest.js app/javascript/debug_logger.js
    ],
    "entry" => %w[
      app/views/modals/ app/views/shared/ app/views/accounts/ app/views/wallets/ app/views/wallet_exports/
      app/views/tokens/ app/views/faucet/ app/views/cdp/ app/views/sessions/ app/views/registrations/
      app/views/solana_sessions/ app/views/magic_links/ app/views/email_verifications/
      app/views/omniauth_callbacks/ app/views/api_keys/
      app/javascript/wallet_ app/javascript/solana_ app/javascript/cosign app/javascript/cdp_
      app/javascript/base58.js app/javascript/session_wipe.js
      app/helpers/wallet_ app/helpers/onramp_ app/helpers/birthday_modal_
    ],
    "board" => %w[
      app/views/contests/ app/views/live/ app/views/messages/ app/views/games/ app/views/nfl_team_totals/
      app/javascript/turf_board.js app/javascript/state_fanout.js
    ]
  }.freeze
  FALLBACK_SURFACE = "marketing".freeze
  SURFACE_NAMES = (SURFACES.keys + [ FALLBACK_SURFACE ]).freeze

  def self.count(source, extension = ".erb")
    code = COMMENTS.fetch(extension).reduce(source) { |text, comment| text.gsub(comment, "") }
    counts = PATTERNS.transform_values { |patterns| patterns.sum { |pattern| code.scan(pattern).size } }
    counts["inline_script"] += code.scan(SCRIPT_TAG).count { |(attributes)| !attributes.match?(NOT_INLINE) }
    counts
  end

  def self.surface_of(path)
    SURFACES.find { |_surface, prefixes| prefixes.any? { |prefix| path.start_with?(prefix) } }&.first || FALLBACK_SURFACE
  end

  # { "app/views/a.html.erb" => { "x_data" => 1, ... } }, for every file with at least one.
  def self.files(root = Rails.root)
    Dir.glob(root.join(SOURCES).to_s).sort.each_with_object({}) do |file, found|
      counts = count(File.read(file), File.extname(file))
      found[Pathname(file).relative_path_from(root).to_s] = counts if counts.values.any?(&:positive?)
    end
  end

  # { "board" => { "x_data" => 40, ... }, ... }, every surface and every kind present.
  def self.census(files = self.files)
    zero = SURFACE_NAMES.to_h { |surface| [ surface, KINDS.to_h { |kind| [ kind, 0 ] } ] }
    files.each_with_object(zero) do |(path, counts), totals|
      totals[surface_of(path)].merge!(counts) { |_kind, total, count| total + count }
    end
  end

  # One sentence per surface and kind whose count differs from its ceiling.
  def self.drift(census, ceilings)
    SURFACE_NAMES.flat_map do |surface|
      KINDS.filter_map do |kind|
        counted = census.dig(surface, kind).to_i
        ceiling = ceilings.dig(surface, kind)
        entry = "#{surface}.#{kind}"
        if ceiling.nil?
          "#{entry}: has no ceiling; set it to #{counted} in #{CEILINGS_FILE.basename}"
        elsif counted > ceiling
          "#{entry}: rose #{ceiling} -> #{counted}; write a Stimulus controller instead of the new one"
        elsif counted < ceiling
          "#{entry}: fell #{ceiling} -> #{counted}; lower its ceiling to #{counted} in #{CEILINGS_FILE.basename}"
        end
      end
    end
  end

  def ceilings = YAML.load_file(CEILINGS_FILE)

  test "no surface has more of any kind than its ceiling, or fewer" do
    drift = self.class.drift(self.class.census, ceilings)

    assert_empty drift, "surfaces drifted from their ceilings:\n  #{drift.join("\n  ")}"
  end

  test "the ceilings name exactly the surfaces and kinds counted, and are not all zero" do
    assert_equal SURFACE_NAMES.sort, ceilings.keys.sort
    ceilings.each { |surface, kinds| assert_equal KINDS.sort, kinds.keys.sort, "#{surface} kinds" }
    assert_operator ceilings.values.sum { |kinds| kinds.values.sum }, :>, 0, "all-zero ceilings would mean the scan saw nothing"
  end

  test "the counter sees each spelling of each kind" do
    one = ->(kind, source, extension = ".erb") do
      assert_equal({ kind => 1 }, self.class.count(source, extension).select { |_kind, count| count.positive? }, source)
    end

    one.call("x_data", '<div x-data="{ open: false }">')
    one.call("x_data", "<body x-data>")
    one.call("x_data", '<%= form_with html: { "x-data": "composer()" } do %>')
    one.call("x_show", '<p x-show="open">')
    one.call("x_show", '<p x-show.transition="open">')
    one.call("x_if", '<template x-if="open">')
    one.call("x_for", '<template x-for="row in rows">')
    one.call("x_model", '<input x-model.number="amount">')
    one.call("x_text", '<span x-text="name">')
    one.call("x_html", '<span x-html="body">')
    one.call("x_init", '<div x-init="load()">')
    one.call("x_ref", '<div x-ref="track">')
    one.call("x_cloak", "<div x-cloak>")
    one.call("x_transition", "<div x-transition.opacity>")
    one.call("x_transition", '<div x-transition:enter="ease-out">')
    one.call("x_effect", '<div x-effect="sync()">')
    one.call("x_other", "<div x-ignore>")
    one.call("x_other", "<div x-collapse>")
    one.call("x_bind", '<a x-bind:href="url">')
    one.call("x_bind", '<a :href="url">')
    one.call("x_bind", "<a\n  :class='{ on: open }'>")
    one.call("x_bind", '<%= f.submit "Go", ":disabled": "busy" %>')
    one.call("x_bind", '<%= form_with html: { ":action" => "url" } do %>')
    one.call("x_on", '<a x-on:click="go()">')
    one.call("x_on", '<a @click.prevent="go()">')
    one.call("x_on", '<div @keydown.escape.window="close()">')
    one.call("x_on", '<%= form_with html: { "@turbo:submit-end" => "done()" } do %>')
    one.call("x_on", '<%= f.text_field :name, "@input": "check()" %>')
    one.call("alpine_api", "Alpine.store('session')", ".js")
    one.call("alpine_api", "store = 'window.Alpine.data'", ".rb")
    one.call("inline_script", "<script>\n  go();\n</script>")
    one.call("inline_script", '<script nonce="<%= content_security_policy_nonce %>" type="module">go()</script>')
    one.call("inline_script", '<%= javascript_tag "go()" %>')
    one.call("inline_script", "<%= tag.script(nonce: true) do %>go()<% end %>")
    one.call("inline_handler", '<button onclick="go()">')
    one.call("inline_handler", "<form onsubmit='return ok()'>")
    one.call("inline_handler", '<%= link_to "Go", "#", onclick: "go()" %>')
    one.call("inline_handler", '<%= link_to "Go", "#", "onclick" => "go()" %>')
  end

  test "the counter passes over what is not a directive, a script or a handler" do
    none = ->(source, extension = ".erb") do
      assert_empty self.class.count(source, extension).select { |_kind, count| count.positive? }, source
    end

    none.call("<%# x-data, @click=\"go()\" and a <script> tag, in an ERB comment %>")
    none.call("<!-- x-show and onclick=\"go()\" -->")
    none.call("  // Alpine.store reads x-data before the <script> below")
    none.call("  # x-show is resolved by Alpine.store", ".rb")
    none.call(" * x-show is resolved by Alpine.store", ".js")
    none.call('<%= link_to @contest.name, contest_path(@contest), class: "link" %>')
    none.call('<%= tag.div class: "a", data: { id: @user.id } %>')
    none.call('<%= render "row", status: :class, key: ok ? :a : :b %>')
    none.call("<% @title = \"Lobby\" %>")
    none.call('<a href="mailto:team@example.com">team@example.com</a>')
    none.call("<style>@media (min-width: 640px) { a:hover { color: red } }</style>")
    none.call('<div class="translate-x-data overflow-x-auto" data-x-data-source="1">')
    none.call('headers: { "x-csrf-token" => token, "x-id-source" => 1 }', ".rb")
    none.call('<script src="https://cdn.example.com/chart.js"></script>')
    none.call('<script type="application/json" id="board-config"><%= raw json %></script>')
    none.call('<p data-onchain="1">only: "one" onramp: "x"</p>')
    none.call("el.onclick = handler; window.onload = boot;", ".js")
  end

  test "every path lands on one surface, and an unmatched one on the fallback" do
    assert_equal "admin", self.class.surface_of("app/views/admin/hub.html.erb")
    assert_equal "admin", self.class.surface_of("app/views/live/_dev_score_tools.html.erb")
    assert_equal "board", self.class.surface_of("app/views/live/index.html.erb")
    assert_equal "board", self.class.surface_of("app/views/contests/_turf_totals_board.html.erb")
    assert_equal "entry", self.class.surface_of("app/views/modals/_auth.html.erb")
    assert_equal "entry", self.class.surface_of("app/javascript/wallet_signal.js")
    assert_equal "marketing", self.class.surface_of("app/views/layouts/application.html.erb")
    assert_equal "marketing", self.class.surface_of("app/views/brand_new/index.html.erb")
  end

  test "a rise, a fall and a missing ceiling each fail the ratchet, per surface and kind" do
    census = ->(overrides) do
      SURFACE_NAMES.to_h { |surface| [ surface, KINDS.to_h { |kind| [ kind, 1 ] } ] }.tap do |counts|
        overrides.each { |(surface, kind), count| counts[surface][kind] = count }
      end
    end
    ceilings = census.call({})
    drift = ->(overrides) { self.class.drift(census.call(overrides), ceilings) }

    assert_empty drift.call({}), "control: at its ceilings"
    assert_match(/\Aboard\.x_show: rose 1 -> 2/, drift.call(%w[board x_show] => 2).sole)
    assert_match(/\Aentry\.x_on: fell 1 -> 0; lower its ceiling to 0/, drift.call(%w[entry x_on] => 0).sole)
    assert_equal 2, drift.call(%w[admin x_data] => 0, %w[board x_data] => 2).size, "a fall does not pay for a rise elsewhere"
    assert_match(/\Amarketing\.inline_script: has no ceiling; set it to 1/,
                 self.class.drift(census.call({}), ceilings.merge("marketing" => ceilings["marketing"].except("inline_script"))).sole)
  end
end
