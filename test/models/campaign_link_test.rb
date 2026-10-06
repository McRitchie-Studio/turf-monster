require "test_helper"

# [unit] CampaignLink: a human-named /l/<token> stored as a Studio::Link —
# its token rules, its collisions with the other /l/ tenants, and the URL a
# click is sent to.
class CampaignLinkTest < ActiveSupport::TestCase
  def build(**attrs)
    CampaignLink.new({ token: "tt", target_path: "/turf-monster-v2", reference: "tiktok-bio" }.merge(attrs))
  end

  def errors_on(attr, **attrs)
    link = build(**attrs)
    link.valid?
    link.errors[attr]
  end

  # --- storage ----------------------------------------------------------------

  test "is stored as an ownerless referral Studio::Link marked as a campaign" do
    link = build
    link.save!

    row = Studio::Link.find_by(token: "tt")
    assert_equal "referral", row.kind
    assert_nil row.linkable
    assert_nil row.expires_at
    assert_equal({ "campaign" => true, "target" => "/turf-monster-v2", "reference" => "tiktok-bio" }, row.metadata)
  end

  test "the scope holds campaigns only: not magic links, not a user's referral link" do
    build.save!
    Studio::Link.create_magic_link(email: "x@example.com")
    Studio::Link.referral_for(users(:jordan))

    assert_equal ["tt"], CampaignLink.pluck(:token)
  end

  test "a user's referral link never picks up a campaign row" do
    build.save!
    referral = Studio::Link.referral_for(users(:jordan), target: "/turf-monster-v2")
    assert_not_equal "tt", referral.token
    assert_equal users(:jordan), referral.linkable
  end

  # --- token rules --------------------------------------------------------------

  test "the token is lowercased and stripped before it is checked" do
    link = build(token: "  TikTok-2 ")
    assert link.valid?, link.errors.full_messages.to_sentence
    assert_equal "tiktok-2", link.token
  end

  test "the token is 2 to 32 lowercase letters, digits and inner hyphens" do
    assert_empty errors_on(:token, token: "tt")
    assert_empty errors_on(:token, token: "a" * 32)
    assert_not_empty errors_on(:token, token: "t")
    assert_not_empty errors_on(:token, token: "a" * 33)
    assert_not_empty errors_on(:token, token: "-tt")
    assert_not_empty errors_on(:token, token: "tt-")
    assert_not_empty errors_on(:token, token: "t_t")
    assert_not_empty errors_on(:token, token: "t/t")
    assert_not_empty errors_on(:token, token: "")
  end

  test "reserved words are refused" do
    %w[new edit admin lp login].each do |word|
      assert_includes errors_on(:token, token: word), "is reserved", word
    end
  end

  test "a token already held by any studio link is refused" do
    magic = Studio::Link.create!(kind: "magic_link", token: "promo", expires_at: 1.hour.from_now)
    assert_includes errors_on(:token, token: magic.token), "has already been taken"

    build.save!
    assert_includes errors_on(:token, token: "tt", reference: "other"), "has already been taken"
  end

  test "a landing page's slug is refused, so an old /l/<slug> link keeps reaching it" do
    slug = landing_pages(:launch).slug
    assert_match(/landing page/, errors_on(:token, token: slug).to_sentence)
  end

  test "an existing link is not re-judged against a landing page made after it" do
    link = build(token: "later-page")
    link.save!
    LandingPage.create!(name: "Later", slug: "later-page")

    link.reference = "renamed"
    assert link.valid?, link.errors.full_messages.to_sentence
  end

  # --- target and reference ------------------------------------------------------

  test "the target must be a path on this site" do
    assert_empty errors_on(:target_path, target_path: "/turf-monster-v2?utm_source=bio#drop")
    ["", "turf-monster-v2", "//evil.example", "/\\evil.example", "https://evil.example/", "/has space"].each do |bad|
      assert_not_empty errors_on(:target_path, target_path: bad), bad.inspect
    end
  end

  test "the target cannot be another short link" do
    assert_not_empty errors_on(:target_path, target_path: "/l/other")
    assert_not_empty errors_on(:target_path, target_path: "/i/abc")
    assert_empty errors_on(:target_path, target_path: "/lp/tiktok")
  end

  test "the reference is required and normalized like every reference" do
    assert_equal "tiktok-bio", build(reference: "  TikTok-Bio ").reference
    assert_includes errors_on(:reference, reference: "   "), "can't be blank"
  end

  # --- resolution ---------------------------------------------------------------

  test "the destination appends r to the target" do
    assert_equal "/turf-monster-v2?r=tiktok-bio", build.destination
  end

  test "the target's own query and fragment survive" do
    link = build(target_path: "/turf-monster-v2?utm_source=tiktok#drop")
    assert_equal "/turf-monster-v2?utm_source=tiktok&r=tiktok-bio#drop", link.destination
  end

  test "the short link's own query rides along, but its reference is the one that counts" do
    link = build(target_path: "/?reference=old&r=older")
    assert_equal "/?utm_medium=bio&r=tiktok-bio",
                 link.destination("utm_medium" => "bio", "r" => "spoofed", "reference" => "spoofed")
  end

  test "resolve finds a campaign by its token in any case, and nothing else" do
    build.save!
    magic = Studio::Link.create_magic_link(email: "x@example.com")

    assert_equal "tt", CampaignLink.resolve("tt")&.token
    assert_equal "tt", CampaignLink.resolve("TT")&.token
    assert_nil CampaignLink.resolve(magic.token)
    assert_nil CampaignLink.resolve("nope")
    assert_nil CampaignLink.resolve("")
  end

  test "disable and enable flip the link through expires_at" do
    link = build
    link.save!
    assert link.active?

    link.disable!
    assert_not link.reload.active?
    assert link.expires_at.present?

    link.enable!
    assert link.reload.active?
  end
end
