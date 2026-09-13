require "test_helper"
require "open3"
require "json"

# THE STUB AND THE MODULE MUST ANSWER ALIKE, proven by RUNNING BOTH.
#
# THE TRAP THIS CLOSES. layouts/application inlines a minimal walletProvider stub
# because Alpine evaluates x-data BEFORE importmap modules execute, so a click
# landing in that window reaches the STUB, not the module. Two objects, one
# contract — and nothing made them agree. A stub missing requireProvider throws
# "requireProvider is not a function", which is the same unreadable class of
# failure that method exists to remove; a stub with DIFFERENT copy tells a phone
# to install an extension while the module tells it the truth, depending only on
# how fast the page loaded.
#
# ASSERTED BEHAVIOURALLY, NOT BY GREP. A test that string-matched the layout
# source would pass over a stub whose method existed and returned the wrong
# sentence, and it would pass over a syntax error too. This one takes the stub
# out of the RENDERED page — the bytes a browser actually receives — evaluates
# it in Node beside the real module, and compares what they SAY.
class WalletStubParityTest < ActionDispatch::IntegrationTest
  MODULE_SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1".freeze
  MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/128 Safari/537.36".freeze

  # Lift the stub's object literal out of the rendered HTML by brace matching.
  # Deliberately NOT a regex over the whole block: the same inline script carries
  # solanaConnectAndVerify and friends, and a greedy match would drag them in.
  def rendered_stub
    get root_path
    # `/` redirects to the main contest (SeasonConfig.main_contest).
    follow_redirect! while response.redirect?
    assert_response :success

    marker = "window.walletProvider = {"
    start = response.body.index(marker)
    refute_nil start, "the layout no longer inlines a walletProvider stub — has it moved?"

    open_brace = start + marker.length - 1
    depth = 0
    finish = nil
    (open_brace...response.body.length).each do |i|
      case response.body[i]
      when "{" then depth += 1
      when "}" then (depth -= 1) == 0 && (finish = i)
      end
      break if finish
    end
    refute_nil finish, "could not brace-match the stub object literal"

    response.body[open_brace..finish]
  end

  def ask(source_js, ua)
    script = <<~JS
      global.window = global;
      // See wallet_require_provider_js_test.rb: Node 21+ makes `navigator` a
      // read-only built-in, so assignment silently no-ops and the UA branch goes
      // untested. Define it, then prove it took.
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: #{ua.to_json}, maxTouchPoints: 0 },
        writable: true, configurable: true
      });
      if (navigator.userAgent !== #{ua.to_json}) {
        throw new Error("navigator shim did not apply — got " + navigator.userAgent);
      }
      #{source_js}
      var wp = window.walletProvider;
      var out;
      try {
        wp.requireProvider();
        out = { threw: false };
      } catch (e) {
        out = { threw: true, message: e.message };
      }
      // The DESKTOP-ONLY gate, asked of the same object in the same run. It is
      // reported separately because it answers a different question — about the
      // DEVICE, not the wallet — and must be compared against its own
      // counterpart, never against requireProvider's.
      try {
        wp.requireDesktop();
        out.desktopThrew = false;
      } catch (e) {
        out.desktopThrew = true;
        out.desktopMessage = e.message;
      }
      out.isMobile = wp.isMobile();
      console.log(JSON.stringify(out));
    JS
    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, stderr
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  def stub_js
    @stub_js ||= "window.walletProvider = #{rendered_stub};"
  end

  def module_js
    @module_js ||= File.read(MODULE_SOURCE)
  end

  test "the inlined stub carries requireProvider at all" do
    # Without this the pre-hydration window throws "not a function" — the exact
    # unreadable failure the method exists to remove.
    result = ask(stub_js, IPHONE)

    assert result["threw"], "the stub's detect() always returns null, so it must throw"
    refute_match(/not a function/i, result["message"],
                 "the stub is missing requireProvider — it must mirror the module")
  end

  test "stub and module give a phone the same answer" do
    from_stub = ask(stub_js, IPHONE)
    from_module = ask(module_js, IPHONE)

    assert from_stub["isMobile"] && from_module["isMobile"]
    assert_equal from_module["message"], from_stub["message"],
                 "a user's advice must not depend on how fast the page loaded"
  end

  test "stub and module give a desktop the same answer" do
    from_stub = ask(stub_js, MAC)
    from_module = ask(module_js, MAC)

    assert_equal false, from_stub["isMobile"]
    assert_equal from_module["message"], from_stub["message"]
  end

  # THE STUB NEEDS THE DESKTOP-ONLY PAIR MORE THAN IT NEEDS requireProvider.
  # shared/_wallet_desktop_only_notice.html.erb paints its sentence from an
  # inline script in the page BODY, so the object answering is always the stub,
  # never the module — the importmap has not run yet. A stub without these two
  # throws "desktopOnlyMessage is not a function" while painting the very
  # element whose job is to stop a phone from hitting an error.
  test "the inlined stub carries the desktop-only gate at all" do
    result = ask(stub_js, IPHONE)

    assert result["desktopThrew"], "a phone must be refused by the stub too"
    refute_match(/not a function/i, result["desktopMessage"].to_s,
                 "the stub is missing requireDesktop or desktopOnlyMessage")
  end

  test "stub and module give a phone the same desktop-only answer" do
    from_stub = ask(stub_js, IPHONE)
    from_module = ask(module_js, IPHONE)

    assert from_stub["desktopThrew"] && from_module["desktopThrew"]
    assert_equal from_module["desktopMessage"], from_stub["desktopMessage"],
                 "the painted reason and the thrown reason must not depend on load order"
  end

  # The desktop side of the parity, and it is an agreement to say NOTHING.
  # requireDesktop asks about the device only, so a desktop passes both objects
  # silently — the wallet question is answered at each call site's own isPhantom
  # check. A stub that started refusing here would block a desktop signing flow
  # for the duration of the pre-hydration window.
  test "stub and module both let a desktop through" do
    from_stub = ask(stub_js, MAC)
    from_module = ask(module_js, MAC)

    assert_equal false, from_stub["isMobile"]
    assert_equal false, from_stub["desktopThrew"], "the stub refused a desktop"
    assert_equal false, from_module["desktopThrew"], "the module refused a desktop"
  end

  test "neither surfaces a raw null dereference on any device" do
    [IPHONE, MAC].each do |ua|
      [stub_js, module_js].each do |source|
        message = ask(source, ua)["message"]
        refute_match(/is not an object/i, message)
        refute_match(/\bnull\b/i, message)
      end
    end
  end
end
