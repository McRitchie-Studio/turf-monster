require "test_helper"

# ApplicationController#promote_to_onchain_session! — the SESSION half of proving
# wallet ownership, and the reason a wallet LINK and a wallet LOGIN can no longer
# disagree about what the session is.
#
# Unit-style on a bare controller instance with `session` pinned to a plain Hash
# (Solana::CurrentWallet documents that shape as supported), following
# display_entry_token_count_test.rb's pattern. No request, no HTTP — the two
# writes are the whole subject.
class PromoteToOnchainSessionTest < ActiveSupport::TestCase
  BRAND_KEY = Solana::CurrentWallet::SESSION_KEY

  def controller_with(session)
    ApplicationController.new.tap do |c|
      c.define_singleton_method(:session) { session }
    end
  end

  def promote(session, provider:)
    controller_with(session).send(:promote_to_onchain_session!, provider: provider)
  end

  test "grants the on-chain privilege AND remembers the brand that signed" do
    session = {}

    promote(session, provider: "phantom")

    assert_equal true, session[:onchain],
                 "the privilege flag is what SessionContext reads to render mode web3"
    assert_equal "phantom", session[BRAND_KEY],
                 "the brand is what resolves an adapter that can sign NOW"
  end

  test "normalises the brand spelling the browser happened to report" do
    session = {}

    promote(session, provider: " Phantom ")

    assert_equal "phantom", session[BRAND_KEY],
                 "Wallet Standard registrations arrive in whatever case the wallet chose"
  end

  test "an unrecognised brand still grants the privilege, and stores no brand" do
    session = {}

    promote(session, provider: "not-a-wallet")

    # The caller verified a signature before reaching here, so the privilege is
    # earned regardless of what the browser called the wallet. Storing an
    # unknown string instead would be worse than storing nothing: it can never
    # match a registry row, so it would name a signer that cannot be resolved.
    assert_equal true, session[:onchain],
                 "an unknown BRAND must not cost the session its verified privilege"
    assert_not session.key?(BRAND_KEY),
              "an unrecognised brand stores nothing rather than an unmatchable value"
  end

  test "a wallet SWITCH replaces the previous brand" do
    session = { BRAND_KEY => "solflare", onchain: true }

    promote(session, provider: "phantom")

    assert_equal "phantom", session[BRAND_KEY],
                 "re-auth through a different wallet must repoint the session, not keep the old signer"
  end
end
