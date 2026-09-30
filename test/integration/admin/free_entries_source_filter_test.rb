require "test_helper"

# The signup-source filter on /admin/free_entries.
#
# The operator's job it serves: a TikTok video says "type turfmonster.media/tiktok
# for a free entry", signups land with users.reference = "tiktok", and Alex
# hand-mints for them here. So the filter has to hold on EVERY path that puts
# rows on the page — the first render, each lazily streamed batch, and the
# redirect back after a row action — or the table quietly fills with everyone.
class Admin::FreeEntriesSourceFilterTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)
    @tiktok = users(:sam)
    @other  = users(:casey)
    @tiktok.update_columns(reference: "tiktok", slug: "sam-source")
    @other.update_columns(reference: "friends-test", slug: "casey-source")
    log_in_as(@admin)
  end

  # Which of the two wallet users have a row: each row's Act-as form routes on
  # the user's slug, so the slug appears in the tbody exactly when the row does.
  def row_slugs
    css_select("#users-tbody").first.to_s.scan(/\b(sam-source|casey-source)\b/).flatten.uniq
  end

  test "unfiltered, every wallet user is listed with their source" do
    get admin_free_entries_path

    assert_response :success
    assert_select "td[data-test='signup-source']", text: "tiktok"
    assert_select "td[data-test='signup-source']", text: "friends-test"
    assert_equal %w[casey-source sam-source], row_slugs.sort
  end

  test "?reference=tiktok lists only the TikTok signups" do
    get admin_free_entries_path(reference: "tiktok")

    assert_response :success
    assert_equal %w[sam-source], row_slugs
    assert_select "td[data-test='signup-source']", text: "friends-test", count: 0
    assert_match "Users from tiktok", response.body
  end

  test "the filter's select offers each source with its count and keeps the choice" do
    get admin_free_entries_path(reference: "tiktok")

    assert_select "select#reference option[value='']", text: "All sources"
    assert_select "select#reference option[value='tiktok'][selected]", text: "tiktok (1)"
    assert_select "select#reference option[value='friends-test']", text: "friends-test (1)"
  end

  test "a source nobody signed up from yet still shows as selected, with an empty table" do
    get admin_free_entries_path(reference: "instagram")

    assert_response :success
    assert_select "select#reference option[value='instagram'][selected]", text: "instagram (0)"
    assert_match "No users from instagram with Solana wallets yet.", response.body
    assert_empty row_slugs
  end

  test "a streamed batch honours the filter" do
    get admin_free_entries_path(page: 1, reference: "tiktok"),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, "sam-source"
    refute_includes response.body, "casey-source",
      "a filtered page must not stream in other sources' users on the next batch"
  end

  test "the next-batch trigger carries the filter on its fetch" do
    # 11 TikTok wallet users → two pages at PER_PAGE 10, so page 1 renders a trigger.
    10.times do |i|
      User.create!(email: "tt#{i}@example.com", username: "tiktoker#{i}",
                   web3_solana_address: "TikTokWallet#{i}#{'x' * 30}"[0, 44], reference: "tiktok")
    end

    get admin_free_entries_path(reference: "tiktok")

    assert_select "#load-trigger"
    assert_includes css_select("#load-trigger").first["x-init"],
                    admin_free_entries_path(page: 2, reference: "tiktok")
  end

  test "row actions carry the filter so their redirect comes back filtered" do
    get admin_free_entries_path(reference: "tiktok")

    assert_select "form[action=?]", admin_impersonate_path(@tiktok.slug) # sanity: row rendered
    # The null_store keeps every row cold (no Mint/Grant/Burn), so pin the
    # redirect itself: an action posted with the filter returns to it.
    Solana::Vault.stub :new, FakeVault.new do
      post admin_grant_free_entries_path(user_slug: @tiktok.slug, minted: 0, reference: "tiktok")
    end
    assert_redirected_to admin_free_entries_path(reference: "tiktok")
  end
end
