require "test_helper"
require "open3"
require "json"

# requireProvider, exercised in Node against the REAL module.
#
# THE DEFECT IT EXISTS FOR, reported from production 2026-09-07: `detect()`
# returns null whenever no wallet is injected, and on iOS Safari and Android
# Chrome that is ALWAYS — a mobile browser cannot host an extension. Six call
# sites dereferenced that null immediately, so a phone got
# `null is not an object (evaluating 'provider.connect')` printed into a
# transaction modal, while a user was trying to spend a FREE entry token.
#
# WHAT IS ASSERTED HERE AND NOWHERE ELSE: that the copy is DEVICE-APPROPRIATE.
# A message is not correct merely because it is not a stack trace — telling a
# phone to install a browser extension is advice nobody holding that phone can
# take, and it is what the wallet-export flow used to say. The negative
# assertions below are the load-bearing ones.
class WalletRequireProviderJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  # `ua` drives isMobile(); `injected` decides whether a provider is present.
  def run_provider(ua:, injected: false, touch_points: 0)
    script = <<~JS
      global.window = global;
      // DEFINED, NOT ASSIGNED, and this is not a style choice. Node 21+ ships
      // `navigator` as a BUILT-IN read-only global, so `global.navigator = {...}`
      // silently does nothing there and wallet_provider.js reads Node's own user
      // agent instead of ours. Locally (Node 20, no built-in) the assignment
      // worked and every test passed; CI runs a newer Node and four of them went
      // red on isMobile. defineProperty overrides the built-in in both.
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: #{ua.to_json}, maxTouchPoints: #{touch_points} },
        writable: true, configurable: true
      });
      // FAIL LOUDLY IF THE SHIM DID NOT TAKE. Without this the next Node change
      // that breaks it reports as a wrong-copy failure somewhere downstream,
      // which is exactly how the first version of this wasted a CI round trip.
      if (navigator.userAgent !== #{ua.to_json}) {
        throw new Error("navigator shim did not apply — got " + navigator.userAgent);
      }
      #{injected ? "global.phantom = { solana: { isPhantom: true, connect() {} } };" : ""}
      #{File.read(SOURCE)}
      var out;
      try {
        var p = window.walletProvider.requireProvider();
        out = { threw: false, name: p && p.name };
      } catch (e) {
        out = { threw: true, message: e.message };
      }
      out.isMobile = window.walletProvider.isMobile();
      console.log(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, stderr
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1".freeze
  MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/128 Safari/537.36".freeze
  ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/128 Mobile Safari/537.36".freeze

  test "an injected wallet is returned rather than thrown over" do
    result = run_provider(ua: MAC, injected: true)

    assert_equal false, result["threw"], "a present wallet must not be refused"
    assert_equal "phantom", result["name"]
  end

  test "iPhone Safari is told to use its wallet app's browser, never to install anything" do
    result = run_provider(ua: IPHONE)

    assert result["isMobile"], "the iPhone UA must classify as mobile or the copy branch is untested"
    assert result["threw"], "a null provider must throw rather than reach a call site"

    message = result["message"]
    # THE POSITIVE CLAIM: it names the one remedy that works on this device.
    assert_match(/wallet app/i, message)
    assert_match(/Phantom, Solflare, and Backpack/, message,
                 "all three wallets ship an in-app browser — naming only Phantom sends the other two nowhere")

    # THE NEGATIVE CLAIMS, which are the point. Advice a phone cannot act on is
    # worse than silence, and "install the extension" is exactly what the
    # wallet-export flow used to say to every device.
    refute_match(/install/i, message, "a phone cannot install a browser extension")
    refute_match(/extension/i, message)
    refute_match(/refresh/i, message, "refreshing changes nothing — there is no extension to appear")
  end

  test "Android Chrome gets the same mobile remedy" do
    result = run_provider(ua: ANDROID)

    assert result["isMobile"]
    assert_match(/wallet app/i, result["message"])
    refute_match(/install/i, result["message"])
  end

  test "an iPad reporting a Mac UA is still treated as mobile" do
    # Modern iPadOS lies about its user agent. maxTouchPoints is the tell, and
    # without it an iPad gets extension advice it cannot act on either.
    result = run_provider(ua: MAC, touch_points: 5)

    assert result["isMobile"], "a touch Mac UA is an iPad"
    assert_match(/wallet app/i, result["message"])
  end

  test "a desktop browser is told the thing that actually helps it" do
    result = run_provider(ua: MAC)

    assert_equal false, result["isMobile"]
    assert result["threw"]
    # Here the extension advice is correct, and the mobile copy would be wrong —
    # a desktop user has no wallet app browser to open.
    assert_match(/extension/i, result["message"])
    refute_match(/wallet app's own browser/i, result["message"])
  end

  test "the thrown message is never the raw null dereference" do
    # The regression this whole change exists to prevent, asserted directly
    # rather than inferred from the copy.
    [IPHONE, ANDROID, MAC].each do |ua|
      message = run_provider(ua: ua)["message"]
      refute_match(/is not an object/i, message)
      refute_match(/null/i, message)
      refute_match(/undefined/i, message)
    end
  end
end
