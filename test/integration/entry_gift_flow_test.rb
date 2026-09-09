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

  # THE THIRD OUTCOME. Studio::LinkConsumption's decision table has three
  # branches — :authenticate, :continue, :dead — and every other test in this
  # file signs out first (reset!), so they all exercise :authenticate. A
  # recipient who is ALREADY SIGNED IN as the gift's own address takes
  # :continue instead: the token burns, the session is deliberately left alone,
  # and before the link_continue override below, claim_entry_gift! never ran at
  # all. The gift stayed unclaimed forever with NO error anywhere — the ledger
  # read "Sent", stalled? could not see it (it requires claimed?), and a re-send
  # walked them straight back into the same cell.
  #
  # Ordinary trigger: gift an existing player who reads their mail on the device
  # they are signed in on. Caught in review, not by any tier here.
  test "a recipient already signed in as the gift's own email still claims it" do
    existing = users(:sam)
    gift = EntryGift.create!(recipient_email: existing.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: existing.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)

    log_in_as(existing) # the ONLY difference from the tests above: no reset!

    assert_enqueued_with(job: EntryGiftMintJob) do
      post link_consume_path(token: link.token)
    end

    gift.reload
    assert gift.claimed?, "a signed-in recipient must not silently lose the gift"
    assert_equal existing, gift.claimed_by
    assert_equal existing.solana_address, gift.wallet_address
  end

  # The :continue path must stay INVISIBLE in every other respect — that is the
  # whole reason the engine routes it away from sign_in_existing. Claiming the
  # gift must not cost the viewer the session they already had.
  test "claiming on the signed-in path leaves the session alone" do
    existing = users(:sam)
    gift = EntryGift.create!(recipient_email: existing.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: existing.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)

    log_in_as(existing)
    post link_consume_path(token: link.token)

    # Still the same signed-in person, and still signed in.
    get account_path
    assert_response :success
    assert_equal existing, gift.reload.claimed_by
  end

  # THE RESCUE NOBODY WAS TESTING — the one path whose entire purpose is "never
  # 500 a signed-in visitor", and whose failure is invisible by construction: the
  # link is already burned, the gift stays :sent, and EntryGift#stalled? cannot
  # surface it because stalled? requires claimed?. So the ONLY trace it leaves is
  # the ErrorLog, and until now nothing asserted that trace existed.
  #
  # Raised from the service, which is where a real failure would come from (a
  # wallet-generation fault, a DB blip mid-claim).
  test "a claim that raises still signs the visitor in, and files an ErrorLog" do
    gift = EntryGift.create!(recipient_email: RECIPIENT, sender: @admin)
    link = Studio::Link.create_magic_link(email: RECIPIENT, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    reset!

    boom = ->(*) { raise "wallet generation exploded" }
    assert_difference -> { ErrorLog.count }, 1 do
      EntryGifts::Claim.stub :call, boom do
        post link_consume_path(token: link.token)
      end
    end

    # The visitor is signed in and moving, NOT staring at a 500.
    assert_response :redirect
    assert User.find_by(email: RECIPIENT).present?, "the account was still created"

    # And the failure is attributable rather than silent.
    log = ErrorLog.order(:created_at).last
    assert_match(/wallet generation exploded/, log.message)

    # The gift is genuinely unclaimed — this asserts the DAMAGE the ErrorLog
    # exists to announce, so the test cannot pass by the claim quietly working.
    assert_not gift.reload.claimed?
  end

  # Telemetry must never be what turns a successful sign-in into a 500 — so a
  # failure INSIDE the error reporting is swallowed too. Without this the rescue
  # above is only half-proven: it would still 500 if ErrorLog itself were down.
  test "a failure inside the error reporting still does not 500 the visitor" do
    gift = EntryGift.create!(recipient_email: RECIPIENT, sender: @admin)
    link = Studio::Link.create_magic_link(email: RECIPIENT, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    reset!

    boom = ->(*) { raise "wallet generation exploded" }
    dead_log = ->(*) { raise "ErrorLog is down" }

    EntryGifts::Claim.stub :call, boom do
      ErrorLog.stub :capture!, dead_log do
        post link_consume_path(token: link.token)
      end
    end

    assert_response :redirect
    assert User.find_by(email: RECIPIENT).present?
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
