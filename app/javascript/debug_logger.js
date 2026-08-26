// Browser-console logger for web2 (fetch) and web3 (Phantom + Solana RPC) traffic.
// Each request emits a single collapsed group: description, duration, request payload, response.
//
// Toggle live in DevTools:  window.DEBUG_NET = true    (or false)
//
// DEFAULTS OFF OUTSIDE DEVELOPMENT — and it used to default ON everywhere, which
// shipped a live traffic logger to production. What it printed was not incidental:
// the /auth/solana/verify request body carries the SIWS message AND the full base58
// signature, both well inside the 1500-char truncation, and it re-fires on every
// _reauth; the response side prints session_state's fresh CSRF token. Anyone with
// the user's console open — a support screen-share, a recorded session, a bystander —
// read live credentials.
//
// The env comes from data-app-environment on <body>, which the layout already
// renders (AppFlags.qa_environment? ? "qa" : Rails.env). Reading THAT rather than a
// new flag matters: QA runs on Heroku with Rails.env=production, so anything keyed
// on Rails.env alone would call QA production and silently disable the tooling
// exactly where operators use it.
//
// An explicit window.DEBUG_NET set before this module loads still wins, in either
// direction — that is the DevTools escape hatch, and turning it ON in production is
// a deliberate act by someone who can already read the console.
function _defaultOn() {
  try {
    var env = document.body && document.body.dataset && document.body.dataset.appEnvironment;
    return env === 'development' || env === 'qa';
  } catch (_) {
    return false; // unreadable env is not a licence to log credentials
  }
}

if (window.DEBUG_NET === undefined) window.DEBUG_NET = _defaultOn();

function _on() { return !!window.DEBUG_NET; }

function _fmtMs(ms) {
  if (ms < 1) return ms.toFixed(2) + 'ms';
  if (ms < 1000) return Math.round(ms) + 'ms';
  return (ms / 1000).toFixed(2) + 's';
}

// SECRETS ARE REDACTED ON THE FETCH LEG, even when the logger is deliberately ON.
//
// SCOPED HONESTLY, because the previous wording ("secrets never reach the
// console") overclaimed and a future reader would have trusted it. _safeBody is
// applied to fetch request and response bodies and NOWHERE ELSE:
//   · _summarizePhantomArgs returns the SIWS message VERBATIM
//   · _rpcRequest prints sendRawTransaction's serialized SIGNED transaction
// Both are dev/qa-or-opt-in only, so neither is a production leak — but they are
// not redacted, and the comment now says so. Extending redaction to the web3
// legs is the honest follow-up; claiming it is already done is not.
//
// Defaulting off protects the user who never opens DevTools; redaction protects the
// one who does, and the operator debugging QA with it enabled. The two are separate
// guarantees and neither substitutes for the other — a support screen-share with
// DEBUG_NET on would otherwise still broadcast a live signature.
//
// Redacted by KEY, on the parsed JSON, rather than by regex over the raw string. A
// regex would have to guess at base58 alphabets and token shapes; the key names are
// the thing this app actually controls. A body that is not JSON is truncated as
// before but never parsed, so a form post cannot smuggle a key past the check.
// RE-DERIVED FROM THIS APP'S ACTUAL WIRE PAYLOADS, 2026-08-26, not guessed.
// The previous list named `authenticity_token` / `csrf_token` / `csrfToken` —
// three spellings of a key THIS APP NEVER EMITS. It renders a bare `csrf`
// (accounts_controller.rb:90, `client_session_payload.merge(csrf:
// form_authenticity_token)`), so a live CSRF token printed on every
// visibilitychange rehydrate, and the suite stayed green because it asserted
// redaction of `csrf_token` — a key that is never on the wire. A redactor tested
// against a fictional key proves nothing.
//
// Re-derive rather than extend, with the payloads themselves:
//   grep -rhoE "render json: \{[^}]*\}" app/controllers/ | grep -oE "[a-z_]+:" | sort -u
//   grep -rhoE "JSON\.stringify\(\{[^}]{0,220}" app/views/ app/javascript/ | grep -oE "[a-zA-Z_]+:" | sort -u
var _SECRET_KEYS = [
  // --- credentials: a copy of this value can be USED by whoever reads it ---
  'signature',        // the base58 SIWS signature — a live credential
  'message',          // the SIWS message: carries the nonce the signature is over
  'signed_tx',        // a SIGNED transaction: submittable by anyone holding it
  'csrf',             // accounts_controller.rb:90 — THE live token, bare key
  'authenticity_token', 'csrf_token', 'csrfToken', // other apps' spellings; harmless to keep
  'nonce',            // solana_sessions_controller.rb:8 — see the note below
  'token', 'params_token', // magic-link tokens ARE logins. Note the entry-token
                      // COUNT is `tokens` (plural) and stays visible.
  'secret', 'password', 'private_key', 'encrypted_web2_solana_private_key'
];

// `nonce` IS on the list, deliberately. It is single-use and deleted before
// verify (OPSEC-018), so a captured one is spent — but it is the exact value
// `message` is redacted FOR, and printing the pair together in a support
// screen-share hands over both halves of the challenge. Cheap to redact, and
// nothing debugs better for having it.
//
// DELIBERATELY NOT REDACTED, because over-redaction blinds the tool it is
// protecting: `tx_signature` and `sent_signature` are PUBLIC on-chain
// identifiers — they are the whole point of a block explorer — and `pubkey` is
// public too, already rendered on <body data-wallet-address>. A logger that
// hides the transaction id cannot debug a transaction.

function _redact(value) {
  if (Array.isArray(value)) return value.map(_redact);
  if (!value || typeof value !== 'object') return value;

  var out = {};
  Object.keys(value).forEach(function(k) {
    out[k] = _SECRET_KEYS.indexOf(k) !== -1 ? '[redacted]' : _redact(value[k]);
  });
  return out;
}

// Returns a log-safe rendering of a request/response body.
function _safeBody(body) {
  if (typeof body !== 'string') return body;
  try {
    return JSON.stringify(_redact(JSON.parse(body)));
  } catch (_) {
    return body; // not JSON — nothing to key off, so leave it to _trunc
  }
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
        console.log('request:', _trunc(_safeBody(reqBody), 1500) || '(none)');
        console.log('response:', _trunc(_safeBody(body), 1500));
        console.log('status:', resp.status, resp.statusText);
        console.groupEnd();
      }).catch(function() {});
      return resp;
    }, function(err) {
      var dur = performance.now() - t0;
      _group(label + ' ✕ ' + (err && err.message), '#06d6a0', '#ef4444', dur);
      console.log('request:', _trunc(_safeBody(reqBody), 1500) || '(none)');
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

// INSIDE the guard. This line sat outside every one of them, so a production
// console printed "[debug-net] enabled" while the logger was disabled — the
// banner asserting the opposite of the fact it exists to report.
if (_on()) {
  console.log('%c[debug-net] enabled — toggle with `window.DEBUG_NET = false`', 'color:#888');
}
