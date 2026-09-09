require "test_helper"

# Admin::EntryGiftsController — the operator's send form and gift ledger.
class Admin::EntryGiftsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @user  = users(:sam)
  end

  # --- the admin gate ---

  test "index redirects non-admins" do
    log_in_as(@user)
    get admin_entry_gifts_path
    assert_response :redirect
  end

  test "create refuses a non-admin and sends nothing" do
    log_in_as(@user)
    assert_no_difference -> { EntryGift.count } do
      post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }
    end
  end

  # --- the form ---

  test "index renders the send form and the ledger" do
    EntryGift.create!(recipient_email: "already@example.com", sender: @admin)
    log_in_as(@admin)
    get admin_entry_gifts_path

    assert_response :success
    assert_select "form[action=?]", admin_entry_gifts_path
    assert_select "input[name=recipient_email]"
    assert_select "textarea[name=note]"
    assert_match "already@example.com", response.body
  end

  test "index renders the empty state with no gifts" do
    log_in_as(@admin)
    get admin_entry_gifts_path
    assert_response :success
    assert_match "No gifts sent yet", response.body
  end

  # THE CONDITION THAT SILENTLY BREAKS THE FEATURE, and therefore must be on
  # screen: with the legal-age attestation on, a gift link cannot CREATE an
  # account (MagicLinksController#sign_up_new refuses one carrying no
  # attestation, and an operator cannot attest for a stranger).
  test "warns on the form while legal-age attestation is on" do
    log_in_as(@admin)
    AppFlags.stub :age_attestation?, true do
      get admin_entry_gifts_path
      assert_match "ENABLE_AGE_ATTESTATION", response.body
    end
  end

  test "no attestation warning when the flag is off" do
    log_in_as(@admin)
    AppFlags.stub :age_attestation?, false do
      get admin_entry_gifts_path
      assert_no_match(/ENABLE_AGE_ATTESTATION/, response.body)
    end
  end

  # --- sending ---

  test "create records the gift, mints a link and queues the email" do
    log_in_as(@admin)

    assert_difference -> { EntryGift.count }, 1 do
      assert_difference -> { EmailDelivery.count }, 1 do
        post admin_entry_gifts_path, params: { recipient_email: " Friend@Example.com ",
                                               contest_slug: contests(:one).slug,
                                               note: "come play" }
      end
    end

    gift = EntryGift.order(:created_at).last
    assert_equal "friend@example.com", gift.recipient_email
    assert_equal @admin, gift.sender
    assert_equal contests(:one), gift.contest
    assert_equal "come play", gift.note
    assert_redirected_to admin_entry_gifts_path
  end

  # The link is what makes the gift findable at consume time. Without the
  # polymorphic owner the click is an ordinary sign-in and the entry is never
  # granted — so this asserts the wiring, not merely that a link exists.
  test "the minted link owns the gift and outlives a sign-in link" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }

    gift = EntryGift.order(:created_at).last
    link = gift.link

    assert link.present?, "the gift must carry its link"
    assert_equal "magic_link", link.kind
    assert_equal gift, link.linkable
    assert_equal "friend@example.com", link.metadata["email"]
    assert_operator link.expires_at, :>, 20.days.from_now,
                    "a gift sits in an inbox; it must not expire like a 15-minute sign-in link"
  end

  test "the link lands on the chosen contest" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com",
                                           contest_slug: contests(:one).slug }

    assert_equal contest_path(contests(:one)), EntryGift.order(:created_at).last.link.metadata["return_to"]
  end

  test "a bad email is a flash, not a record and not a 500" do
    log_in_as(@admin)

    assert_no_difference -> { EntryGift.count } do
      post admin_entry_gifts_path, params: { recipient_email: "nope" }
    end
    assert_redirected_to admin_entry_gifts_path
    assert_match(/not a valid email/, flash[:alert])
  end

  # --- the four ledger states, RENDERED ---
  #
  # Acceptance 6 asks for sent / claimed / minted / failed to be VISIBLE on the
  # ledger, and only :sent was ever observed on screen. EntryGift#status is
  # exhaustively unit-tested, but the label and colour come from two literal
  # hashes in _gift_row.html.erb — a typo in either renders an EMPTY status cell
  # with every unit test still green. These assert the string a human reads.

  test "the ledger renders every gift state" do
    log_in_as(@admin)
    sent    = EntryGift.create!(recipient_email: "sent@example.com", sender: @admin)
    claimed = EntryGift.create!(recipient_email: "claimed@example.com", sender: @admin)
    minted  = EntryGift.create!(recipient_email: "minted@example.com", sender: @admin)
    failed  = EntryGift.create!(recipient_email: "failed@example.com", sender: @admin)

    claimed.update!(claimed_by: @user, claimed_at: 1.minute.ago)
    minted.update!(claimed_by: @user, claimed_at: 1.hour.ago, minted_at: Time.current,
                   mint_signature: "sig_rendered")
    failed.update!(claimed_by: @user, claimed_at: 1.hour.ago, mint_error: "no wallet to mint to")

    get admin_entry_gifts_path
    assert_response :success

    assert_select "tr", text: /sent@example\.com.*Sent/m
    assert_select "tr", text: /claimed@example\.com.*Claimed — minting/m
    assert_select "tr", text: /minted@example\.com.*Minted/m
    assert_select "tr", text: /failed@example\.com.*Mint failed/m
    # The failure's REASON is on screen too — a state with no explanation sends
    # the operator to the logs.
    assert_match "no wallet to mint to", response.body
    assert_equal 4, EntryGift.count
  end

  # The state the ledger exists to make loud: claimed long ago, still no token.
  # It renders as its own label rather than sitting quietly as "Claimed".
  test "a stalled claim says so, distinctly from a fresh one" do
    log_in_as(@admin)
    stalled = EntryGift.create!(recipient_email: "stalled@example.com", sender: @admin)
    stalled.update!(claimed_by: @user, claimed_at: 30.minutes.ago)

    get admin_entry_gifts_path
    assert_select "tr", text: /stalled@example\.com.*mint stalled/m
  end

  # --- the dev-only claim link ---
  #
  # On a desk the invite is CAPTURED, not sent (LOCAL_EMAIL_CAPTURE=1), and the
  # engine's local inbox can only build an "open" button for four hardcoded email
  # keys — this one is not among them. Without this link the operator cannot try
  # their own feature without hand-assembling /l/<token> from an args preview.

  test "an unclaimed gift shows its claim link outside production" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }
    gift = EntryGift.order(:created_at).last

    get admin_entry_gifts_path
    assert_select "a[href=?]", link_path(token: gift.link.token)
  end

  test "a claimed gift shows no claim link" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }
    gift = EntryGift.order(:created_at).last
    token = gift.link.token
    gift.update!(claimed_by: @user, claimed_at: Time.current)

    get admin_entry_gifts_path
    assert_select "a[href=?]", link_path(token: token), count: 0
  end

  # THE GATE THAT MATTERS: this is a live single-use credential for somebody
  # else's account, and a QA app boots in the PRODUCTION env, so it must be
  # hidden there exactly as in real production.
  #
  # Stubs the PREDICATE, never Rails.env itself. Stubbing the environment is
  # global for the request, and Solana::Config raises OPSEC-012 at autoload time
  # under it — so that version of this test was green or red depending on the
  # seed (111 red, 222/333/444 green). See EntryGift.claim_links_visible?.
  test "the claim link is hidden where claim links are not visible" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }
    gift = EntryGift.order(:created_at).last

    EntryGift.stub :claim_links_visible?, false do
      get admin_entry_gifts_path
      assert_select "a[href=?]", link_path(token: gift.link.token), count: 0
      assert_match "friend@example.com", response.body, "the row itself still renders"
    end
  end

  # The predicate's own contract, asserted directly rather than through a render:
  # production hides, everywhere else shows.
  test "claim links are visible outside production only" do
    assert EntryGift.claim_links_visible?, "visible in test/development"
  end

  # --- re-send ---

  test "resend replaces the link rather than reusing a spent one" do
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: "friend@example.com" }
    gift = EntryGift.order(:created_at).last
    original_token = gift.link.token

    assert_difference -> { EmailDelivery.count }, 1 do
      post admin_resend_entry_gift_path(gift)
    end

    assert_not_equal original_token, gift.reload.link.token
    assert_nil Studio::Link.find_by(token: original_token), "the old link must stop working"
    assert_equal gift.mint_ref, EntryGift.find(gift.id).mint_ref, "the idempotency key must not be re-rolled"
  end

  test "resend refuses a claimed gift" do
    log_in_as(@admin)
    gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @admin)
    gift.update!(claimed_by: @user, claimed_at: Time.current)

    assert_no_difference -> { EmailDelivery.count } do
      post admin_resend_entry_gift_path(gift)
    end
    assert_match(/already claimed/, flash[:alert])
  end

  # --- retry mint ---

  test "retry_mint re-queues a stalled claim and clears the error" do
    log_in_as(@admin)
    gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @admin)
    gift.update!(claimed_by: @user, claimed_at: 1.hour.ago, mint_error: "RPC timeout")

    assert_enqueued_with(job: EntryGiftMintJob, args: [gift.id]) do
      post admin_retry_mint_entry_gift_path(gift)
    end
    assert_nil gift.reload.mint_error
  end

  test "retry_mint refuses an unclaimed gift" do
    log_in_as(@admin)
    gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @admin)

    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      post admin_retry_mint_entry_gift_path(gift)
    end
    assert_match(/hasn't claimed/, flash[:alert])
  end

  test "retry_mint refuses an already-minted gift" do
    log_in_as(@admin)
    gift = EntryGift.create!(recipient_email: "friend@example.com", sender: @admin)
    gift.update!(claimed_by: @user, claimed_at: 1.hour.ago, minted_at: Time.current)

    assert_no_enqueued_jobs(only: EntryGiftMintJob) do
      post admin_retry_mint_entry_gift_path(gift)
    end
    assert_match(/Already minted/, flash[:alert])
  end
end
