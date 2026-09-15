require "test_helper"
require "json"
require "open3"

# `cosign_signatures.js` — the browser half of the three-signature cosign, run
# in node against the real module.
#
# ── WHY THIS TIER EXISTS, AND THE HOLE THAT PROVED IT ─────────────────────
#
# The Ruby tiers cover `#rebuild` and `#broadcast`: what the server reserves,
# what it validates, what it records. None of them can see the BROWSER's signer
# queue. During development a one-line mutation to `cosign.js` —
#
#     .concat(rebuilt.extra_cosigners || [])   ->   .concat([])
#
# — dropped every extra cosigner from that queue, silently reverting the whole
# fix, and the entire Ruby suite stayed green through it. A server that
# correctly reserves a third slot and a browser that never fills it produce
# exactly the transaction this change exists to stop: one signature short, 6046
# from five paths and 6047 from `settle_contest`.
#
# So the two properties below are asserted where they live. They are the ones
# that were not free.
class CosignSignaturesJsTest < ActiveSupport::TestCase
  SOURCE = "app/javascript/cosign_signatures.js".freeze

  # Load the real module with the smallest window/global shim it needs. It is a
  # plain IIFE that attaches to `window`, so nothing is stubbed except the
  # browser objects it reads.
  def run_module(body)
    source = Rails.root.join(SOURCE)
    script = <<~JS
      import { readFileSync } from 'node:fs';

      const out = {};
      globalThis.window = globalThis;
      // Only the two constructors the module names. A fuller web3.js is not
      // needed for the byte-level question these tests ask.
      globalThis.solanaWeb3 = {
        PublicKey: class { constructor(k) { this.k = k; } toBase58() { return this.k; } },
        Transaction: { from() { throw new Error('not used in this test'); } }
      };

      eval(readFileSync(process.argv[1], 'utf8'));

      #{body}

      console.log(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def key(b58)
    "{ publicKey: { toBase58: () => #{b58.inspect} }"
  end

  # ── AN EMPTY SLOT IS ZERO-FILLED, NOT ABSENT ──────────────────────────────
  #
  # web3.js zero-fills a signature slot that has not been signed rather than
  # omitting it, so "present in the signatures array" and "signed" are
  # different facts. Reading the first as the second is how a transaction
  # reaches the chain one signature short — and the program's answer to that
  # (6046, or 6047 on settle) names no wallet, so the operator learns nothing.
  test "an all-zero signature slot reads as NOT signed" do
    r = run_module(<<~JS)
      const zeroed = { signatures: [#{key('WalletA')}, signature: new Uint8Array(64) }] };
      out.zeroSlot = window.cosignSignatures.extractSignature(zeroed, 'WalletA');
    JS

    assert_nil r["zeroSlot"],
               "a zero-filled slot must read as unsigned; treating it as a signature is how a " \
               "transaction reaches the chain short"
  end

  test "a real signature is returned for the wallet that made it" do
    r = run_module(<<~JS)
      const sig = new Uint8Array(64); sig[0] = 7; sig[63] = 9;
      const signed = { signatures: [#{key('WalletA')}, signature: sig }] };
      const got = window.cosignSignatures.extractSignature(signed, 'WalletA');
      out.length = got ? got.length : null;
      out.first = got ? got[0] : null;
      out.last = got ? got[63] : null;
    JS

    assert_equal 64, r["length"]
    assert_equal 7, r["first"]
    assert_equal 9, r["last"]
  end

  # THE WRONG WALLET'S SIGNATURE IS NOT THIS WALLET'S. The collector asks each
  # wallet for its own slot by pubkey; returning a neighbour's bytes would put a
  # signature in a slot it does not verify against, and `serialize()` would
  # reject the merged wire for a reason unrelated to what went wrong.
  test "a signature is never read out of another wallet's slot" do
    r = run_module(<<~JS)
      const sig = new Uint8Array(64); sig[0] = 42;
      const signed = { signatures: [
        #{key('WalletA')}, signature: sig },
        #{key('WalletB')}, signature: new Uint8Array(64) }
      ] };
      out.b = window.cosignSignatures.extractSignature(signed, 'WalletB');
      out.missing = window.cosignSignatures.extractSignature(signed, 'WalletC');
    JS

    assert_nil r["b"], "WalletB's slot is empty — WalletA's signature must not be read into it"
    assert_nil r["missing"], "a wallet that is not a signer of this message has no signature"
  end

  # ── THE EXPECTED-SWITCH SUPPRESSION ──────────────────────────────────────
  #
  # Collecting three signatures REQUIRES the operator to change Phantom
  # accounts, and the wallet watcher reads any switch away from the session's
  # address as an identity change: it opens the `wallet-changed` card with
  # `dismissible: false`. Correct for an unexpected switch; fatal for an
  # expected one, because that card would cover the cosign flow, refuse to
  # close, and strand a half-collected treasury transaction.
  #
  # These are SOURCE guards, not behavioural ones, and that is worth stating
  # rather than dressing up: the watcher lives inside an Alpine registration and
  # cannot be instantiated standalone without refactoring it for the test. What
  # they pin is the exact regression shape — the check disappearing, or the
  # suppression outliving its flow. The behaviour itself is exercised in
  # e2e/cosign_two_wallet_signatures.spec.js, where the stub really does switch
  # accounts mid-collection.
  test "the watcher consults the expected-switch list before raising the hand-off card" do
    js = Rails.root.join("app/javascript/solana_stores.js").read

    assert_match(/expectedSwitchAddresses/, js,
                 "the watcher must know which switches a flow declared")
    notify = js[/_notifySwitch: function.*?\n    \},/m]
    refute_nil notify, "_notifySwitch must still exist for this guard to mean anything"
    assert_match(/expectedSwitchAddresses\.indexOf\(pubkeyB58\)/, notify,
                 "an EXPECTED switch must be recognised before modals.open — otherwise the " \
                 "non-dismissible wallet-changed card covers the cosign flow mid-ceremony")
    assert_match(/dismissible: false/, notify,
                 "the card is still non-dismissible for every UNDECLARED wallet — this is a " \
                 "scoped suppression, never a disable")
  end

  # A SUPPRESSION THAT OUTLIVES ITS FLOW DISARMS THE GUARD FOR THE WHOLE PAGE,
  # silently and for every wallet — the same class of mistake as a mutation left
  # in source. Both flows that declare one must clear it on every exit path,
  # including an early return and a thrown rejection.
  test "every flow that suppresses the switch card clears it in a finally" do
    {
      "app/javascript/cosign.js" => "the treasury cosign flow",
      "app/views/admin/vault_state/show.html.erb" => "the unpause flow"
    }.each do |path, what|
      src = Rails.root.join(path).read
      next unless src.include?("expectSwitchesTo")

      assert_match(/finally\s*\{[^}]*clearExpectedSwitches/m, src,
                   "#{what} declares expected switches and must clear them in a finally — " \
                   "a catch alone leaves the guard disarmed on the early-return path")
    end
  end

  # ── THE MUTATION THAT SURVIVED THE RUBY SUITE ─────────────────────────────
  #
  # `cosign.js` is too DOM- and fetch-coupled to execute here, and its
  # behaviour is covered end to end by e2e/cosign_two_wallet_signatures.spec.js.
  # This is the cheap backstop for the ONE line that silently undoes the fix: if
  # the signer queue stops reading the server's `extra_cosigners`, the browser
  # collects one signature for a three-signature action and every server-side
  # test still passes.
  test "the browser builds its signer queue from the server's reserved slots" do
    js = Rails.root.join("app/javascript/cosign.js").read

    assert_match(/\.concat\(\s*rebuilt\.extra_cosigners\s*\|\|\s*\[\]\s*\)/, js,
                 "the signer queue must append the extra cosigners the REBUILD reserved — " \
                 "dropping them collects one signature for a three-signature action, and no " \
                 "server-side test can see it")

    assert_match(/cosigner_address:\s*signerQueue\[0\]/, js,
                 "the named cosigner reported to #broadcast must be the slot the server " \
                 "reserved, not provider.publicKey — which by then holds whichever account " \
                 "the operator switched to LAST")

    assert_match(/extra_cosigners:\s*signerQueue\.slice\(1\)/, js,
                 "#broadcast must be told every extra wallet that signed, or the audit row " \
                 "names one signer for a three-signature payout")
  end
end
