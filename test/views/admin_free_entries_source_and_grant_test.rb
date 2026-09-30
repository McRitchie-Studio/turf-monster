require "test_helper"

# The /admin/free_entries row's Source cell and its "Grant 1" control.
#
# Like the burn buttons, Grant keys off a COUNT, so it has the same three ways
# to render fine and still be wrong: showing on a cold cache (unverified count),
# showing beside Mint (two green mints on one row), and submitting a different
# number from the one the operator saw. The test env's :null_store would keep
# every row cold, so each case warms a real MemoryStore — the pattern from
# admin_free_entries_burn_buttons_test.
class AdminFreeEntriesSourceAndGrantTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)
    @signup = users(:sam)
    @signup.update_columns(seeds: 0, reference: "tiktok", slug: "sam-grant-view")
  end

  def render_page(tokens: [], seeds: 0, reference: nil)
    @signup.update_columns(seeds: seeds)
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub :cache, store do
      store.write(Solana::Vault.entry_tokens_cache_key(@signup.solana_address), tokens)
      log_in_as(@admin)
      get admin_free_entries_path(reference: reference)
    end
    assert_response :success
  end

  # Asserts the row exists, so no refute below can pass on a missing row.
  def signup_row
    row = css_select("#users-tbody tr").find { |tr| tr.to_s.include?(@signup.slug) }
    assert row, "the signup's row did not render"
    row
  end

  test "the row names the user's signup source" do
    render_page

    assert_equal "tiktok", signup_row.css("td[data-test='signup-source']").text.strip
  end

  test "a user with no recorded source reads 'none'" do
    @signup.update_columns(reference: nil)
    render_page

    assert_equal "none", signup_row.css("td[data-test='signup-source']").text.strip
  end

  test "a zero-owed signup gets Grant 1, bound to the minted count it shows" do
    render_page

    form = signup_row.css("form").find { |f| f["action"].include?("/grant") }
    assert form, "a new signup is owed nothing, so Grant is the only way to give the promised entry"
    assert_equal admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0), form["action"]
    assert_match(/Grant 1/, form.text)
    assert_match(/absorbs the next one they earn/, form.css("button").first["data-turbo-confirm"],
      "the confirm must say the grant counts against their level-up entries")
  end

  test "Grant carries the active source filter" do
    render_page(reference: "tiktok")

    form = signup_row.css("form").find { |f| f["action"].include?("/grant") }
    assert_equal admin_grant_free_entries_path(user_slug: @signup.slug, minted: 0, reference: "tiktok"),
                 form["action"]
  end

  test "Grant submits the count already minted, not zero" do
    render_page(tokens: [{ consumed: true, source: 0, created_at: 1 }], seeds: 50)

    form = signup_row.css("form").find { |f| f["action"].include?("/grant") }
    assert_includes form["action"], "minted=1"
  end

  test "a row owed a level-up entry shows Mint, not Grant" do
    render_page(seeds: 150) # floor(150/100) - 0 minted = 1 owed

    assert_match(/Mint 1/, signup_row.to_s)
    refute_match(/Grant 1/, signup_row.to_s, "one green mint per row")
  end

  test "a cold row offers no Grant" do
    Rails.stub :cache, ActiveSupport::Cache::MemoryStore.new do # never written → cold
      log_in_as(@admin)
      get admin_free_entries_path
    end

    assert_response :success
    refute_match(/Grant 1/, signup_row.to_s, "never mint against a count that has not been read")
  end
end
