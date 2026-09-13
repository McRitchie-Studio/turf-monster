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

  # THE PRODUCT CALL ON THIS PATH, pinned so it cannot be quietly reverted to
  # silence. Claiming the gift is necessary but not sufficient: a recipient who
  # taps "claim your free entry" and is shown NOTHING will tap it again, and the
  # second tap takes :dead and reads "link already used" — for a gift they
  # believe they never received. So :continue announces the ENTRY.
  #
  # The toast names the entry, never a sign-in, which is what makes it honest on
  # a path where no sign-in happened.
  test "a gift claimed on the signed-in path announces the entry" do
    existing = users(:sam)
    gift = EntryGift.create!(recipient_email: existing.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: existing.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)

    log_in_as(existing)
    post link_consume_path(token: link.token)

    toast = flash[:auth_toast]&.with_indifferent_access
    refute_nil toast, "a claimed gift must not land silently"
    assert_equal "You've got a free entry 🎟️", toast[:title]
    refute_match(/sign(ed)? in/i, toast[:message],
                 "this path announces the entry, not a sign-in that never happened")
  end

  # THE CONTROL for the test above, and the property it must not break: the
  # toast is scoped to gifts. A plain magic-link re-click still takes :continue
  # and must stay exactly as invisible as it was before the gift work — the
  # engine routes it away from sign_in_existing precisely so a re-click costs
  # the visitor nothing. (magic_link_reclick_test.rb asserts the same from the
  # engine's side; this states it in the gift suite, where the regression would
  # be introduced.)
  test "a gift-less re-click on the signed-in path still announces nothing" do
    existing = users(:sam)
    link = Studio::Link.create_magic_link(email: existing.email) # no linkable: no gift

    log_in_as(existing)
    post link_consume_path(token: link.token)

    assert_nil flash[:auth_toast], "a spent link of your own is not an event worth announcing"
  end

  # THE VERDICT THE CLAIM INVALIDATES. Signing in computes WalletSetupPolicy
  # once and caches it in session[:wallet_setup]; for an account with no wallet
  # that verdict is TRUE. The claim on this path then mints a managed wallet —
  # the one fact wallet_setup_required? short-circuits on — so the gate stops
  # short-circuiting and falls through to the cached TRUE. The page then tells
  # eligibilityBlocker to refuse every hold and open the wallet-setup card, for
  # the rest of the session, to a player holding the very entry that exists to
  # spare them that card. The :authenticate shapes never had this: they claim
  # BEFORE they record.
  test "a gift claimed on the signed-in path recomputes the cached wallet verdict" do
    recipient = users(:jordan)
    recipient.update_columns(web2_solana_address: nil, web3_solana_address: nil)

    log_in_as(recipient)
    # The sign-in's landing render spends its one-shot prompts, as a real
    # browser's does long before the recipient opens their mail.
    follow_redirects!
    assert_equal true, session[:wallet_setup],
                 "precondition: signing in without a wallet caches a TRUE verdict"

    gift = EntryGift.create!(recipient_email: recipient.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: recipient.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    post link_consume_path(token: link.token)

    assert recipient.reload.managed_wallet?,
           "precondition: the claim minted the wallet that ends the gate's short-circuit"
    assert_equal false, session[:wallet_setup],
                 "the claim must re-record the verdict it just made stale"
    # STATE, NOT A PROMPT. The :authenticate shapes arm the onboarding chain;
    # this path re-records only what the entry gate enforces, so a continuing
    # player is not walked through first-name and age cards they never asked
    # to see again. Jordan has no first name, so a chain armed here would show.
    assert_nil session[:onboarding_prompt],
               "the signed-in path must not start an onboarding beat"

    # The entry gate as the client reads it: eligibilityBlocker checks
    # walletSetupRequired ahead of every funding rail.
    follow_redirects!
    assert_includes response.body, '"walletSetupRequired":false'
  end

  # THE CONTROL: the verdict is RECOMPUTED, not cleared. An admin claimant holds
  # no custodial key (OPSEC-044), so the claim lands with a mint_error, mints no
  # wallet and buys no bypass. The same re-record must therefore still read
  # TRUE. A fix that simply wrote false after any claim would pass the test
  # above and fail this one.
  test "a claim that buys no bypass leaves the wallet verdict standing" do
    log_in_as(@admin)
    follow_redirects!
    assert_equal true, session[:wallet_setup],
                 "precondition: an admin with no wallet signs in with a TRUE verdict"

    gift = EntryGift.create!(recipient_email: @admin.email, sender: @admin)
    link = Studio::Link.create_magic_link(email: @admin.email, linkable: gift,
                                          ttl: EntryGift::LINK_TTL)
    post link_consume_path(token: link.token)

    gift.reload
    assert gift.claimed?, "precondition: the claim landed"
    assert_equal EntryGifts::Claim::ADMIN_REASON, gift.mint_error,
                 "precondition: an admin's gift can never be minted"
    assert_equal true, session[:wallet_setup],
                 "a claim that grants no entry must not lift the wallet gate"
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

  # --- the aunt test (operator QA, 2026-09-09) ---
  #
  # The whole promise of gifting an entry is that the recipient does not have to
  # understand Solana. On QA a gifted player was still walked into "Set up your
  # wallet" twice — as step 3 of the onboarding chain, and again on
  # hold-to-confirm after a refresh. Both are driven by ONE verdict computed at
  # sign-in, so this asserts at that seam.

  test "a gifted signup is never asked to set up a wallet" do
    gift = send_gift
    token = gift.link.token
    reset!

    post link_consume_path(token: token)
    recipient = User.find_by(email: RECIPIENT)
    assert recipient.present?

    # The chain the client is told to walk. Wallet must NOT be in it — that is
    # the modal the operator hit after first name → dob.
    steps = session[:onboarding_prompt] || []
    assert_not_includes steps, "wallet",
                        "a gifted player must not be sent to wallet setup"

    # And the session-level verdict the hold-to-confirm blocker reads
    # (client_session_payload.walletSetupRequired -> eligibilityBlocker, which is
    # checked BEFORE tokensAvailable — which is why hold-to-confirm blocked).
    assert_not session[:wallet_setup],
               "the wallet gate must be off for an account holding a free entry"
  end

  # THE CONTROL, and it is what stops the test above from passing vacuously: an
  # ordinary signup with NO gift, same flag, still gets the wallet step. Without
  # it, deleting the whole wallet gate would leave the assertion above green.
  test "an ordinary signup is still asked to set up a wallet" do
    reset!
    token = Studio::Link.create_magic_link(email: "no-gift-here@example.com").token
    post link_consume_path(token: token)

    assert User.find_by(email: "no-gift-here@example.com").present?
    assert session[:wallet_setup],
           "web3-only onboarding must still nudge a wallet-less signup"
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
