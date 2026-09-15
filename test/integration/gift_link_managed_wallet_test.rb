require "test_helper"

# The gifted newcomer's route into the app, and the two ways it can go wrong.
#
# MEASURED FIRST, and the measurement is what this file pins. For a first-time
# visitor clicking an emailed gift link, AUTHENTICATION HAPPENS BEFORE THE CLAIM:
# the link itself is the sign-up (MagicLinksController#sign_up_new creates the
# account and sets the session), and only then does claim_entry_gift! run. So
# EntryGifts::Claim#ensure_wallet! finds no address and mints a MANAGED one, and
# the voucher is stamped there. The happy path never puts a wallet choice in
# front of them at all.
#
# THE SIGN-IN CARD IS STILL REACHABLE, and that is what the nudge is for. A gift
# link is minted with `age_attested: false` (the operator cannot attest to a
# stranger's age), so while ENABLE_AGE_ATTESTATION is on the consume refuses to
# create the account and bounces the recipient to /signin — holding a live gift,
# in front of Google, Phantom and email. Pick Phantom there and they start a
# SECOND account, and the gift they came for claims to the wrong one.
class GiftLinkManagedWalletTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:alex)
    @contest = contests(:one)
    @web3_only = ENV["ENABLE_WEB3_ONLY_ONBOARDING"]
    @age = ENV["ENABLE_AGE_ATTESTATION"]
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = "true"
  end

  teardown do
    ENV["ENABLE_WEB3_ONLY_ONBOARDING"] = @web3_only
    ENV["ENABLE_AGE_ATTESTATION"] = @age
  end

  def send_gift(email)
    log_in_as(@admin)
    post admin_entry_gifts_path, params: { recipient_email: email, contest_slug: @contest.slug }
    EntryGift.order(:created_at).last
  end

  # The auth card's OWN wallet button. Scanning for the Solana mark or the
  # picker's open call would hit the shared modal host, which the layout renders
  # on every page signed out or not — an assertion on those passes for a
  # suppression that never happened.
  AUTH_SOLANA = "[data-auth-solana]".freeze

  # --- the measurement, pinned --------------------------------------------

  test "a first-time visitor is signed in before the claim, and the voucher is stamped at the managed wallet" do
    email = "gift-measure@example.com"
    gift = send_gift(email)
    reset!

    post link_consume_path(token: gift.link.token, wallet: "managed")

    recipient = User.find_by(email: email)
    gift.reload
    assert recipient.present?, "the click IS the sign-up"
    assert_operator recipient.created_at, :<=, gift.claimed_at,
                    "authentication must precede the claim, or ensure_wallet! decides a race"
    assert_equal :managed, recipient.wallet_kind
    assert_equal recipient.web2_solana_address, gift.wallet_address,
                 "the voucher must land where the SERVER can sign for it"
    assert_nil recipient.web3_solana_address
  end

  # --- the nudge ------------------------------------------------------------

  test "the emailed claim link carries the managed-wallet nudge" do
    gift = send_gift("gift-url@example.com")
    mail = EntryGiftMailer.gift_invite(gift, gift.link.token)
    # `.body.to_s` is EMPTY on a multipart mail — the text is in the parts. An
    # assertion on the empty string would have passed for `assert_not_includes`
    # and failed loudly here, which is how this was caught.
    body = mail.parts.map { |part| part.body.to_s }.join

    assert_includes body, "wallet=managed",
                     "the parameter has to be ON the link the recipient receives"
  end

  test "a gifted newcomer bounced to sign-in is not shown the wallet choice" do
    ENV["ENABLE_AGE_ATTESTATION"] = "true"
    gift = send_gift("gift-nudge@example.com")
    reset!

    post link_consume_path(token: gift.link.token, wallet: "managed")
    assert_redirected_to signin_path(wallet: "managed")
    follow_redirect!

    assert_response :success
    assert_select AUTH_SOLANA, false,
                  "a gifted newcomer must not meet a wallet choice they have no reason to make"
    # No trailing message strings here: assert_select reads a String third
    # argument as a TEXT TEST, not a failure message, so "the other ways in
    # must remain" was being asserted as the button's own text.
    assert_select "form[action=?]", "/auth/google_oauth2"
    assert_select "input#email"
  end

  # THE CONTROL. Same page, same bounce, no parameter — the wallet choice is
  # still there. Without this the assertion above passes for a card that never
  # renders the button at all.
  test "the same sign-in page without the nudge still offers the wallet" do
    get signin_path

    assert_response :success
    assert_select AUTH_SOLANA
  end

  # Piece 2, at the seam where a WALLET HOLDER actually meets it.
  #
  # A signed-in visitor cannot render the sign-in card at all (/signin bounces
  # them to /account), so the reachable case is a holder clicking a gift link
  # that has expired: Studio::LinkConsumption takes the dead path and bounces
  # through `link_login_path`, which is the one seam the nudge rides on. For a
  # Phantom holder it must come back CLEAN — hiding web3 auth from them does not
  # spare a choice, it pushes them into a second account.
  test "a dead gift link bounces a phantom holder to a sign-in with no nudge" do
    holder = User.create!(email: "dead-link-holder@example.com", email_verified_at: Time.current)
    holder.update_columns(web3_solana_address: "PhantomDead#{SecureRandom.hex(12)}")
    log_in_as(holder)

    get link_path(token: "no-such-token-at-all", wallet: "managed")

    assert_redirected_to signin_path,
                         "a wallet holder must be sent to the NORMAL sign-in"
    assert_not response.location.include?("wallet=managed")
  end

  # THE CONTROL FOR IT. Same dead link, same bounce, a visitor with no wallet —
  # the nudge holds. Without this the test above passes for a nudge that never
  # rides anywhere.
  test "a dead gift link keeps the nudge for a visitor with no wallet" do
    get link_path(token: "no-such-token-at-all", wallet: "managed")

    assert_redirected_to signin_path(wallet: "managed")
  end

  # A managed-only account is exactly who the nudge is FOR, so the wider
  # `solana_connected?` predicate (true for a managed wallet) would switch it
  # off for its own audience.
  test "a managed-only account still gets the nudge" do
    managed = User.create!(email: "managed-only@example.com", email_verified_at: Time.current)
    managed.update_columns(web2_solana_address: "ManagedOnly#{SecureRandom.hex(12)}",
                           web3_solana_address: nil)
    log_in_as(managed)

    get link_path(token: "no-such-token-at-all", wallet: "managed")

    assert_redirected_to signin_path(wallet: "managed")
  end
end
