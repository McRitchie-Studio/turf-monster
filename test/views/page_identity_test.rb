require "test_helper"

# [component] layouts/_page_identity: the <title> and meta description every
# application-layout page carries. They are read from studio-engine's
# resolution (studio_link_preview), the same chain the og:/twitter: tags use,
# so the tab title and the unfurl never disagree (/tasks/turf-adopts-link-preview).
class PageIdentityTest < ActionView::TestCase
  helper Studio::LinkPreviewHelper

  setup { Studio::SiteIdentity.delete_all }

  def render_identity
    render partial: "layouts/page_identity"
  end

  test "with no override the drafted site copy names the page" do
    render_identity

    assert_select "title", text: Studio.site_title
    assert_select "meta[name='description'][content=?]", Studio.site_description
    assert_select "link[rel='apple-touch-icon']"
    # The preview tags are the engine head's job, not this partial's.
    assert_select "meta[property^='og:']", count: 0
  end

  test "the operator's saved copy wins over the draft" do
    Studio::SiteIdentity.current!.update!(title: "Saved title", description: "Saved description.")
    render_identity

    assert_select "title", text: "Saved title"
    assert_select "meta[name='description'][content='Saved description.']"
  end

  test "a page's content_for title and description win, unescaped once" do
    view.content_for(:title, "Pass & Run — Turf Monster")
    view.content_for(:meta_description, "A page of its own.")
    render_identity

    assert_select "title", text: "Pass & Run — Turf Monster"
    assert_select "meta[name='description'][content='A page of its own.']"
    assert_not_includes rendered, "&amp;amp;", "the title was escaped twice"
  end

  test "a link_preview description override reaches the meta description" do
    view.link_preview(description: "The exact smart contract that holds your prize pools.")
    render_identity

    assert_select "meta[name='description'][content=?]", "The exact smart contract that holds your prize pools."
  end
end
