import { Controller } from "@hotwired/stimulus"
import {
  decodeContest, fmtUsd, ordinal, poolCovers, solvencyLabel, solvencyTone, statusText, statusTone, totals
} from "turf/proof_of_reserves"

// /proof-of-reserves: reads each contest's account and prize-pool balance
// straight from the chain, in the browser, and judges the vault's solvency.
// It reads only; it signs and sends nothing.
//
// Each contest is a row target carrying data-contest-pda and
// data-prize-pool-pda; its parts are marked data-field. The server renders the
// loading state (Refresh disabled, every row "Loading…"), so connect starts a
// refresh over markup that already says one is running. An element whose
// colour follows a state carries each state's classes as data-<state>-class.
export default class extends Controller {
  static targets = [
    "card", "label", "refresh", "idle", "busy", "reserves", "obligations", "fetched", "fetchedAt",
    "bannerError", "row", "payout"
  ]
  static values = { rpcUrl: String }

  connect() {
    this.generation = (this.generation || 0) + 1
    this.rows = this.rowTargets.map((element) => ({
      element,
      contestPda: element.dataset.contestPda,
      prizePoolPda: element.dataset.prizePoolPda,
      onchain: null,
      prizePoolUsd: null,
      prizePoolLamports: 0n,
      error: null,
      loading: true
    }))
    this.banner = { loading: true, error: null, reservesUsd: null, obligationsUsd: null, refreshing: true, fetchedAt: null }
    this.refresh()
  }

  disconnect() {
    this.generation += 1
  }

  async refresh() {
    const generation = this.generation
    const live = () => generation === this.generation
    Object.assign(this.banner, { refreshing: true, loading: true, error: null })
    this.renderBanner()

    const connection = new window.solanaWeb3.Connection(this.rpcUrlValue, "confirmed")
    await Promise.all(this.rows.map(async (row) => {
      Object.assign(row, { loading: true, error: null })
      if (live()) this.renderRow(row)
      try {
        const info = await connection.getAccountInfo(new window.solanaWeb3.PublicKey(row.contestPda), "confirmed")
        row.onchain = info ? decodeContest(info.data) : null
        if (!row.onchain) { row.error = "Account not found"; return }
        try {
          const balance = await connection.getTokenAccountBalance(new window.solanaWeb3.PublicKey(row.prizePoolPda), "confirmed")
          row.prizePoolUsd = Number(balance.value.uiAmount || 0)
          row.prizePoolLamports = BigInt(balance.value.amount)
        } catch {
          // A pool not yet funded, or settled and swept, reads 0 rather than failing the row.
          row.prizePoolUsd = 0
          row.prizePoolLamports = 0n
        }
      } catch (error) {
        row.error = error.message || String(error)
      } finally {
        row.loading = false
        if (live()) this.renderRow(row)
      }
    }))
    if (!live()) return

    const sums = totals(this.rows)
    Object.assign(this.banner, {
      error: sums.bannerError,
      reservesUsd: sums.reservesUsd,
      obligationsUsd: sums.obligationsUsd,
      fetchedAt: new Date(),
      loading: false,
      refreshing: false
    })
    this.renderBanner()
  }

  renderBanner() {
    const banner = this.banner
    const label = solvencyLabel(banner)
    const tone = solvencyTone(label)
    this.tone(this.cardTarget, tone, [ "ok", "warn", "muted" ])
    this.tone(this.labelTarget, tone, [ "ok", "warn", "muted" ])
    this.labelTarget.textContent = label
    this.refreshTarget.disabled = banner.refreshing
    this.idleTarget.hidden = banner.refreshing
    this.busyTarget.hidden = !banner.refreshing
    this.reservesTarget.textContent = fmtUsd(banner.reservesUsd)
    this.obligationsTarget.textContent = fmtUsd(banner.obligationsUsd)
    this.fetchedTarget.hidden = !banner.fetchedAt
    this.fetchedAtTarget.textContent = banner.fetchedAt ? banner.fetchedAt.toLocaleTimeString() : ""
    this.bannerErrorTarget.hidden = !banner.error
    this.bannerErrorTarget.textContent = banner.error || ""
  }

  renderRow(row) {
    const field = (name) => row.element.querySelector(`[data-field="${name}"]`)
    const { onchain } = row

    const pill = field("status")
    this.tone(pill, statusTone(row), [ "ok", "warn", "muted" ])
    pill.textContent = statusText(row)
    field("season").hidden = !onchain
    field("seasonId").textContent = onchain ? onchain.seasonId : ""
    field("loading").hidden = !row.loading
    field("error").hidden = !row.error
    field("error").textContent = row.error || ""

    const decoded = field("decoded")
    decoded.hidden = !(onchain && !row.error)
    if (decoded.hidden) return

    const covers = poolCovers(row)
    const note = field("poolNote")
    this.tone(note, covers === false ? "short" : "covered", [ "covered", "short" ])
    note.textContent = covers === false ? "Short of guaranteed prize" : "Funds the guaranteed prize"
    field("prizePool").textContent = fmtUsd(row.prizePoolUsd)
    field("prizes").textContent = fmtUsd(onchain.prizesUsd)
    field("currentEntries").textContent = onchain.currentEntries
    field("maxEntries").textContent = onchain.maxEntries
    field("entryFee").textContent = fmtUsd(onchain.entryFeeUsd)

    field("payouts").hidden = onchain.payoutAmountsUsd.length === 0
    field("payoutList").replaceChildren(...onchain.payoutAmountsUsd.map((amount, index) => {
      const chip = this.payoutTarget.content.firstElementChild.cloneNode(true)
      chip.querySelector('[data-field="place"]').textContent = ordinal(index + 1)
      chip.querySelector('[data-field="amount"]').textContent = fmtUsd(amount)
      return chip
    }))
  }

  // Puts exactly one state's classes, from its data-<state>-class, on the element.
  tone(element, tone, states) {
    const classes = (state) => element.dataset[`${state}Class`].split(" ")
    states.forEach((state) => element.classList.remove(...classes(state)))
    element.classList.add(...classes(tone))
  }
}
