import { Controller } from "@hotwired/stimulus"

// The signer console on /admin/authorities: intent, keys, review, one CTA,
// signatures, read-back. The SERVER derives the plan (POST plan); this
// controller renders it and carries no program-shape literal. See
// app/views/admin/authorities/_console.html.erb and Solana::SignerPlan.
//
// Rules this file keeps:
//   - Nothing is pressable until the console state has loaded; the CTA ships
//     disabled and is enabled only by a plan the server accepted.
//   - A pasted key is validated as it is typed (base58, 32 bytes) and a
//     malformed one makes NO request.
//   - A refusal renders inline and the draft (intent, picks, paste) stays.
//   - Phantom is asked only for the queue the server sent with the bytes,
//     and that queue must equal the plan the operator reviewed.
//   - A declined or failed collection cancels the row at once.
//   - The page is a full load (strict CSP); a bfcache restore re-reads the
//     chain on pageshow rather than trusting a restored DOM.
const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

export function base58Bytes(value) {
  let n = 0n
  for (const ch of value) {
    const digit = ALPHABET.indexOf(ch)
    if (digit === -1) return -1
    n = n * 58n + BigInt(digit)
  }
  let bytes = 0
  while (n > 0n) { n /= 256n; bytes++ }
  let leading = 0
  while (leading < value.length && value[leading] === "1") leading++
  return bytes + leading
}

export function short(key) {
  const k = String(key || "")
  return k.length > 12 ? `${k.slice(0, 4)}…${k.slice(-4)}` : k
}

export default class extends Controller {
  static targets = [
    "shape", "continuity", "blocked", "connect", "current", "heldError",
    "intentGroup", "intent", "intentReasons", "keys", "removeBox", "removeList", "addBox", "addList",
    "paste", "confirmBox", "confirm", "pasteError", "refusal",
    "review", "before", "after", "sentence", "signers", "cta",
    "status", "readback", "readbackTitle", "readbackRows", "explorer", "nonce", "noncePrepare",
    "keyRowTemplate", "emptyRowTemplate", "pickTemplate", "signerRowTemplate"
  ]

  static values = {
    consoleUrl: String, planUrl: String, rotationsUrl: String,
    intent: String, remove: String, add: String
  }

  connect() {
    this.chosenIntent = null
    this.removePicks = new Set(this.split(this.removeValue))
    this.addPicks = new Set(this.split(this.addValue))
    this.planSeq = 0
    this.onPageShow = (event) => { if (event.persisted) this.load() }
    window.addEventListener("pageshow", this.onPageShow)
    this.load().then(() => {
      if (this.intentValue) this.selectIntent(this.intentValue)
    })
  }

  disconnect() {
    window.removeEventListener("pageshow", this.onPageShow)
  }

  // ── loading ──────────────────────────────────────────────────────────────

  get connected() {
    const key = window.solana && window.solana.publicKey
    return key && key.toBase58 ? key.toBase58() : null
  }

  async load() {
    this.ctaTarget.disabled = true
    const url = new URL(this.consoleUrlValue, window.location.origin)
    if (this.connected) url.searchParams.set("connected", this.connected)
    let body = {}
    let ok = false
    try {
      const resp = await fetch(url, { headers: { Accept: "application/json" } })
      body = await resp.json().catch(() => ({}))
      ok = resp.ok && body.ok
    } catch (e) {
      body = { message: "The console could not reach the server." }
    }
    if (!ok) {
      this.state = null
      this.shapeTarget.textContent = body.code === "shape_mismatch"
        ? "This app and the chain disagree about the program, so nothing can be planned until that is fixed."
        : "The signer set could not be read, so nothing can be planned against it."
      this.show(this.blockedTarget, body.message || "Refusing to plan blind.")
      this.intentGroupTarget.disabled = true
      return
    }
    this.hide(this.blockedTarget)
    this.state = body
    this.renderHeader()
    this.renderCurrent()
    this.renderIntents()
    this.renderPicks()
    if (body.live_rotation) {
      this.show(this.blockedTarget,
        `Rotation ${body.live_rotation.slug} is ${body.live_rotation.status}. Resolve it before starting another.`)
      this.intentGroupTarget.disabled = true
    }
    if (this.chosenIntent) this.requestPlan()
  }

  async connectPhantom() {
    const provider = window.solana
    if (!provider || !provider.isPhantom) {
      this.say("Phantom is not available in this browser.")
      return
    }
    try {
      await provider.connect()
    } catch (e) {
      this.say("Phantom did not connect.")
      return
    }
    window.dispatchEvent(new CustomEvent("signer-console:connected", { detail: { address: this.connected } }))
    await this.load()
  }

  // ── rendering ────────────────────────────────────────────────────────────

  renderHeader() {
    const r = this.state.rules
    this.shapeTarget.textContent =
      `Vault signer set: ${r.shape}, ${r.max_slots} slots, ${r.required} signatures to rotate.`
    this.continuityTarget.textContent = r.continuity
    if (this.state.server_held_error) {
      this.show(this.heldErrorTarget, this.state.server_held_error)
    } else {
      this.hide(this.heldErrorTarget)
    }
    this.connectTarget.textContent = this.connected ? `Phantom: ${short(this.connected)}` : "Connect Phantom"
    this.renderNonce()
  }

  // THE SIGNING CLOCK. Ready: a server-led rotation waits on the console's
  // durable nonce and has no time limit. Missing: one click has the server
  // create it (Solana::ConsoleNonce#prepare!). Until then signing works as
  // before, on a fresh blockhash.
  renderNonce() {
    const nonce = this.state.console_nonce || {}
    let text
    if (nonce.state === "ready") {
      text = `No time limit: a server-led rotation waits on durable nonce ${short(nonce.pubkey)} until you finish signing.`
    } else if (nonce.state === "missing") {
      text = "Signing has about 45 seconds from the first prompt. Prepare the console nonce once to remove the limit."
    } else if (nonce.state === "occupied") {
      text = "The console nonce address already holds another account, so it cannot be created there. " +
        "Steffon can make a nonce with this server key as authority and name it in SOLANA_DURABLE_NONCE_PUBKEY."
    } else if (nonce.state === "unreadable") {
      text = "The console nonce could not be read; signing falls back to about 45 seconds from the first prompt."
    } else {
      text = "This server holds no key, so there is no console nonce."
    }
    // An ENDED rotation whose signed bytes could still land. Voidable ones are
    // being killed by the server; an unvoidable one needs the old server key.
    const outstanding = this.state.outstanding_wires || []
    if (outstanding.length) {
      const stuck = outstanding.filter((w) => !w.voidable).map((w) => w.slug)
      text = `${outstanding.length} ended rotation(s) could still land (${outstanding.map((w) => w.slug).join(", ")}). ` +
        (stuck.length
          ? `${stuck.join(", ")} sit on a nonce this server no longer controls: advance it with the old server key, ` +
            "or unseat one of its signers, before anything else. "
          : "The server is advancing their nonce now; reload in a minute. ") + text
    }
    this.nonceTarget.textContent = text
    this.noncePrepareTarget.hidden = nonce.state !== "missing"
    this.noncePrepareTarget.disabled = nonce.state !== "missing"
  }

  async prepareNonce() {
    const nonce = (this.state && this.state.console_nonce) || {}
    if (nonce.state !== "missing" || !nonce.prepare_url) return
    this.noncePrepareTarget.disabled = true
    this.say("Creating the console nonce (the server signs and pays about 0.0015 SOL)…")
    const { ok, body } = await this.post(nonce.prepare_url, {})
    if (!ok) {
      this.fail(body.message || "The console nonce could not be created.")
      this.noncePrepareTarget.disabled = false
      return
    }
    this.say("")
    await this.load()
  }

  renderCurrent() {
    const r = this.state.rules
    const rows = this.padded(this.state.current, r.max_slots)
    this.currentTarget.replaceChildren(...rows.map((key, i) => this.keyRow(key, i)))
  }

  renderIntents() {
    const reasons = this.state.rules.intents
    this.intentGroupTarget.disabled = false
    const notes = []
    this.intentTargets.forEach((button) => {
      const reason = reasons[button.dataset.intent]
      button.disabled = !!reason
      button.title = reason || ""
      button.setAttribute("aria-pressed", String(button.dataset.intent === this.chosenIntent))
      if (reason) notes.push(`${button.textContent.trim()}: ${reason}`)
    })
    this.intentReasonsTarget.replaceChildren(...notes.map((text) => {
      const li = document.createElement("li")
      li.textContent = text
      return li
    }))
  }

  renderPicks() {
    const labels = this.state.labels
    this.removeListTarget.replaceChildren(...this.state.current.map((key) =>
      this.pick(key, labels[key], "remove", this.removePicks.has(key))))
    const candidates = this.state.candidates
    this.addListTarget.replaceChildren(...candidates.map((key) =>
      this.pick(key, labels[key], "add", this.addPicks.has(key))))
    // A pre-filled key the roster does not offer goes to the paste field.
    const offered = new Set(candidates)
    const stray = [...this.addPicks].find((key) => !offered.has(key))
    if (stray && !this.pasteTarget.value) {
      this.addPicks.delete(stray)
      this.pasteTarget.value = stray
    }
  }

  pick(key, label, side, checked) {
    const node = this.pickTemplateTarget.content.firstElementChild.cloneNode(true)
    const box = node.querySelector("[data-pick]")
    box.value = key
    box.dataset.side = side
    box.checked = checked
    node.querySelector("[data-name]").textContent = (label && label.name) || "Unknown key"
    node.querySelector("[data-address]").textContent = key
    return node
  }

  keyRow(key, index, opts = {}) {
    if (!key) {
      const empty = this.emptyRowTemplateTarget.content.firstElementChild.cloneNode(true)
      empty.querySelector("[data-slot]").textContent = String(index + 1)
      return empty
    }
    const labels = (opts.labels || this.state.labels)
    const label = labels[key] || { name: "Unknown key", unknown: true }
    const node = this.keyRowTemplateTarget.content.firstElementChild.cloneNode(true)
    node.dataset.keyRow = key
    node.querySelector("[data-slot]").textContent = String(index + 1)
    node.querySelector("[data-name]").textContent = label.name
    this.groupedAddress(node.querySelector("[data-address]"), key)
    const badge = (name, on) => node.querySelector(`[data-badge="${name}"]`).classList.toggle("hidden", !on)
    badge("server", !!label.server)
    badge("held", !!label.server_held)
    badge("connected", key === this.connected)
    badge("unknown", !!label.unknown)
    badge("removed", !!opts.removed)
    badge("added", !!opts.added)
    if (opts.match) {
      const match = node.querySelector("[data-match]")
      match.textContent = opts.match.text
      match.classList.remove("hidden")
      match.classList.add(opts.match.ok ? "text-success-ink" : "text-warning-ink")
    }
    if (opts.removed) node.classList.add("border-danger", "bg-danger/10")
    if (opts.added) node.classList.add("border-success", "bg-success/10")
    return node
  }

  // The full address in 4-character groups, the first and last group bold.
  groupedAddress(el, key) {
    const groups = key.match(/.{1,4}/g) || []
    el.replaceChildren(...groups.map((g, i) => {
      const span = document.createElement(i === 0 || i === groups.length - 1 ? "strong" : "span")
      span.textContent = g + (i < groups.length - 1 ? " " : "")
      if (span.tagName === "STRONG") span.className = "text-heading"
      return span
    }))
  }

  padded(keys, slots) {
    const out = keys.slice(0, slots)
    while (out.length < slots) out.push(null)
    return out
  }

  // ── the draft ────────────────────────────────────────────────────────────

  chooseIntent(event) {
    this.selectIntent(event.currentTarget.dataset.intent)
  }

  selectIntent(intent) {
    if (!this.state || this.signing) return
    if (this.state.rules.intents[intent]) return
    this.chosenIntent = intent
    this.renderIntents()
    this.show(this.keysTarget)
    this.removeBoxTarget.classList.toggle("hidden", intent === "add")
    this.addBoxTarget.classList.toggle("hidden", false)
    this.requestPlan()
  }

  picked(event) {
    const box = event.currentTarget
    if (this.signing) return
    const set = box.dataset.side === "remove" ? this.removePicks : this.addPicks
    if (box.checked) set.add(box.value)
    else set.delete(box.value)
    this.requestPlan()
  }

  pasted() {
    if (this.signing) return
    this.requestPlan()
  }

  // The pasted key, or an error string. Never sends a malformed key.
  pastedKey() {
    const value = this.pasteTarget.value.trim()
    if (!value) return { key: null }
    if (base58Bytes(value) !== 32) {
      const shown = value.length > 50 ? `A ${value.length}-character value` : `"${value}"`
      return { error: `${shown} is not a Solana address (32 bytes of base58). Check for a character pasted with it.` }
    }
    if (/^1+$/.test(value)) return { error: "The zero key is the empty slot, not a signer." }
    const known = this.state.labels[value] && !this.state.labels[value].unknown
    if (!known) {
      this.show(this.confirmBoxTarget)
      if (this.confirmTarget.value.trim() !== value) {
        return { error: "Unknown key: enter it a second time, exactly, to confirm.", soft: true }
      }
      return { key: value, unknown: true }
    }
    this.hide(this.confirmBoxTarget)
    return { key: value }
  }

  draft() {
    const pasted = this.pastedKey()
    const add = [...this.addPicks]
    if (pasted.key && !add.includes(pasted.key)) add.push(pasted.key)
    return {
      intent: this.chosenIntent,
      remove: this.chosenIntent === "add" ? [] : [...this.removePicks],
      add,
      confirm_unknown: pasted.unknown ? [pasted.key] : [],
      connected: this.connected,
      pasteError: pasted.error
    }
  }

  async requestPlan() {
    // Every draft change outdates any answer still in flight, including a
    // draft that makes no request (a malformed paste, an empty pick).
    if (this.signing) return
    const seq = ++this.planSeq
    this.ctaTarget.disabled = true
    this.hide(this.refusalTarget)
    if (!this.state || !this.chosenIntent) return
    const draft = this.draft()
    if (draft.pasteError) {
      this.show(this.pasteErrorTarget, draft.pasteError)
      this.hide(this.reviewTarget)
      return
    }
    this.hide(this.pasteErrorTarget)
    if (draft.remove.length === 0 && draft.add.length === 0) {
      this.hide(this.reviewTarget)
      return
    }

    const { ok, body } = await this.post(this.planUrlValue, this.payload(draft))
    if (seq !== this.planSeq) return // a newer draft answered first
    if (!ok) {
      this.plan = null
      this.hide(this.reviewTarget)
      this.show(this.refusalTarget, body.message || "The plan was refused.")
      this.refusalTarget.dataset.code = body.code || ""
      return
    }
    // THE REVIEWED DRAFT IS FROZEN WITH ITS PLAN. Sign sends exactly this,
    // never the live picks, so a pick changed after review cannot reach the
    // bytes Phantom signs.
    this.plan = body
    this.reviewedPayload = this.payload(draft)
    this.renderReview(body)
  }

  payload(draft) {
    return {
      intent: draft.intent, remove: draft.remove, add: draft.add,
      confirm_unknown: draft.confirm_unknown, connected: draft.connected
    }
  }

  renderReview(plan) {
    const labels = plan.labels
    const slots = plan.max_slots
    const evicted = new Set(plan.evicted)
    const added = new Set(plan.added)
    this.beforeTarget.replaceChildren(...this.padded(plan.current, slots).map((key, i) =>
      this.keyRow(key, i, { labels, removed: evicted.has(key) })))
    this.afterTarget.replaceChildren(...this.padded(plan.proposed, slots).map((key, i) =>
      this.keyRow(key, i, { labels, added: added.has(key), match: this.matchFor(key, labels) })))
    this.sentenceTarget.textContent = plan.sentence

    const held = new Set(plan.server_held)
    this.signersTarget.replaceChildren(...plan.authorizers.map((key, i) => {
      const node = this.signerRowTemplateTarget.content.firstElementChild.cloneNode(true)
      node.dataset.signerRow = key
      node.querySelector("[data-name]").textContent = (labels[key] && labels[key].name) || "Unknown key"
      node.querySelector("[data-short]").textContent = short(key)
      node.querySelector("[data-role]").textContent =
        i === 0 && plan.server_leads ? "Signs on the server and pays the fee"
          : held.has(key) ? "Signs on the server"
            : i === 0 ? "You sign in Phantom; this account pays the fee"
              : "You sign in Phantom"
      return node
    }))

    const n = plan.prompt_count
    this.ctaTarget.textContent = `Sign in Phantom (${n} ${n === 1 ? "prompt" : "prompts"})`
    this.ctaTarget.disabled = false
    this.show(this.reviewTarget)
  }

  matchFor(key, labels) {
    const label = labels[key]
    if (!label) return null
    if (label.holder === "alex") {
      return key === this.connected
        ? { ok: true, text: "Matches your connected Phantom account." }
        : { ok: false, text: "Not the connected account; open Phantom and compare." }
    }
    if (label.unknown) return { ok: false, text: "Unknown key, entered twice." }
    return null
  }

  changePlan() {
    if (this.signing) return
    this.hide(this.reviewTarget)
    this.ctaTarget.disabled = true
    this.intentGroupTarget.scrollIntoView({ block: "nearest" })
  }

  // ── signing ──────────────────────────────────────────────────────────────

  // The draft is LOCKED from the click until the rotation lands or fails:
  // intent, picks and paste are disabled, and any change event is ignored.
  async sign() {
    if (!this.plan || !this.reviewedPayload || this.signing) return
    this.signing = true
    this.lock(true)
    let outcome = "failed"
    try {
      outcome = await this.signReviewed(this.plan, this.reviewedPayload)
    } finally {
      this.signing = false
      if (outcome !== "landed") this.lock(false)
    }
    if (outcome === "replan") {
      // Re-plan from the draft on screen so the operator reviews what the
      // chain holds now, and keep the refusal that sent him back in view.
      const why = this.refusalTarget.textContent
      await this.requestPlan()
      if (this.refusalTarget.hidden) this.show(this.refusalTarget, why)
    }
  }

  lock(on) {
    this.intentGroupTarget.disabled = on
    this.keysTarget.querySelectorAll("input, button").forEach((el) => { el.disabled = on })
    this.element.querySelectorAll("[data-action*='changePlan']").forEach((el) => { el.disabled = on })
    this.element.dataset.signing = String(on)
  }

  // "landed", "failed" or "replan".
  async signReviewed(plan, reviewed) {
    this.ctaTarget.disabled = true
    this.hide(this.readbackTarget)

    try {
      if (window.walletProvider && window.walletProvider.requireDesktop) window.walletProvider.requireDesktop()
    } catch (gate) {
      this.fail(gate.message)
      return "failed"
    }
    const provider = window.solana
    if (!provider || !provider.isPhantom) {
      this.fail("Phantom is required to sign. Unlock the Phantom extension, then reload.")
      return "failed"
    }

    this.say("Building a fresh transaction…")
    try {
      await provider.connect()
    } catch (e) {
      this.fail("Phantom did not connect.")
      return "failed"
    }

    // The reviewed draft, and the set and signers it was reviewed as: the
    // server refuses (reviewed_set_mismatch) unless a fresh plan equals them.
    const { ok, body: built } = await this.post(this.rotationsUrlValue, {
      ...reviewed,
      connected: this.connected,
      reviewed_proposed: plan.proposed,
      reviewed_authorizers: plan.authorizers
    })
    if (!ok) {
      this.fail(built.message || "The rotation could not be built.")
      return "replan"
    }

    // And the BYTES carry the reviewed set and queue, or nothing is signed.
    const builtSet = (built.new_signers || []).filter((k) => k && !/^1{32}$/.test(k))
    const queue = built.signer_queue || []
    if (builtSet.join(",") !== plan.proposed.join(",")) {
      await this.cancel(built)
      this.fail("The built signer set differs from the set you reviewed. Nothing was signed; plan again.")
      return "failed"
    }
    if (queue.join(",") !== plan.phantom_queue.join(",")) {
      await this.cancel(built)
      this.fail("The server's signing queue differs from the plan you reviewed. Nothing was signed; plan again.")
      return "failed"
    }

    ;(built.server_signed || []).forEach((key) => this.paint(key, "signed"))
    queue.forEach((key) => this.paint(key, "pending"))
    if (this.connected) this.paint(this.connected, "connected")

    // Declare the accounts this ceremony moves through, so the wallet-changed
    // card does not rise over a half-collected rotation (solana_stores.js,
    // window.tmWalletSwitches; no Alpine reference here).
    const switches = window.tmWalletSwitches
    let signed
    try {
      if (window.confirmSolanaNetworkIntent) await window.confirmSolanaNetworkIntent({ action: "Rotate vault signers" })
      if (switches) switches.expectSwitchesTo(queue)
      signed = await window.cosignSignatures.collect(provider, built.serialized_tx, queue, {
        onPrompt: (key, i, total) => {
          this.paint(key, "signing")
          this.say(`Approve in Phantom as ${short(key)}${total > 1 ? ` (${i + 1} of ${total})` : ""}…`)
        },
        onWaiting: (key) => this.say(`Open Phantom and switch to ${short(key)}, then approve.`),
        onSigned: (key) => this.paint(key, "signed"),
        onFailed: (key) => this.paint(key, "failed"),
        // A nonce-anchored wire does not expire, so the operator is not cut
        // off at the usual three minutes while switching accounts.
        switchTimeoutMs: built.nonce_anchored ? 25 * 60 * 1000 : undefined
      })
    } catch (err) {
      await this.cancel(built)
      const msg = err && err.message ? err.message : String(err)
      const declined = /user rejected|user declined/i.test(msg) || (err && err.code === 4001)
      this.fail(declined ? "You declined in Phantom. Nothing was sent; the draft is kept." : msg)
      this.ctaTarget.disabled = false
      return "failed"
    } finally {
      if (switches) switches.clearExpectedSwitches()
    }

    this.say("Broadcasting from the server…")
    const { ok: landed, body: result } = await this.post(built.broadcast_url, {
      signed_tx: signed,
      signer_queue: queue,
      cosigner_address: queue[0],
      extra_cosigners: queue.slice(1)
    })
    if (!landed) {
      this.fail(result.error || result.message || "The server could not broadcast the rotation.")
      return "failed"
    }
    this.renderReadback(result, plan)
    return "landed"
  }

  async cancel(built) {
    if (!built || !built.cancel_url) return
    await this.post(built.cancel_url, {})
  }

  renderReadback(result, plan) {
    const expected = result.expected || plan.proposed
    const actual = result.signers || []
    const slots = Math.max(plan.max_slots, actual.length)
    const rows = []
    let mismatch = null
    for (let i = 0; i < slots; i++) {
      const want = expected[i] || null
      const got = actual[i] || null
      const same = want === got
      if (!same && !mismatch) mismatch = { slot: i + 1, want, got }
      const tr = document.createElement("tr")
      tr.dataset.readbackRow = String(i + 1)
      tr.dataset.match = String(same)
      if (!same) tr.className = "bg-danger/10 text-danger-ink font-bold"
      ;[String(i + 1), want ? short(want) : "empty", got ? short(got) : "empty", same ? "yes" : "NO"]
        .forEach((text) => {
          const td = document.createElement("td")
          td.className = "py-1 pr-2 font-mono"
          td.textContent = text
          tr.appendChild(td)
        })
      rows.push(tr)
    }
    this.readbackRowsTarget.replaceChildren(...rows)
    if (actual.length === 0) {
      this.readbackTitleTarget.textContent = "Landed, but the set could not be read back. Reload this page before acting again."
      this.readbackTitleTarget.className = "text-sm font-bold mb-1 text-warning-ink"
    } else if (mismatch) {
      this.readbackTitleTarget.textContent =
        `One slot differs from the plan: slot ${mismatch.slot} holds ${mismatch.got || "nothing"}, ` +
        `expected ${mismatch.want || "nothing"}. Stop and read this page before acting again.`
      this.readbackTitleTarget.className = "text-sm font-bold mb-1 text-danger-ink"
    } else {
      this.readbackTitleTarget.textContent = "Landed. The chain now holds:"
      this.readbackTitleTarget.className = "text-sm font-bold mb-1 text-success-ink"
    }
    if (result.tx_signature) {
      const cluster = document.body.dataset.solanaCluster
      const suffix = cluster && cluster !== "mainnet-beta" ? `?cluster=${cluster}` : ""
      this.explorerTarget.href = `https://explorer.solana.com/tx/${result.tx_signature}${suffix}`
      this.explorerTarget.classList.remove("hidden")
    }
    this.hide(this.reviewTarget)
    this.say("")
    this.hide(this.statusTarget)
    this.show(this.readbackTarget)
  }

  // ── plumbing ─────────────────────────────────────────────────────────────

  paint(key, state) {
    const row = this.signersTarget.querySelector(`[data-signer-row="${key}"] [data-signer-state]`)
    if (row) row.dataset.state = state
  }

  say(text) {
    if (text) this.show(this.statusTarget, text)
    else this.hide(this.statusTarget)
  }

  fail(text) {
    this.show(this.refusalTarget, text)
    this.hide(this.statusTarget)
  }

  async post(url, body) {
    const token = document.querySelector('meta[name="csrf-token"]')
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": token ? token.content : ""
        },
        body: JSON.stringify(body)
      })
      const json = await resp.json().catch(() => ({}))
      return { ok: resp.ok && json.ok !== false, body: json }
    } catch (e) {
      return { ok: false, body: { message: "The server could not be reached." } }
    }
  }

  split(value) {
    return String(value || "").split(",").map((v) => v.trim()).filter(Boolean)
  }

  // Both spellings: the error regions ship with the `hidden` ATTRIBUTE (the
  // live-region guard requires it), the rest with the class.
  show(el, text) {
    if (text !== undefined) el.textContent = text
    el.hidden = false
    el.classList.remove("hidden")
  }

  hide(el) {
    el.hidden = true
    el.classList.add("hidden")
  }
}
