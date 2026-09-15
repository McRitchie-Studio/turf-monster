require "test_helper"

# AccountsController#link_solana must refuse to strand a free entry.
#
# THE SHAPE OF THE FAULT, measured on the real consume path before any of this
# was written: a gifted account claims its voucher into a MANAGED wallet, links
# a Phantom, and User#solana_address — `web3_solana_address ||
# web2_solana_address` — stops resolving to the address the voucher was minted
# at. The token is on chain and cannot be moved. Nothing in the app noticed:
# combo_wallets? true, WalletSetupPolicy.required? false.
#
# THE QUEUED-MINT WINDOW IS WHAT THESE EXERCISE, deliberately. A gift claimed
# but not yet minted is decidable from columns alone, so the guard is proven
# here without an RPC — the same window WalletSetupPolicy#holds_free_entry?
# exists for, and the one a token-only check would sail through.
class WalletLinkVoucherGuardTest < ActionDispatch::IntegrationTest
  def gifted_user
    user = User.create!(email: "guarded-#{SecureRandom.hex(4)}@example.com",
                        email_verified_at: Time.current)
    user.update_columns(web2_solana_address: "ManagedGuard#{SecureRandom.hex(12)}",
                        web3_solana_address: nil)
    user.reload
  end

  def claim_gift_for(user)
    EntryGift.create!(recipient_email: user.email, sender: users(:alex)).tap do |gift|
      gift.update!(claimed_by: user, claimed_at: Time.current,
                   wallet_address: user.web2_solana_address)
    end
  end

  # A signature this app would reject anyway — the point is WHICH refusal comes
  # back. The guard runs before verification, so a blocked request never gets
  # as far as reading these.
  def link_params
    { message: "unused", signature: "unused", pubkey: "PhantomIncoming#{SecureRandom.hex(10)}" }
  end

  test "linking a wallet is refused while an unspent voucher is still held" do
    user = gifted_user
    claim_gift_for(user)
    log_in_as(user)

    post link_solana_account_path, params: link_params

    assert_response :unprocessable_entity
    assert_equal AccountsController::STRANDED_VOUCHER_ERROR,
                 response.parsed_body["error"],
                 "the refusal must name the free entry, not a generic wallet error"
    assert_nil user.reload.web3_solana_address,
               "the account must be left exactly as it was"
  end

  # THE REFUSAL HAS TO LAND BEFORE THE SIGNATURE, and the STATUS is what proves
  # it. A user who has already signed and is then told no is the one shape the
  # wallet-error path warns about (see the layout's verify comment): the step
  # that proved their wallet fine is the step that precedes the refusal.
  #
  # The params below are garbage, so verification would raise
  # Solana::AuthVerifier::VerificationError and the action's own rescue would
  # answer 401. A 422 carrying the voucher copy can therefore only have come
  # from before that call.
  test "the refusal arrives without the signature being verified" do
    user = gifted_user
    claim_gift_for(user)
    log_in_as(user)

    post link_solana_account_path, params: link_params

    assert_response :unprocessable_entity
    assert_equal AccountsController::STRANDED_VOUCHER_ERROR, response.parsed_body["error"]
  end

  # THE CONTROL FOR THAT ORDERING CLAIM. The same garbage params with no gift on
  # the account DO reach verification, and answer with its refusal instead —
  # so the status above is a real discriminator and not a constant.
  test "the same garbage signature reaches verification when nothing is held" do
    log_in_as(gifted_user)

    post link_solana_account_path, params: link_params

    assert_response :unauthorized
  end

  # THE CONTROL, and without it every test above passes for a guard that refuses
  # every wallet link ever attempted. Same user, same request, NO gift — the
  # guard stands aside and the request reaches the signature check, which
  # rejects it for its own (different) reason.
  test "an account holding no voucher is not blocked by this guard" do
    user = gifted_user
    log_in_as(user)

    post link_solana_account_path, params: link_params

    assert_not_equal AccountsController::STRANDED_VOUCHER_ERROR, response.parsed_body["error"],
                     "a user with no gift must not meet the voucher refusal"
  end

  # A spent gift releases the block — the bypass lasts exactly as long as the
  # free entry does. Modelled here as the mint having failed unpayably, which is
  # the other way a gift stops being a live claim on the managed wallet.
  test "an unpayable gift does not block the wallet link forever" do
    user = gifted_user
    claim_gift_for(user).update!(mint_error: EntryGifts::Claim::ADMIN_REASON)
    log_in_as(user)

    post link_solana_account_path, params: link_params

    assert_not_equal AccountsController::STRANDED_VOUCHER_ERROR, response.parsed_body["error"]
  end

  # Already web3: #solana_address resolves to the Phantom either way, so
  # refusing would only trap the account rather than protect anything.
  test "an account that already holds a phantom is not blocked" do
    user = gifted_user
    claim_gift_for(user)
    user.update_columns(web3_solana_address: "AlreadyPhantom#{SecureRandom.hex(10)}")
    log_in_as(user)

    post link_solana_account_path, params: link_params

    assert_not_equal AccountsController::STRANDED_VOUCHER_ERROR, response.parsed_body["error"]
  end
end
