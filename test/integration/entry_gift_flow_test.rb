require "test_helper"

# The whole gift, end to end: the operator sends one, a stranger clicks it, and
# a playable free entry lands on an account that did not exist a moment ago.
#
# This is the tier that would have caught every seam the unit tests each pass in
# isolation — the link carrying the gift, the consume path finding it, the
# wallet being minted under web3-only onboarding, and the token being paid to
# THAT wallet.
class EntryGiftFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  RECIPIENT = "brand-new-friend@example.com".freeze

  setup do
    @admin = users(:alex)
    @contest = contests(:one)
    # The season's onboarding: a fresh signup gets NO wallet of its own.
    @web3_only = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
  end

  teardown { ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = @web3_only }

  def send_gift(note: "come play")
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: RECIPIENT,
                                           contest_slug: @contest.slug, note: note }
    EntryGift.order(:created_at).last
  end

  test "operator sends, stranger clicks, and a free entry is minted to a new account" do
    assert_nil User.find_by(email: RECIPIENT), "precondition: no such account"

    gift = send_gift
    token = gift.link.token
    reset! # the recipient is a different browser entirely

    # The emailed GET is inert (scanner-safe); only the human's POST consumes.
    get link_path(token: token)
    assert_response :success
    assert_nil User.find_by(email: RECIPIENT), "a scanner's GET must not create the account"

    assert_enqueued_with(job: EntryGiftMintJob) do
      post link_consume_path(token: token)
    end

    # The account exists, is signed in, and landed on the contest it was invited to.
    recipient = User.find_by(email: RECIPIENT)
    assert recipient.present?, "the click creates the account"
    assert_redirected_to contest_path(@contest)

    # THE OPERATOR'S CALL, proven end to end: a managed wallet even though
    # web3-only onboarding is on, or there is no address to mint the gift to.
    assert recipient.web2_solana_address.present?,
           "a gifted account must be given a wallet despite web3-only onboarding"

    gift.reload
    assert gift.claimed?
    assert_equal recipient, gift.claimed_by
    assert_equal recipient.solana_address, gift.wallet_address

    # Now pay it, with the chain faked at the vault boundary.
    vault = FakeVault.new
    Solana::Vault.stub :ensure_program_id_live!, :live do
      Solana::Vault.stub :new, vault do
        perform_enqueued_jobs(only: EntryGiftMintJob)
      end
    end

    assert_equal [gift.mint_source_ref], vault.mint_calls
    assert_equal [recipient.solana_address], vault.mint_wallets
    assert gift.reload.minted?
    assert gift.mint_signature.present?
  end

  test "a gift to someone who already has an account is claimed on sign-in" do
    existing = users(:sam)
    gift = EntryGift.create!(recipient_email: existing.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: existing.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    reset!

    assert_no_difference -> { User.count } do
      post link_consume_path(token: link.token)
    end

    gift.reload
    assert_equal existing, gift.claimed_by
    assert_equal existing.solana_address, gift.wallet_address, "an existing wallet is reused"
  end

  # A SECOND CLICK MUST NOT COST THEM ANYTHING. The link is single-use, so the
  # re-click is dead — and a dead link must leave the session alone and the gift
  # exactly as it was (one claim, one mint, no second token).
  test "re-clicking a spent gift link grants nothing further" do
    gift = send_gift
    token = gift.link.token
    reset!

    post link_consume_path(token: token)
    first_claimed_at = gift.reload.claimed_at

    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      post link_consume_path(token: token)
    end
    assert_equal first_claimed_at.to_i, gift.reload.claimed_at.to_i
  end

  # An ordinary sign-in link carries no gift, and must stay ordinary.
  test "a plain magic link grants no entry" do
    reset!
    token = Studio::Link.create_magic_link(email: "nobody-special@example.com").token

    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      post link_consume_path(token: token)
    end
    assert_equal 0, EntryGift.count
  end

  # The gift's own toast replaces the stock "grab an entry token" copy — telling
  # someone who was just handed an entry to go buy one is the one thing this
  # flow must not say.
  #
  # The recipient is set up with NOTHING outstanding (a first name, a linked
  # wallet), because the toast is deliberately suppressed whenever an onboarding
  # modal is about to open — a toast under a modal just talks over it. Without
  # that setup this test asserts nothing at all, which is exactly how its first
  # draft passed: `steps` came back [:first_name], the flash was empty, and the
  # conditional it was wrapped in swallowed the whole assertion.
  test "the sign-in toast says the entry is already theirs" do
    existing = users(:sam)
    existing.update!(first_name: "Sam")
    assert_empty OnboardingFlow.steps_for(existing), "precondition: nothing outstanding"

    gift = EntryGift.create!(recipient_email: existing.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: existing.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    reset!

    post link_consume_path(token: link.token)
    toast = flash[:auth_toast]

    assert toast.present?, "a completed account gets a toast"
    assert_match(/free entry/i, toast["title"] || toast[:title])
    assert_match(/#{@admin.name}/, (toast["message"] || toast[:message]).to_s)
    assert_no_match(/grab an entry token/i, (toast["message"] || toast[:message]).to_s)
  end

  # The control for the test above: WITHOUT a gift, the same completed account
  # gets the ordinary welcome-back copy. Without this the assertion above cannot
  # tell "the gift changed the toast" from "this is what the toast always says".
  test "a plain sign-in keeps the ordinary welcome copy" do
    existing = users(:sam)
    existing.update!(first_name: "Sam")
    token = Studio::Link.create_magic_link(email: existing.email).token
    reset!

    post link_consume_path(token: token)
    toast = flash[:auth_toast]

    assert_match(/welcome back/i, toast["title"] || toast[:title])
  end
end
