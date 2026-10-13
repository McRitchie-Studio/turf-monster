import { Controller } from "@hotwired/stimulus"

// Open Squads proposals on /admin/authorities (see _proposals.html.erb and
// Solana::SquadsProposals). Lists what each proposal does, its approvals and
// the connected seat; Approve asks Phantom once to sign and send the vote the
// server built for the connected member. The member pays the fee; no server
// key is on the transaction. After sending, the list is read back from chain.
const short = (k) => { const s = String(k || ""); return s.length > 12 ? `${s.slice(0, 4)}…${s.slice(-4)}` : s }

export default class extends Controller {
  static targets = ["status", "list", "rowTemplate", "squadsLink"]
  static values = { url: String, approveUrl: String }

  connect() {
    this.approving = new Set()
    this.onConnected = () => this.load()
    this.onPageShow = (event) => { if (event.persisted) this.load() }
    window.addEventListener("signer-console:connected", this.onConnected)
    window.addEventListener("pageshow", this.onPageShow)
    this.load()
  }

  disconnect() {
    window.removeEventListener("signer-console:connected", this.onConnected)
    window.removeEventListener("pageshow", this.onPageShow)
  }

  get connected() {
    const key = window.solana && window.solana.publicKey
    return key && key.toBase58 ? key.toBase58() : null
  }

  async load({ keepStatus = false } = {}) {
    const url = new URL(this.urlValue, window.location.origin)
    if (this.connected) url.searchParams.set("connected", this.connected)
    let body = {}
    try {
      const resp = await fetch(url, { headers: { Accept: "application/json" } })
      body = await resp.json().catch(() => ({}))
      if (!resp.ok || !body.ok) throw new Error(body.message || "unreadable")
    } catch (e) {
      this.statusTarget.textContent = `Proposals could not be read: ${e.message}`
      this.listTarget.replaceChildren()
      return []
    }
    if (body.squads_url) this.squadsLinkTarget.href = body.squads_url
    this.rows = body.proposals || []
    if (!keepStatus) this.statusTarget.textContent = this.rows.length ? "" : "No open proposals."
    this.listTarget.replaceChildren(...this.rows.map((row) => this.render(row)))
    return this.rows
  }

  render(row) {
    const node = this.rowTemplateTarget.content.firstElementChild.cloneNode(true)
    node.dataset.proposal = String(row.index)
    const set = (sel, text) => { node.querySelector(sel).textContent = text }
    const s = row.summary || {}
    set("[data-title]", `#${row.index} · ${this.title(row)}`)
    set("[data-status]", row.stale ? `${row.status}, stale` : row.status)
    set("[data-detail]", this.detail(row))

    const v = row.verification
    if (v) {
      const verdict = node.querySelector("[data-verdict]")
      verdict.textContent = v.ok
        ? `Buffer verified: matches build ${v.build_version}.`
        : `NOT VERIFIED: ${v.reason}`
      verdict.classList.remove("hidden")
      verdict.classList.add(v.ok ? "text-success-ink" : "text-danger-ink")
      verdict.dataset.verified = String(!!v.ok)
      if (v.buffer_hash) {
        const hash = node.querySelector("[data-hash]")
        hash.textContent = `buffer ${s.buffer} · sha256 ${v.buffer_hash}`
        hash.classList.remove("hidden")
      }
    }

    const names = (row.approved || []).map(short).join(", ") || "none"
    set("[data-approvals]", `${row.approved.length} of ${row.threshold} approvals (${names}); ` +
      (row.approvals_needed ? `${row.approvals_needed} more needed.` : "ready to execute in the Squads app."))
    set("[data-seat]", !row.connected ? "Connect Phantom to vote."
      : row.connected_approved ? `Your seat ${short(row.connected)} has approved.`
        : row.connected_is_voter ? `Your seat ${short(row.connected)} can approve.`
          : `${short(row.connected)} is not a voting member of this Squad.`)

    node.querySelector("[data-link]").href = row.squads_url
    const button = node.querySelector("[data-approve]")
    if (row.can_approve) {
      button.classList.remove("hidden")
      // A vote in flight keeps its button disabled through every re-render of
      // the read-back, so a second click can never raise a second prompt.
      button.disabled = this.approving.has(String(row.index))
      button.dataset.index = String(row.index)
    } else if (row.approve_blocked) {
      const blocked = node.querySelector("[data-blocked]")
      blocked.textContent = row.approve_blocked
      blocked.classList.remove("hidden")
    }
    return node
  }

  // The server lists program upgrades only; vault transfers keep the
  // squad-vault-ops link flow and config changes stay in the Squads app.
  title() {
    return "Program upgrade"
  }

  detail(row) {
    const s = row.summary || {}
    return `Installs buffer ${s.buffer} into program ${s.program}. Buffer rent refund (spill) to ${s.spill}.`
  }

  async approve(event) {
    const button = event.currentTarget
    const index = button.dataset.index
    if (this.approving.has(index)) return
    this.approving.add(index)
    button.disabled = true
    const provider = window.solana
    try {
      if (window.walletProvider && window.walletProvider.requireDesktop) window.walletProvider.requireDesktop()
      if (!provider || !provider.isPhantom) throw new Error("Phantom is required to approve.")
      await provider.connect()
      const member = this.connected
      this.statusTarget.textContent = `Building the approval for #${index}…`
      const token = document.querySelector('meta[name="csrf-token"]')
      const resp = await fetch(this.approveUrlValue.replace("INDEX", index), {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json",
                   "X-CSRF-Token": token ? token.content : "" },
        body: JSON.stringify({ member })
      })
      const built = await resp.json().catch(() => ({}))
      if (!resp.ok || !built.ok) throw new Error(built.message || "The approval could not be built.")

      const bytes = Uint8Array.from(atob(built.serialized_tx), (c) => c.charCodeAt(0))
      const tx = window.solanaWeb3.Transaction.from(bytes)
      this.statusTarget.textContent = `Approve proposal #${index} in Phantom as ${short(member)}…`
      const sent = await provider.signAndSendTransaction(tx)
      const signature = sent && (sent.signature || sent)
      this.statusTarget.textContent = `Sent (${short(String(signature))}). Reading the proposal back…`
      await this.readBack(index, member)
    } catch (err) {
      const msg = err && err.message ? err.message : String(err)
      const declined = /user rejected|user declined/i.test(msg) || (err && err.code === 4001)
      this.statusTarget.textContent = declined ? "You declined in Phantom. Nothing was sent." : msg
    } finally {
      this.approving.delete(index)
      // Re-read so the button reflects the chain, not this click.
      await this.load({ keepStatus: true })
    }
  }

  async readBack(index, member) {
    for (let i = 0; i < 10; i++) {
      const rows = await this.load({ keepStatus: true })
      const row = rows.find((r) => String(r.index) === String(index))
      if (!row || (row.approved || []).includes(member)) {
        this.statusTarget.textContent = row
          ? `Your approval on #${index} is on chain: ${row.approved.length} of ${row.threshold}.`
          : `Proposal #${index} is no longer open.`
        return
      }
      await new Promise((r) => setTimeout(r, 1500))
    }
    this.statusTarget.textContent = `The approval was sent but is not visible yet. Reload in a minute before trying again.`
  }
}
