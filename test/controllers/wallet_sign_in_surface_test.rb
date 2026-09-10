require "test_helper"

# The consolidated sign-in helper is inline JS in layouts/application.html.erb —
# so the RENDERED page is its component, and "does it reach the browser at all"
# is a real regression this tier can hold. There is exactly ONE implementation
# (window.solanaConnectAndVerify) behind four wallet surfaces, so a layout that
# stops shipping it, or a branch deleted in a refactor, breaks every one of them
# at once and silently.
#
# SCOPE, stated plainly: this asserts what is SHIPPED, not how it BEHAVES. The
# behavioural coverage for signIn is e2e/wallet_sign_in.spec.js, which executes
# both branches in a browser.
class WalletSignInSurfaceTest < ActionDispatch::IntegrationTest
  test "the sign-in page ships the shared wallet helper" do
    get "/signin"
    assert_response :success
    assert_match "solanaConnectAndVerify", response.body,
                 "all four wallet surfaces call this one helper"
  end

  test "the rendered helper carries BOTH the signIn branch and the fallback" do
    get "/signin"

    assert_match "supportsSignIn", response.body,
                 "the consolidated one-approval branch must reach the browser"
    assert_match "provider.signIn(", response.body,
                 "signIn must actually be called, not merely feature-detected"
    assert_match "provider.signMessage(", response.body,
                 "the two-step fallback must survive for wallets without signIn"
    assert_match "provider.connect()", response.body,
                 "the fallback still connects before signing"
  end

  test "the nonce fetch is kicked off before either wallet branch" do
    get "/signin"
    body = response.body

    nonce_fetch = body.index("/auth/solana/nonce")
    sign_in_call = body.index("provider.signIn(")
    connect_call = body.index("var resp = await provider.connect();")

    assert nonce_fetch, "the helper must still fetch a nonce"
    assert sign_in_call && connect_call, "both branches must be present"
    # The latency fix: the nonce request is started BEFORE the wallet round trip
    # rather than awaited after connect(), so it resolves during the human-gated
    # prompt on both paths.
    assert nonce_fetch < sign_in_call,
           "the nonce fetch must be kicked off before the signIn branch"
    assert nonce_fetch < connect_call,
           "the nonce fetch must be kicked off before the fallback connect"
  end
end
