require "test_helper"

# [component] The desktop-only declaration, as MARKUP, on the three admin pages
# that own a wallet flow.
#
# WHAT THIS TIER CAN AND CANNOT SEE. It cannot see the notice appear — that is a
# UA branch a browser runs, and e2e/admin_desktop_only.spec.js is the only tier
# that can witness it. What it CAN see is the structure that branch depends on,
# and every piece of it is something a well-meaning edit removes without any
# other test noticing:
#
#   · the notice partial is rendered on the page at all,
#   · it ships HIDDEN, so a desktop operator sees nothing new,
#   · its message slot is EMPTY — the sentence is not written into the server
#     response, because it comes from walletProvider.desktopOnlyMessage() and a
#     second copy here is a second copy to drift, and
#   · every button that starts a wallet flow carries the marker the gate
#     disables it by.
#
# The last one is the one worth having. The gate disables
# `[data-desktop-only-action]`; a button added later without that attribute
# stays live on a phone and nothing else in the suite would say so.
#
# DELIBERATELY NOT ASSERTED HERE: anything about the inline script's SOURCE
# TEXT. A string appearing in a response body is not evidence that a browser
# runs it — an ERB comment that terminates early can open a phantom element
# that swallows a whole script while every token in it still greps clean. The
# behaviour belongs to the e2e tier.
class AdminDesktopOnlyNoticeTest < ActionDispatch::IntegrationTest
  NOTICE = "#wallet-desktop-only-notice".freeze

  setup { log_in_as(users(:alex)) }

  # vault_init renders its form only when the vault is UNINITIALIZED, and
  # FakeVault's default read_vault_state returns a populated hash — so the
  # uninitialized branch needs a double that answers nil.
  class UninitializedVault
    def read_vault_state(**_opts) = nil
  end

  # vault_state renders its pause/unpause card only when the vault EXISTS, and
  # the view calls .length on :signers, which FakeVault's default omits.
  def initialized_vault
    vault = FakeVault.new
    vault.vault_state = {
      pda: "vault-pda",
      threshold: 2,
      signers: Solana::Config::MULTISIG_SIGNERS,
      paused: false,
      usdc_mint: Solana::Config::USDC_MINT,
      usdt_mint: Solana::Config::USDT_MINT,
      vault_usdc: "11111111111111111111111111111111",
      vault_usdt: "11111111111111111111111111111111",
      treasury_authority: "11111111111111111111111111111111",
      accepted_currencies: []
    }
    vault
  end

  def assert_hidden_notice(page)
    assert_select "#{NOTICE}[hidden]", 1,
      "#{page}: the desktop-only notice must render HIDDEN — a desktop operator " \
      "signs from this page normally and must see nothing new"
    assert_select "#{NOTICE} [data-desktop-only-message]", 1,
      "#{page}: the notice lost the slot the shared sentence is painted into"
  end

  def assert_message_not_baked_in(page)
    slot = css_select("#{NOTICE} [data-desktop-only-message]").first
    assert slot, "#{page}: no message slot to check"
    assert_equal "", slot.text.strip,
      "#{page}: the desktop-only sentence was written into the server response. It must come " \
      "from walletProvider.desktopOnlyMessage(), which is the same source the click-time throw " \
      "uses — two copies are two copies to drift"
  end

  test "vault init declares itself desktop only and marks its signing button" do
    Solana::Vault.stub :new, UninitializedVault.new do
      get admin_vault_init_path
    end
    assert_response :success

    assert_hidden_notice("admin/vault_init")
    assert_message_not_baked_in("admin/vault_init")
    assert_select "#vault-init-btn[data-desktop-only-action]", 1,
      "admin/vault_init: the Connect Phantom + Sign button is not marked, so the gate " \
      "cannot disable it on a phone"
  end

  test "vault state declares itself desktop only and marks its pause button" do
    Solana::Vault.stub :new, initialized_vault do
      get admin_vault_state_path
    end
    assert_response :success

    assert_hidden_notice("admin/vault_state")
    assert_message_not_baked_in("admin/vault_state")
    # An unpaused vault renders PAUSE — the destructive one, and the one that
    # makes an operator type an on-chain-logged reason before it would have
    # discovered the device cannot sign.
    assert_select "#vault-pause-btn[data-desktop-only-action]", 1,
      "admin/vault_state: the PAUSE button is not marked, so a phone can still open the " \
      "reason form and the confirm dialog before failing"
  end

  test "the paused vault's unpause button is marked too" do
    vault = initialized_vault
    vault.vault_state = vault.read_vault_state.merge(paused: true)

    Solana::Vault.stub :new, vault do
      get admin_vault_state_path
    end
    assert_response :success

    assert_hidden_notice("admin/vault_state (paused)")
    assert_select "#vault-unpause-btn[data-desktop-only-action]", 1,
      "admin/vault_state: the unpause branch renders a DIFFERENT button, and marking only " \
      "the pause one leaves recovery live on a phone"
  end

  test "the treasury page marks every co-sign button" do
    two = 2.times.map do |i|
      PendingTransaction.create!(tx_type: "settle_contest", serialized_tx: "AA#{i}", status: "pending")
    end

    get admin_pending_transactions_path
    assert_response :success

    assert_hidden_notice("admin/pending_transactions")
    assert_message_not_baked_in("admin/pending_transactions")
    # EVERY row, not the first: the buttons are rendered in a loop, and a marker
    # applied outside it would gate one and leave the rest live.
    assert_select "button[data-desktop-only-action][onclick*=?]", "cosignTransaction", two.length,
      "admin/pending_transactions: every pending row's Co-sign button must carry the marker"
  end

  test "the notice is absent where there is nothing to sign" do
    PendingTransaction.delete_all

    get admin_pending_transactions_path
    assert_response :success

    assert_select NOTICE, 0,
      "an empty treasury offers no wallet action, so a desktop-only warning there is noise"
  end
end
