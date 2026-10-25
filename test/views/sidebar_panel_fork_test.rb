require "test_helper"

# [component] components/_sidebar_panel is a fork of studio-engine's copy kept
# for two deltas (title_html and the id-bearing close hook; the file's header
# says why). Everything else follows the engine 0.113.0 copy, including the
# hardening of the three dismissal handlers.
class SidebarPanelForkTest < ActionView::TestCase
  QUOTED = %(cartOpen = false; track("closed")).freeze

  def panel(**locals)
    html = render(partial: "components/sidebar_panel", locals: { id: "entry-sidebar", open: "cartOpen" }.merge(locals))
    Nokogiri::HTML5.fragment(html).at_css("aside")
  end

  # The regression this fork carried until the engine's hardening was ported:
  # each handler was built as %(@name="#{action}").html_safe, so the double
  # quote inside track("closed") ended the attribute and the rest of the
  # expression became attributes of the aside.
  test "a double quote in an action cannot end its attribute" do
    aside = panel(close_action: QUOTED, outside_action: QUOTED, escape_action: QUOTED)

    %w[@click.outside @keydown.escape.window @turbo:before-cache.window].each do |name|
      assert_equal QUOTED, aside[name], "#{name} must carry the whole expression"
    end
    stray = aside.attribute_nodes.map(&:name).grep(/closed|track/)
    assert_empty stray, "the expression leaked into attributes: #{stray.inspect}"
  end

  test "title_html leads the header where a title would, and names nothing" do
    aside = panel(title_html: tag.span("2 Free Entries", data: { status: "" }), aria_label: "Settings menu",
                  close_action: "cartOpen = false")
    lead = aside.at_css("div.min-w-0.flex-1 > [data-status]")

    assert lead, "the status line must sit in the left-hand lead slot"
    assert_equal "Settings menu", aside["aria-label"]
    assert_nil aside["aria-labelledby"], "title_html is content, not the panel's name"
  end

  test "the close button carries the panel id the gear click handler matches" do
    button = panel(close_action: "cartOpen = false").at_css("button[aria-label='Close sidebar']")

    assert_equal "entry-sidebar", button["data-sidebar-panel-close"]
    assert_includes button["class"], "focus-visible:ring-2", "the engine copy's focus ring came with the port"
  end
end
