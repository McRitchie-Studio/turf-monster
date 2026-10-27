// [unit] wallet_signal.js registers the wallet with the engine's session store
// whenever that store arrives: at once when it already exists (studio/session.js
// as a classic script, today), or at DOMContentLoaded when it loads as a module
// behind Turf's entry point (the engine's planned change).
//
// THE AFTER-PARSING CASE IS THE REAL ONE. wallet_signal is itself an importmap
// module, and a module script runs after the document has parsed, when
// readyState is already "interactive", never "loading". These tests used to
// fake "loading", which is the one state the module never sees, so the wait
// they proved was a wait the page never took (Carl, turf-folds-into-engine-stimulus).
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const PATH = fileURLToPath(new URL("../../app/javascript/wallet_signal.js", import.meta.url))
const SOURCE = readFileSync(PATH, "utf8")

// A fresh copy of the module each time, so install()'s window.tmWalletSignal
// guard and module state start clean. The query defeats the module cache.
let copies = 0
function load() {
  copies += 1
  const body = SOURCE + `\n// copy ${copies}\n`
  return import("data:text/javascript;base64," + Buffer.from(body).toString("base64"))
}

function fakeDocument(readyState) {
  const listeners = {}
  return {
    readyState,
    body: {},
    addEventListener(name, fn) { (listeners[name] ||= []).push(fn) },
    fire(name) { (listeners[name] || []).splice(0).forEach((fn) => fn()) },
    listeners
  }
}

function fakeSource() {
  return {
    name: "wallet",
    starts: 0,
    start() { this.starts += 1; return () => {} },
    subscribe() { return () => {} },
    current() { return { status: "unknown", address: null } }
  }
}

function fakeSession() {
  return {
    registered: [],
    registerIdentitySource(source) {
      this.registered.push(source)
      source.start(() => {})
      return { name: source.name, unregister() {} }
    }
  }
}

let created
function fakeWindow(extra = {}) {
  created = []
  return {
    location: { pathname: "/" },
    SolanaStudio: { walletIdentity: { create(options) { const s = fakeSource(); s.options = options; created.push(s); return s } } },
    ...extra
  }
}

beforeEach(() => {
  delete globalThis.window
  delete globalThis.document
})

test("whenStudioSession calls back at once with a store that already exists", async () => {
  const { whenStudioSession } = await load()
  const session = fakeSession()
  const seen = []
  whenStudioSession({ StudioSession: session }, fakeDocument("loading"), (s) => seen.push(s))
  assert.deepEqual(seen, [ session ])
})

test("whenStudioSession waits for DOMContentLoaded when the store is not there yet", async () => {
  const { whenStudioSession } = await load()
  for (const readyState of ["loading", "interactive"]) {
    const win = {}
    const doc = fakeDocument(readyState)
    const seen = []
    whenStudioSession(win, doc, (s) => seen.push(s))
    assert.deepEqual(seen, [], `${readyState}: it must not resolve before the page's modules have run`)

    win.StudioSession = fakeSession()
    doc.fire("DOMContentLoaded")
    assert.deepEqual(seen, [ win.StudioSession ], readyState)
  }
})

test("whenStudioSession, evaluated after parsing (an importmap module), registers with a store that arrives later", async () => {
  // The module runs at readyState "interactive", before DOMContentLoaded; a
  // module studio/session queued behind it evaluates after it and before the
  // event. The old code answered null here at once, and the wallet ran with no
  // session behind it.
  const { whenStudioSession } = await load()
  const win = {}
  const doc = fakeDocument("interactive")
  const seen = []
  whenStudioSession(win, doc, (s) => seen.push(s))
  assert.deepEqual(seen, [], "an after-parsing evaluation must still wait for the page's modules")

  win.StudioSession = fakeSession()
  doc.fire("DOMContentLoaded")
  assert.deepEqual(seen, [ win.StudioSession ])
})

test("whenStudioSession falls back to load when DOMContentLoaded has already fired", async () => {
  // Evaluated between DOMContentLoaded and load (an import() after the page's
  // modules): readyState still reads "interactive", but the event will not fire
  // again, so `load` settles it.
  const { whenStudioSession } = await load()
  const win = fakeDocument("interactive") // a window that takes listeners
  const doc = fakeDocument("interactive")
  const seen = []
  whenStudioSession(win, doc, (s) => seen.push(s))
  assert.deepEqual(seen, [])

  win.StudioSession = fakeSession()
  win.fire("load")
  assert.deepEqual(seen, [ win.StudioSession ])

  doc.fire("DOMContentLoaded")
  win.fire("load")
  assert.deepEqual(seen.length, 1, "it calls back once, whichever event comes first")
})

test("whenStudioSession answers null on a loaded page with no store, and on a parsed one at DOMContentLoaded", async () => {
  const { whenStudioSession } = await load()
  const seen = []
  whenStudioSession({}, fakeDocument("complete"), (s) => seen.push(s))
  assert.deepEqual(seen, [ null ], "complete: nothing more will load, answer now")

  const doc = fakeDocument("interactive")
  whenStudioSession({}, doc, (s) => seen.push(s))
  doc.fire("DOMContentLoaded")
  assert.deepEqual(seen, [ null, null ])
})

test("attachIdentitySource registers with a store, or starts the source alone", async () => {
  const { attachIdentitySource } = await load()
  const session = fakeSession()
  const withStore = fakeSource()
  assert.equal(attachIdentitySource(session, withStore).name, "wallet")
  assert.deepEqual(session.registered, [ withStore ])
  assert.equal(withStore.starts, 1, "the store starts it, once")

  const alone = fakeSource()
  assert.equal(attachIdentitySource(null, alone), null)
  assert.equal(alone.starts, 1)
})

test("install registers once with a store that exists before it runs (the classic session.js)", async () => {
  const session = fakeSession()
  globalThis.window = fakeWindow({ StudioSession: session })
  globalThis.document = fakeDocument("loading")
  await load() // evaluating it installs, as on a page

  assert.equal(created.length, 1)
  assert.deepEqual(session.registered, created)
  assert.equal(created[0].starts, 1)
  assert.equal(window.tmWalletSignal.registration.name, "wallet")
})

test("install registers once with a store that arrives after it (a module session.js)", async () => {
  globalThis.window = fakeWindow()
  // "interactive": install() runs inside an importmap module, after parsing.
  globalThis.document = fakeDocument("interactive")
  await load()

  assert.equal(created.length, 1, "the wallet source exists from the start")
  assert.equal(created[0].starts, 0, "nothing has started it without the store")
  assert.equal(window.tmWalletSignal.registration, null)

  const session = fakeSession()
  window.StudioSession = session
  document.fire("DOMContentLoaded")

  assert.deepEqual(session.registered, created, "registered with the late store, not silently left out")
  assert.equal(created[0].starts, 1, "started once, by the store")
  assert.equal(window.tmWalletSignal.registration.name, "wallet")
})
