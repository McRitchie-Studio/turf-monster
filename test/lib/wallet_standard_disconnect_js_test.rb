# frozen_string_literal: true

require "test_helper"

# [unit] The Wallet Standard adapter must forward a DISCONNECT.
#
# THE DEFECT THIS PINS. _makeWsAdapter's `on` opened with
# `if (event !== 'accountChanged') return;` and dropped every other event on the
# floor. The disconnect subscription in solana_stores.js was therefore a SILENT
# NO-OP on this adapter — and that adapter is the steady state for a modern
# Phantom, because the app swaps to it on 'wallet-provider:registered'. The
# subscription worked only on the legacy provider, whose own `on` forwards
# anything.
#
# Wallet Standard has NO native disconnect event: an empty `accounts` array on a
# 'standard:events' change IS the disconnect, so the adapter has to translate it.
#
# Runs the SHIPPED file under node rather than a copy of its logic — a
# reimplementation here would pass while the real adapter stayed broken.
class WalletStandardDisconnectJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  # Builds a fake Wallet Standard wallet, subscribes through the real adapter,
  # fires one `change`, and reports what the callbacks saw.
  def run_case(subscribe:, accounts:)
    harness = <<~JS
      const src = require('fs').readFileSync(#{SOURCE.to_s.inspect}, 'utf8');
      global.window = { addEventListener() {}, dispatchEvent() {} };
      let changeCb = null;
      const wallet = {
        accounts: [{ address: 'AAA', publicKey: new Uint8Array(32) }],
        features: {
          'standard:events': { on: (name, cb) => { if (name === 'change') changeCb = cb; } },
          'solana:signAndSendTransaction': {}
        }
      };
      // Expose the module-private factory without executing the browser bootstrap.
      const fn = new Function('window', src + '; return _makeWsAdapter;');
      const adapter = fn(global.window)(wallet);

      let fired = 0, lastArg = 'UNSET';
      adapter.on(#{subscribe.to_json}, function (arg) { fired += 1; lastArg = arg === null ? 'NULL' : (arg === undefined ? 'UNDEFINED' : 'OBJ'); });
      if (!changeCb) { console.log(JSON.stringify({ error: 'no change listener registered' })); process.exit(0); }
      changeCb({ accounts: #{accounts.to_json} });
      console.log(JSON.stringify({ fired, lastArg }));
    JS
    out = IO.popen(["node", "-e", harness], &:read)
    raise "node failed: #{out}" unless $?.success?

    JSON.parse(out.lines.last)
  end

  # THE FIX. A disconnect on Wallet Standard arrives as accounts: [].
  def test_a_disconnect_subscription_fires_on_an_empty_accounts_change
    result = run_case(subscribe: "disconnect", accounts: [])

    assert_nil result["error"], result["error"].to_s
    assert_equal 1, result["fired"],
                 "the disconnect subscription never fired — on Wallet Standard it is a silent no-op, " \
                 "which is the steady state for a modern Phantom"
  end

  # A SWITCH IS NOT A DISCONNECT. Firing disconnect for an account change would
  # tear down a session the user never left.
  def test_a_disconnect_subscription_stays_quiet_on_an_account_switch
    result = run_case(subscribe: "disconnect", accounts: [{ address: "BBB", publicKey: [] }])

    assert_equal 0, result["fired"],
                 "disconnect fired for an account SWITCH — that ends a session the user is still in"
  end

  # The pre-existing channel must keep working exactly as before: an empty
  # accounts array still reaches accountChanged as null, which is the path that
  # already degraded correctly on both provider shapes.
  def test_account_changed_still_reports_null_on_an_empty_accounts_change
    result = run_case(subscribe: "accountChanged", accounts: [])

    assert_equal 1, result["fired"]
    assert_equal "NULL", result["lastArg"],
                 "accountChanged must still deliver null on disconnect — solana_stores.js routes " \
                 "that to _handleSignerLost, and it is the path that worked before this fix"
  end

  # An event the adapter does not translate must still be dropped, or every
  # unrelated subscription starts firing on account changes.
  def test_an_untranslated_event_is_still_ignored
    result = run_case(subscribe: "someOtherEvent", accounts: [])

    # The adapter returns BEFORE touching 'standard:events', so it never even
    # registers a change listener — which is the strongest form of "ignored", and
    # is why this asserts on the harness's no-listener report rather than on a
    # fire count that cannot exist.
    assert_equal "no change listener registered", result["error"],
                 "an untranslated event subscribed to the wallet's change feed; every unrelated " \
                 "listener would then wake on account changes"
  end
end
