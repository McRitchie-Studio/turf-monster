require "test_helper"
require "json"
require "open3"

# The navbar's last known figures are a display value (app/javascript/nav_figures.js). Nothing
# that signs, enters a contest or checks funds may read them. These hold that by the source, and
# hold the key that keeps one wallet's figure from another, in Node against the real file.
class NavFiguresDisplayOnlyTest < ActiveSupport::TestCase
  SOURCES = Dir[Rails.root.join("app/**/*.{js,erb,rb}")].freeze

  def files_naming(pattern)
    SOURCES.select { |path| File.read(path).match?(pattern) }.map { |path| path.delete_prefix("#{Rails.root}/") }.sort
  end

  test "only the module, its layout tag and the writers in solana_utils name the figures" do
    assert_equal %w[app/javascript/nav_figures.js app/javascript/solana_utils.js app/views/layouts/application.html.erb],
                 files_naming(/TurfNavFigures|tm:nav-figures/)
  end

  test "solana_utils only writes the figures, and the layout only asks whether one is known" do
    utils = Rails.root.join("app/javascript/solana_utils.js").read
    assert_equal %w[forget remember who], utils.scan(/TurfNavFigures\.(\w+)/).flatten.uniq.sort
    layout = Rails.root.join("app/views/layouts/application.html.erb").read
    assert_equal %w[known], layout.scan(/TurfNavFigures\.(\w+)/).flatten.uniq
  end

  test "no funding check reads the painted pill" do
    # eligibilityBlocker and the entry flow read $store.session; the pill is paint.
    offenders = files_naming(/data-balance-display/) - %w[
      app/controllers/application_controller.rb
      app/javascript/nav_figures.js app/javascript/solana_utils.js app/javascript/state_fanout.js
      app/views/components/_nav_balance.html.erb app/views/contests/_turf_totals_board.html.erb
    ]
    assert_empty offenders
    utils = Rails.root.join("app/javascript/solana_utils.js").read
    reads = utils.lines.grep(/data-balance-display/).grep_v(%r{^\s*//})
    assert reads.all? { |line| line.include?("querySelector") }, reads.join
    assert_no_match(/usdcCents\s*=.*textContent|tokensAvailable\s*=.*textContent/, utils)
  end

  HARNESS = <<~'JS'.freeze
    const fs = require("fs"), vm = require("vm");
    const source = fs.readFileSync(process.argv[1], "utf8");
    function element(text, cls) {
      const set = new Set(cls);
      return { textContent: text, dataset: {}, style: { setProperty() {} },
        classList: { toggle: (n, on) => (on ? set.add(n) : set.delete(n)), add: (n) => set.add(n), remove: (n) => set.delete(n), contains: (n) => set.has(n) },
        closest: () => null, querySelector: () => null, querySelectorAll: () => [] };
    }
    function load(store, data) {
      const pill = element("", ["hidden"]);
      const body = { dataset: data };
      const listeners = {};
      const sessionStorage = { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = v; }, removeItem: (k) => { delete store[k]; } };
      const document = { body, addEventListener: (n, f) => { listeners[n] = f; },
        querySelectorAll: (sel) => (sel === "[data-balance-display]" ? [pill] : []) };
      const window = { sessionStorage };
      vm.runInNewContext(source, { window, document, JSON, Object, parseInt });
      return { pill, api: window.TurfNavFigures, listeners };
    }
    const A = { userId: "1", walletAddress: "AAA", solanaCluster: "devnet" };
    const out = {};
    const seed = () => { const store = {}; load(store, A).api.remember({ amount: "$1024" }); return store; };
    out.same = load(seed(), A).pill.textContent;
    let store = seed();
    out.otherUser = load(store, { ...A, userId: "2" }).pill.textContent;
    out.otherUserDeleted = !("tm:nav-figures" in store);
    out.otherWallet = load(seed(), { ...A, walletAddress: "BBB" }).pill.textContent;
    out.otherCluster = load(seed(), { ...A, solanaCluster: "mainnet-beta" }).pill.textContent;
    out.guest = load(seed(), { userId: "", walletAddress: "" }).pill.textContent;
    store = seed(); store["tm:onchain-settle-until"] = "1:x";
    out.settling = load(store, A).pill.textContent;
    store = {}; const late = load(store, A); late.api.remember({ amount: "$9" }, "2|BBB|devnet");
    out.lateAnswer = store["tm:nav-figures"] === undefined;
    store = seed(); load(store, A).api.forget();
    out.forgot = load(store, A).pill.textContent;
    store = seed();
    const snapshot = element("$5", []);
    const body = { dataset: A, querySelectorAll: (sel) => (sel === "[data-balance-display]" ? [snapshot] : []) };
    load(store, A).listeners["turbo:before-render"]({ detail: { newBody: body } });
    out.snapshot = snapshot.textContent;
    store["tm:onchain-settle-until"] = "1:x";
    const held = element("$5", []);
    const heldBody = { dataset: A, querySelectorAll: (sel) => (sel === "[data-balance-display]" ? [held] : []) };
    load(store, A).listeners["turbo:before-render"]({ detail: { newBody: heldBody } });
    out.heldSnapshot = held.textContent;
    console.log(JSON.stringify(out));
  JS

  test "a figure shows only for the user, wallet and cluster it was read for" do
    stdout, stderr, status = Open3.capture3("node", "-e", HARNESS, Rails.root.join("app/javascript/nav_figures.js").to_s)
    assert status.success?, stderr
    out = JSON.parse(stdout)

    assert_equal "$1024", out["same"]
    assert_equal "", out["otherUser"]
    assert out["otherUserDeleted"], "a record for someone else must go"
    assert_equal "", out["otherWallet"]
    assert_equal "", out["otherCluster"]
    assert_equal "", out["guest"]
    assert_equal "", out["settling"], "a settling spend must not bring the pre-spend figure back"
    assert out["lateAnswer"], "a read made for another identity must not write"
    assert_equal "", out["forgot"]
    assert_equal "$1024", out["snapshot"], "the memory must overwrite a snapshot's figure"
    assert_equal "", out["heldSnapshot"], "a settling spend must blank a snapshot's figure"
  end
end
