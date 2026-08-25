// Browser-console logger for web2 (fetch) and web3 (Phantom + Solana RPC) traffic.
// Each request emits a single collapsed group: description, duration, request payload, response.
//
// Toggle live in DevTools:  window.DEBUG_NET = false   (or true)
// Defaults to enabled.

if (window.DEBUG_NET === undefined) window.DEBUG_NET = true;

function _on() { return !!window.DEBUG_NET; }

function _fmtMs(ms) {
  if (ms < 1) return ms.toFixed(2) + 'ms';
  if (ms < 1000) return Math.round(ms) + 'ms';
  return (ms / 1000).toFixed(2) + 's';
}

function _trunc(s, max) {
  if (s == null) return s;
  max = max || 800;
  if (typeof s !== 'string') {
    try { s = JSON.stringify(s); } catch (_) { return '[unserializable ' + typeof s + ']'; }
  }
  if (s.length > max) s = s.slice(0, max) + '… (+' + (s.length - max) + ' chars)';
  return s;
}

function _group(label, color, okColor, dur) {
  console.groupCollapsed(
    '%c' + label + ' %c(' + _fmtMs(dur) + ')',
    'color:' + color, 'color:' + (okColor || '#888')
  );
}

// ── Web2: window.fetch ──────────────────────────────────────────────
(function patchFetch() {
  if (!window.fetch || window.__debugFetchPatched) return;
  window.__debugFetchPatched = true;
  var orig = window.fetch.bind(window);

  window.fetch = function(input, init) {
    if (!_on()) return orig(input, init);
    var t0 = performance.now();
    var url = typeof input === 'string' ? input : (input && input.url) || String(input);
    var method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
    var reqBody = init && init.body;
    var label = '[web2] ' + method + ' ' + url;

    return orig(input, init).then(function(resp) {
      var dur = performance.now() - t0;
      resp.clone().text().then(function(body) {
        _group(label + ' → ' + resp.status, '#06d6a0', resp.ok ? '#888' : '#ef4444', dur);
        console.log('request:', _trunc(reqBody, 1500) || '(none)');
        console.log('response:', _trunc(body, 1500));
        console.log('status:', resp.status, resp.statusText);
        console.groupEnd();
      }).catch(function() {});
      return resp;
    }, function(err) {
      var dur = performance.now() - t0;
      _group(label + ' ✕ ' + (err && err.message), '#06d6a0', '#ef4444', dur);
      console.log('request:', _trunc(reqBody, 1500) || '(none)');
      console.log('error:', err);
      console.groupEnd();
      throw err;
    });
  };
})();

// ── Web3: Phantom provider methods ───────────────────────────────────
function _summarizeTx(tx) {
  if (!tx) return null;
  try {
    var instructions = tx.instructions || (tx.message && tx.message.instructions) || [];
    return {
      feePayer: tx.feePayer && tx.feePayer.toBase58 ? tx.feePayer.toBase58() : null,
      recentBlockhash: tx.recentBlockhash || (tx.message && tx.message.recentBlockhash) || null,
      instructionCount: instructions.length,
      signatureCount: (tx.signatures || []).length
    };
  } catch (_) { return '[tx: unserializable]'; }
}

function _summarizePhantomArgs(method, args) {
  if (method === 'signMessage') {
    var msg = args[0];
    try {
      var text = (msg instanceof Uint8Array) ? new TextDecoder().decode(msg) : String(msg);
      return { message: text, encoding: args[1] };
    } catch (_) { return { messageBytes: msg && msg.byteLength }; }
  }
  if (method === 'signTransaction') return _summarizeTx(args[0]);
  return args;
}

function _summarizePhantomResult(method, res) {
  if (!res) return res;
  if (method === 'signMessage' && res.signature) return { signatureBytes: res.signature.length };
  if (method === 'signTransaction') return _summarizeTx(res);
  if (method === 'connect' && res.publicKey) {
    return { publicKey: res.publicKey.toBase58 ? res.publicKey.toBase58() : String(res.publicKey) };
  }
  return res;
}

(function patchPhantom() {
  function attach() {
    if (!window.walletProvider || !window.walletProvider.get) return false;
    var p = window.walletProvider.get('phantom');
    // TWO DIFFERENT ANSWERS, and collapsing them killed the retry. attach()'s
    // return value means "stop trying", and the driver above does
    // `if (attach()) return;` BEFORE it ever starts the interval — so a single
    // truthy answer here means the loop never runs at all.
    //
    // Phantom injects ASYNCHRONOUSLY. `get('phantom')` returning null is the
    // ordinary state during the injection window, which is the exact window this
    // retry exists to wait out. Reporting it as "done" meant the instrumentation
    // silently never attached — and this is the tooling you reach for to debug
    // that flow, so it went missing precisely when it was wanted.
    //
    // The sibling patcher below (solanaWeb3) already separates them correctly:
    // absence returns false and keeps trying; already-patched returns true.
    if (!p) return false;
    if (p.__debugPatched) return true;
    p.__debugPatched = true;

    ['connect', 'signMessage', 'signTransaction'].forEach(function(m) {
      var orig = p[m];
      if (typeof orig !== 'function') return;
      p[m] = function() {
        if (!_on()) return orig.apply(this, arguments);
        var args = Array.from(arguments);
        var t0 = performance.now();
        var label = '[web3] Phantom.' + m;
        var argSummary = _summarizePhantomArgs(m, args);
        return Promise.resolve(orig.apply(this, args)).then(function(res) {
          var dur = performance.now() - t0;
          _group(label + ' ✓', '#8e82fe', '#06d6a0', dur);
          console.log('args:', argSummary);
          console.log('result:', _summarizePhantomResult(m, res));
          console.groupEnd();
          return res;
        }, function(err) {
          var dur = performance.now() - t0;
          _group(label + ' ✕ ' + (err && err.message), '#8e82fe', '#ef4444', dur);
          console.log('args:', argSummary);
          console.log('error:', err);
          console.groupEnd();
          throw err;
        });
      };
    });
    return true;
  }

  if (attach()) return;
  var tries = 0;
  var iv = setInterval(function() { if (attach() || ++tries > 40) clearInterval(iv); }, 100);
})();

// ── Web3: solanaWeb3.Connection RPC ──────────────────────────────────
// _rpcRequest is the choke point every Connection JSON-RPC method funnels through
// in @solana/web3.js v1 (sendRawTransaction, getBalance, getAccountInfo, etc.).
(function patchConnection() {
  function attach() {
    if (!window.solanaWeb3 || !window.solanaWeb3.Connection) return false;
    var proto = window.solanaWeb3.Connection.prototype;
    if (proto.__debugPatched) return true;
    proto.__debugPatched = true;

    var orig = proto._rpcRequest;
    if (typeof orig !== 'function') return true;
    proto._rpcRequest = function(methodName, params) {
      if (!_on()) return orig.apply(this, arguments);
      var t0 = performance.now();
      var label = '[web3] rpc.' + methodName;
      return Promise.resolve(orig.apply(this, arguments)).then(function(res) {
        var dur = performance.now() - t0;
        var ok = !(res && res.error);
        _group(label + (ok ? ' ✓' : ' ✕'), '#00bfff', ok ? '#06d6a0' : '#ef4444', dur);
        console.log('params:', _trunc(params, 800));
        console.log('result:', _trunc(res && (res.result !== undefined ? res.result : res), 1200));
        if (res && res.error) console.log('error:', res.error);
        console.groupEnd();
        return res;
      }, function(err) {
        var dur = performance.now() - t0;
        _group(label + ' ✕ ' + (err && err.message), '#00bfff', '#ef4444', dur);
        console.log('params:', _trunc(params, 800));
        console.log('error:', err);
        console.groupEnd();
        throw err;
      });
    };
    return true;
  }

  if (attach()) return;
  var tries = 0;
  var iv = setInterval(function() { if (attach() || ++tries > 60) clearInterval(iv); }, 100);
})();

console.log('%c[debug-net] enabled — toggle with `window.DEBUG_NET = false`', 'color:#888');
