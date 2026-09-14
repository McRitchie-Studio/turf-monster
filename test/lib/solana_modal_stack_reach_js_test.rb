require "test_helper"
require "open3"
require "json"

# [unit] The two solanaModal methods that reach the transaction card WHEREVER IT
# SITS on the modal stack: retire() drops it, strand() marks it failed.
#
# RENAMED FROM solana_modal_retire_js_test.rb (/tasks/stranded-handoff-buries-card)
# because the second caller arrived: the same buried card is reachable down two
# legs, and a file named for one of them hides the other.
#
# THE DEFECT THIS TIER EXISTS FOR. Every other method on this store reaches the
# CURRENT card (_onCurrent), and the transaction card can be BURIED: the
# level-up celebration opens ON TOP of a non-dismissible card rather than
# swapping it away (the free-entry-earned branch in the layout says so in
# words), so a wallet handoff the user abandons can leave a non-dismissible
# processing card one below the screen. A caller that reads .visible / .state
# sees the celebration, concludes there is nothing to retire, and leaves the
# trap standing for the moment the celebration closes — with body.modal-open,
# and therefore the scroll lock and pull-to-refresh, still on it. Raised in
# review of PR 697.
#
# WHAT IT DRIVES, AND THE HONEST LIMIT. The store is lifted VERBATIM out of
# layouts/application.html.erb and executed. The host store it talks to
# (Alpine.store('modals')) is a stand-in written here, small but shaped like
# studio-engine's: a stack, current() reading the top, close() marking _closing
# and splicing, and _sync() setting body.modal-open from the stack's length.
# So this proves the DECISION — which entry is found, when it is refused, what
# the class does afterwards — against a model of the host, not the host itself.
# The composed browser regression in e2e/wallet_handoff_bfcache_return.spec.js
# drives the real engine store, in a real restore, and asserts what the user
# can see.
class SolanaModalStackReachJsTest < ActiveSupport::TestCase
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

  # Bounded by the two lines that open and close the store's own block, so a
  # drift in either direction fails here by name rather than lifting half the
  # layout into the sandbox.
  def store_source
    src = File.read(LAYOUT)
    start = src.index("          var _txCluster =")
    assert start, "could not find the solanaModal store's preamble in the layout"
    store_at = src.index("Alpine.store('solanaModal', {", start)
    assert store_at, "could not find the solanaModal store registration"
    finish = src.index("\n          });\n", store_at)
    assert finish, "could not bound the solanaModal store — its closing line moved"
    src[start...(finish + "\n          });".length)]
  end

  # `body` runs after the store is registered, with: modal (the store), modals
  # (the host stand-in), bodyClasses (what _sync has set), and open(id, props).
  def run_js(body)
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };

      var bodyClasses = {};
      global.document = {
        body: {
          dataset: { solanaCluster: 'devnet' },
          classList: {
            add: function (c) { bodyClasses[c] = true; },
            remove: function (c) { delete bodyClasses[c]; },
            contains: function (c) { return !!bodyClasses[c]; }
          }
        }
      };

      // studio-engine's modal host, in miniature. Same shape the real one has
      // (app/views/studio/modals/_host.html.erb): a stack, current() = the top,
      // close() flips _closing then splices, _sync() drives body.modal-open.
      // The real close() defers its splice by the exit animation; this one
      // splices at once, which the assertions below are written for.
      var modals = {
        stack: [],
        open: function (id, props) { this.stack.push({ id: id, props: props || {} }); this._sync(); },
        current: function () { return this.stack.length ? this.stack[this.stack.length - 1] : null; },
        close: function () {
          var entry = this.current();
          if (!entry || entry._closing) return;
          entry._closing = true;
          this.stack.splice(this.stack.indexOf(entry), 1);
          this._sync();
        },
        swap: function (id, props) { this.stack.pop(); this.open(id, props); },
        _sync: function () {
          if (this.stack.length) document.body.classList.add('modal-open');
          else document.body.classList.remove('modal-open');
        }
      };

      var stores = { modals: modals };
      global.Alpine = {
        store: function (name, def) {
          if (def !== undefined) { stores[name] = def; return def; }
          return stores[name];
        }
      };

      #{store_source}

      var modal = Alpine.store('solanaModal');
      function ids() { return modals.stack.map(function (e) { return e.id; }); }

      var out;
      try {
        out = (function () { #{body} })();
      } catch (e) {
        out = { error: e.message };
      }
      process.stdout.write(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    result = JSON.parse(stdout)
    assert_nil result["error"], "the store threw: #{result['error']}"
    result
  end

  # --- the buried card, which is the whole point ---------------------------

  test "a processing card BURIED under the celebration is retired, and the class follows the stack" do
    result = run_js(<<~JS)
      modal.show('Sign Transaction', 'Approve your free entry in your wallet...');
      // Exactly what the layout's level-up beat does when it finds a card that
      // forbids dismissal: open ON TOP rather than swap it away.
      modals.open('free-entry-earned', { level: 2 });
      var before = { ids: ids(), visible: modal.visible, state: modal.state, locked: document.body.classList.contains('modal-open') };

      var retired = modal.retire();
      var afterRetire = { ids: ids(), locked: document.body.classList.contains('modal-open') };

      // The user closes the celebration they were shown.
      modals.close();
      return { before: before, retired: retired, afterRetire: afterRetire,
               ids: ids(), locked: document.body.classList.contains('modal-open') };
    JS

    # THE STATE THE OLD CODE READ, recorded so the fix's reason is visible: with
    # the celebration on top, .visible and .state describe THAT card, so a
    # caller branching on them retires nothing.
    assert_equal %w[onchain-tx free-entry-earned], result["before"]["ids"]
    assert_equal false, result["before"]["visible"],
                 "sanity: .visible is current-only, and the current card is the celebration"
    assert_nil result["before"]["state"]
    assert_equal true, result["before"]["locked"]

    assert_equal true, result["retired"]
    assert_equal ["free-entry-earned"], result["afterRetire"]["ids"],
                 "the buried transaction card must go, and the celebration must stay"
    assert_equal true, result["afterRetire"]["locked"],
                 "a card is still up, so the scroll lock is still correct"

    assert_equal [], result["ids"]
    assert_equal false, result["locked"],
                 "closing the celebration must leave a scrollable page — no frozen card underneath"
  end

  test "a processing card on top is retired the ordinary way" do
    result = run_js(<<~JS)
      modal.show('Opening Your Wallet', 'Handing this over to your wallet app…');
      var retired = modal.retire();
      return { retired: retired, ids: ids(), locked: document.body.classList.contains('modal-open') };
    JS

    assert_equal true, result["retired"]
    assert_equal [], result["ids"]
    assert_equal false, result["locked"]
  end

  # --- what it refuses ------------------------------------------------------

  test "a card that has already resolved is not retired, buried or not" do
    # THE GUARD IS STATE, NOT POSITION. A success or error card belongs to its
    # own buttons: the user is reading a signature, a CTA, or a reason.
    result = run_js(<<~JS)
      modal.show('Submitting Entry', 'Processing your entry...');
      modal.success('SIG1', 'Entry Confirmed');
      var onTop = modal.retire();
      modals.open('free-entry-earned', { level: 2 });
      var buried = modal.retire();
      return { onTop: onTop, buried: buried, ids: ids() };
    JS

    assert_equal false, result["onTop"]
    assert_equal false, result["buried"]
    assert_equal %w[onchain-tx free-entry-earned], result["ids"],
                 "neither call may touch a settled card"
  end

  test "an error card survives a retire, so its remedy stays readable" do
    result = run_js(<<~JS)
      modal.show('Opening Your Wallet', 'Handing this over to your wallet app…');
      modal.error('Your wallet app did not open.', 'Wallet Did Not Open');
      return { retired: modal.retire(), ids: ids(), state: modal.state };
    JS

    assert_equal false, result["retired"]
    assert_equal ["onchain-tx"], result["ids"]
    assert_equal "error", result["state"]
  end

  test "retiring nothing is answered, not thrown" do
    # The way back fires on a page that may hold no card at all — a second
    # return, or a flow whose card some other beat already closed.
    result = run_js("return { retired: modal.retire(), ids: ids() };")

    assert_equal false, result["retired"]
    assert_equal [], result["ids"]
  end

  test "a card mid-close is already gone as far as retire is concerned" do
    # _liveTx excludes an entry inside its exit window, and it must: patching or
    # re-splicing a card the host is already removing writes onto an entry about
    # to disappear.
    result = run_js(<<~JS)
      modal.show('Sign Transaction', 'Approve your free entry in your wallet...');
      modals.stack[0]._closing = true;
      return { retired: modal.retire(), ids: ids() };
    JS

    assert_equal false, result["retired"]
    assert_equal ["onchain-tx"], result["ids"]
  end

  # --- strand(): the OTHER leg that has to reach the buried card ------------
  #
  # /tasks/stranded-handoff-buries-card. When the hop NEVER happens — no wallet
  # app installed, or the user dismisses the OS prompt — the runner has to say
  # "Wallet Did Not Open" on the card that was waiting. error() cannot reach a
  # buried one (it writes through _onCurrent like every other setter), so the
  # stranded leg painted NOTHING and left the same non-dismissible card standing
  # under the celebration that the return leg had just been taught to clear.
  #
  # WHY A NEW METHOD RATHER THAN RE-POINTING error() AT _liveTx. error() has 14
  # call sites in this app (cosign, lock_contest, the faucet, the generator,
  # both boards, contests/new) and every one of them means "the card the user is
  # looking at". Re-pointing it would make each of them able to write onto a
  # transaction card buried under something else. strand() is the same reach
  # with one caller.

  test "a processing card BURIED under the celebration is stranded where it lies" do
    result = run_js(<<~JS)
      modal.show('Sign Transaction', 'Approve your free entry in your wallet...');
      modals.open('free-entry-earned', { level: 2 });

      var stranded = modal.strand('Your wallet app did not open.', 'Wallet Did Not Open');
      var buried = modals.stack[0].props;
      var afterStrand = { ids: ids(), state: buried.state, title: buried.title,
                          message: buried.errorMessage, dismissible: buried.dismissible,
                          locked: document.body.classList.contains('modal-open') };

      // The user closes the celebration and meets the card underneath.
      modals.close();
      return { stranded: stranded, afterStrand: afterStrand, ids: ids(),
               state: modal.state, dismissible: modals.stack.length ? modals.stack[0].props.dismissible : null,
               locked: document.body.classList.contains('modal-open') };
    JS

    assert_equal true, result["stranded"]
    # STILL THERE, and now carrying its reason: the card is not dropped, it is
    # answered. Dropping it would leave the user with no idea why the entry
    # never happened.
    assert_equal %w[onchain-tx free-entry-earned], result["afterStrand"]["ids"]
    assert_equal "error", result["afterStrand"]["state"]
    assert_equal "Wallet Did Not Open", result["afterStrand"]["title"]
    assert_equal "Your wallet app did not open.", result["afterStrand"]["message"]
    assert_equal true, result["afterStrand"]["dismissible"],
                 "the card the user meets when the celebration closes must be one they can leave"
    assert_equal true, result["afterStrand"]["locked"], "a card is still up, so the lock is right"

    assert_equal ["onchain-tx"], result["ids"], "closing the celebration reveals the answered card"
    assert_equal "error", result["state"]
    assert_equal true, result["dismissible"], "and it is closable — no frozen card, no scroll lock left"
  end

  test "a processing card on top is stranded exactly the way error() left it" do
    # THE VISIBLE CASE MUST NOT GO QUIET. This is the case "Wallet Did Not Open"
    # was written for, and the buried fix must not buy the buried case by
    # dropping the sentence the visible user reads.
    result = run_js(<<~JS)
      modal.show('Opening Your Wallet', 'Handing this over to your wallet app…');
      var stranded = modal.strand('Your wallet app did not open.', 'Wallet Did Not Open');
      return { stranded: stranded, ids: ids(), state: modal.state, title: modal.title,
               message: modal.errorMessage, dismissible: modals.stack[0].props.dismissible };
    JS

    assert_equal true, result["stranded"]
    assert_equal ["onchain-tx"], result["ids"]
    assert_equal "error", result["state"]
    assert_equal "Wallet Did Not Open", result["title"]
    assert_equal "Your wallet app did not open.", result["message"]
    assert_equal true, result["dismissible"]
  end

  test "a settled card is not overwritten by a late stranded timer" do
    # STATE IS THE GUARD HERE TOO. The grace window fires 2.5s after the handoff
    # and nothing stops another beat from resolving the card first; a success
    # the user is reading must not turn into "Wallet Did Not Open".
    result = run_js(<<~JS)
      modal.show('Submitting Entry', 'Processing your entry...');
      modal.success('SIG1', 'Entry Confirmed');
      var onTop = modal.strand('Your wallet app did not open.', 'Wallet Did Not Open');
      modals.open('free-entry-earned', { level: 2 });
      var buried = modal.strand('Your wallet app did not open.', 'Wallet Did Not Open');
      return { onTop: onTop, buried: buried, state: modals.stack[0].props.state,
               title: modals.stack[0].props.title };
    JS

    assert_equal false, result["onTop"]
    assert_equal false, result["buried"]
    assert_equal "success", result["state"]
    # success() carries its copy in message / successTitle and leaves the card's
    # own title alone, so "unchanged" here is the title the flow last set —
    # measured, not assumed.
    assert_equal "Submitting Entry", result["title"], "the settled card keeps its own words"
  end

  test "stranding nothing is answered, not thrown" do
    result = run_js("return { stranded: modal.strand('nope', 'Nope'), ids: ids() };")

    assert_equal false, result["stranded"]
    assert_equal [], result["ids"]
  end

  test "a card mid-close is already gone as far as strand is concerned" do
    result = run_js(<<~JS)
      modal.show('Sign Transaction', 'Approve your free entry in your wallet...');
      modals.stack[0]._closing = true;
      return { stranded: modal.strand('nope', 'Nope'), state: modals.stack[0].props.state };
    JS

    assert_equal false, result["stranded"]
    assert_equal "processing", result["state"]
  end
end
