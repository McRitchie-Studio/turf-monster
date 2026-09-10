require "test_helper"
require "open3"
require "json"

# requireDesktop, exercised in Node against the REAL module.
#
# WHAT THIS TIER OWNS. The four admin wallet flows — vault init, vault
# pause/unpause, contest lock/conclude, treasury cosign — are DESKTOP-ONLY, and
# this file answers whether the shared gate says so in a sentence somebody
# holding a phone can act on.
#
# THE TWO PROPERTIES, AND THEY PULL IN OPPOSITE DIRECTIONS.
#
#   1. A PHONE IS REFUSED EVEN WITH A WALLET. requireProvider asks "can this
#      browser reach a wallet right now", and a phone inside Phantom's own
#      in-app browser CAN — it gets an injected provider and requireProvider
#      hands it over. Correct for contest entry, wrong here: an admin does not
#      co-sign a 2-of-3 treasury operation from a phone. Delete that test and
#      requireDesktop could be an alias for requireProvider and stay green.
#
#   2. A DESKTOP IS NEVER REFUSED FOR WANT OF A WALLET. This gate asks about the
#      DEVICE and nothing else, and the reason is concrete. These callers do not
#      sign through this registry's provider — they hold `window.solana`, while
#      detect() reads `window.phantom.solana`. A legacy Phantom injecting only
#      the former is a desktop that CAN sign and that a wallet-composing gate
#      would refuse, telling the operator to install an extension they have.
#      e2e/cosign_fresh_transaction.spec.js stubs precisely that browser and
#      went red on the composed version. Each call site keeps its own isPhantom
#      check as the wallet answer; this adds only the fact none of them had.
#
# THE COPY RULES ARE THE THIRD PROPERTY. "Phantom wallet is required" — what all
# four flows said before — is true on a phone and useless there. The negative
# assertions below are the load-bearing ones.
class WalletDesktopOnlyJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1".freeze
  MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/128 Safari/537.36".freeze
  ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/128 Mobile Safari/537.36".freeze

  # `ua` drives isMobile(); `injected` decides whether a provider is present.
  # requireProvider is asked in the SAME run so the two gates can be compared
  # rather than described.
  def run_gate(ua:, injected: false, touch_points: 0)
    script = <<~JS
      global.window = global;
      // DEFINED, NOT ASSIGNED. Node 21+ ships `navigator` as a read-only
      // built-in, so `global.navigator = {...}` silently no-ops there and the
      // module reads NODE's user agent instead of ours — green on an older
      // local Node, red in CI, and the failure points at the copy rather than
      // at the shim. See wallet_require_provider_js_test.rb, which paid for it.
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: #{ua.to_json}, maxTouchPoints: #{touch_points} },
        writable: true, configurable: true
      });
      // FAIL LOUDLY IF THE SHIM DID NOT TAKE, rather than reporting a
      // downstream wrong-copy failure for an environment fact.
      if (navigator.userAgent !== #{ua.to_json}) {
        throw new Error("navigator shim did not apply — got " + navigator.userAgent);
      }
      #{injected ? "global.phantom = { solana: { isPhantom: true, connect() {} } };" : ""}
      #{File.read(SOURCE)}
      var wp = window.walletProvider;
      var out = {};
      try {
        out.returned = wp.requireDesktop();
        out.threw = false;
      } catch (e) {
        out.threw = true;
        out.message = e.message;
      }
      // The OTHER gate, on the same browser, so a test can assert they differ.
      try {
        wp.requireProvider();
        out.providerThrew = false;
      } catch (e) {
        out.providerThrew = true;
        out.providerMessage = e.message;
      }
      out.isMobile = wp.isMobile();
      out.desktopOnlyMessage = wp.desktopOnlyMessage();
      console.log(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, stderr
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  test "a phone WITH an injected wallet is still refused" do
    # PROPERTY 1. This is a phone inside a wallet app's own browser: detect()
    # returns a provider, so requireProvider hands it over — asserted here, not
    # assumed — and the admin would be walked into signing a 2-of-3 treasury
    # operation from a phone. requireDesktop refuses the DEVICE first.
    result = run_gate(ua: IPHONE, injected: true)

    assert result["isMobile"], "the iPhone UA must classify as mobile or nothing below is tested"
    assert_equal false, result["providerThrew"],
                 "the wallet IS reachable here — that is what makes this case the interesting one"
    assert result["threw"], "an injected wallet must not buy a phone past a desktop-only gate"
    assert_match(/desktop/i, result["message"])
  end

  test "a desktop with NO wallet is NOT refused by this gate" do
    # PROPERTY 2, and the one a well-meaning refactor breaks. Composing
    # requireProvider here reads as tidier and is wrong: these callers sign
    # through window.solana, which detect() does not look at, so the gate would
    # refuse desktops that can sign. requireProvider's own refusal is asserted
    # alongside to prove the two gates really are answering different questions.
    result = run_gate(ua: MAC)

    assert_equal false, result["isMobile"]
    assert result["providerThrew"], "requireProvider must still refuse — no wallet is injected here"
    assert_equal false, result["threw"],
                 "requireDesktop answers about the DEVICE only. Each call site keeps its own " \
                 "isPhantom check, and a legacy Phantom injecting window.solana but not " \
                 "window.phantom.solana is a desktop that CAN sign"
    assert_nil result["returned"], "there is no provider to hand back — a possibly-null return " \
                                   "is the shape of the original defect"
  end

  test "iPhone Safari is sent to a desktop, not told to install anything" do
    result = run_gate(ua: IPHONE)

    assert result["isMobile"]
    assert result["threw"]
    message = result["message"]

    # THE POSITIVE CLAIM: it names the move that works from a phone.
    assert_match(/desktop/i, message)

    # THE NEGATIVE CLAIMS, which are the point.
    refute_match(/install/i, message, "a phone cannot install a browser extension")
    refute_match(/wallet app/i, message,
                 "the in-app-browser remedy is right for contest entry and wrong here — an " \
                 "admin must not co-sign a treasury operation from a phone")
    refute_match(/refresh/i, message, "refreshing a phone changes nothing about this")
  end

  test "Android Chrome gets the same desktop-only answer" do
    result = run_gate(ua: ANDROID)

    assert result["isMobile"]
    assert result["threw"]
    assert_match(/desktop/i, result["message"])
    refute_match(/wallet app/i, result["message"])
  end

  test "an iPad reporting a Mac UA is still refused" do
    # Modern iPadOS lies about its user agent; maxTouchPoints is the tell. A
    # naive /iPhone|Android/ check waves this device straight into a signing
    # flow it cannot finish.
    result = run_gate(ua: MAC, touch_points: 5)

    assert result["isMobile"], "a touch Mac UA is an iPad"
    assert result["threw"]
    assert_match(/desktop/i, result["message"])
  end

  test "a desktop with a wallet passes through untouched" do
    result = run_gate(ua: MAC, injected: true)

    assert_equal false, result["isMobile"]
    assert_equal false, result["threw"], "the supported case must not be disturbed"
    assert_equal false, result["providerThrew"]
  end

  test "the desktop-only sentence does not change with the device" do
    # It states a property of the OPERATION, not of the browser reading it, so a
    # device branch creeping in here would be a second mechanism.
    messages = [IPHONE, ANDROID, MAC].map { |ua| run_gate(ua: ua)["desktopOnlyMessage"] }

    assert_equal 1, messages.uniq.length, "desktopOnlyMessage must not branch on the device"
    assert_match(/desktop/i, messages.first)
  end

  test "the refusal is never a raw null dereference" do
    # The production regression this whole family of gates descends from: a
    # phone was shown "null is not an object (evaluating 'provider.connect')"
    # inside a transaction modal. Asserted directly, not inferred from the copy.
    [IPHONE, ANDROID].each do |ua|
      message = run_gate(ua: ua)["message"]
      refute_match(/is not an object/i, message)
      refute_match(/\bnull\b/i, message)
      refute_match(/undefined/i, message)
      refute_match(/not a function/i, message)
    end
  end
end
