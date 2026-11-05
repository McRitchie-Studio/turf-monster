require "test_helper"

# [unit] The or divider on the sign-in card and in the auth modal. It once hid a line
# behind the word with a bg-surface patch. On a translucent card the patch showed as a
# lighter rectangle. Now the row has a hairline on each side of the word and no
# background, so it works on any surface.
class AuthOrDividerTest < ActionView::TestCase
  # The helpers the card reads, stubbed at the view: this tier renders the partial.
  def render_card
    view.define_singleton_method(:managed_wallet_onboarding?) { false }
    view.define_singleton_method(:current_user) { nil }
    view.define_singleton_method(:auth_return_to) { |*| nil }
    render partial: "shared/auth_card"
  end

  def render_modal
    view.define_singleton_method(:logged_in?) { false }
    render partial: "modals/auth"
  end

  test "the sign-in card's divider paints nothing behind the word" do
    assert_clean_divider render_card
  end

  test "the auth modal's divider paints nothing behind the word" do
    assert_clean_divider render_modal, margin: "my-4"
  end

  private

  def assert_clean_divider(html, margin: "my-6")
    words = Nokogiri::HTML5.fragment(html).css("span").select { |span| span.text.strip == "or" }
    assert_equal 1, words.size, "expected one or divider"
    word = words.first
    row = word.parent

    assert_equal "text-secondary", word["class"], "the word carries only its ink"
    assert_equal %w[div span div], row.element_children.map(&:name), "a line on each side of the word"
    [ row.element_children.first, row.element_children.last ].each do |line|
      assert_equal "flex-1 border-t border-strong", line["class"], "the hairline"
    end
    [ "flex", "items-center", "gap-3", "text-sm", margin ].each do |klass|
      assert_includes row["class"].split, klass, "the row"
    end
    assert_no_match(/\bbg-|\babsolute\b/, row.to_html, "no knockout and no absolute line")
  end
end
