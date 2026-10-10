import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const por = await loadTurfModule("proof_of_reserves")

// A Contest account as the chain returns it: discriminator, three keys and the
// contest id, then the fields decodeContest reads, then the tail it skips.
function contestBytes({ seasonId, prizePool, entryFee, maxEntries, currentEntries, status, payouts }) {
  const size = 8 + 32 * 3 + 4 + 8 + 8 * 16 + 8 * 16 + 4 + 4 + 1 + 4 + 8 * payouts.length + 1 + 8 + 8 + 16
  const bytes = new Uint8Array(size + 3)
  const view = new DataView(bytes.buffer, 3, size)
  let o = 8 + 32 * 3
  view.setUint32(o, seasonId, true); o += 4
  view.setBigUint64(o, BigInt(prizePool), true); o += 8
  view.setBigUint64(o, BigInt(entryFee), true); o += 8 * 16
  view.setBigUint64(o, 999_000_000n, true); o += 8 * 16
  view.setUint32(o, maxEntries, true); o += 4
  view.setUint32(o, currentEntries, true); o += 4
  view.setUint8(o, status); o += 1
  view.setUint32(o, payouts.length, true); o += 4
  payouts.forEach((amount) => { view.setBigUint64(o, BigInt(amount), true); o += 8 })
  return bytes.subarray(3)
}

test("a Contest account decodes, reading from the view's own offset", () => {
  const decoded = por.decodeContest(contestBytes({
    seasonId: 7, prizePool: 150_000_000, entryFee: 19_000_000, maxEntries: 30, currentEntries: 12, status: 1,
    payouts: [ 100_000_000, 50_000_000 ]
  }))
  assert.deepEqual(decoded, {
    prizesLamports: 150_000_000n,
    maxEntries: 30,
    currentEntries: 12,
    status: "Locked",
    prizesUsd: 150,
    entryFeeUsd: 19,
    payoutAmountsUsd: [ 100, 50 ],
    seasonId: 7
  })
})

test("an unknown status byte reads Unknown", () => {
  const decoded = por.decodeContest(contestBytes({
    seasonId: 1, prizePool: 0, entryFee: 0, maxEntries: 3, currentEntries: 0, status: 9, payouts: []
  }))
  assert.equal(decoded.status, "Unknown")
  assert.deepEqual(decoded.payoutAmountsUsd, [])
})

test("dollars read to the cent, and an unknown figure reads as a dash", () => {
  assert.equal(por.fmtUsd(1234.5), "$1,234.50")
  assert.equal(por.fmtUsd(0), "$0.00")
  assert.equal(por.fmtUsd(null), "—")
  assert.equal(por.fmtUsd(undefined), "—")
})

test("ordinals", () => {
  assert.deepEqual([ 1, 2, 3, 4, 11, 12, 13, 21, 22, 101 ].map(por.ordinal),
    [ "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st" ])
})

test("a row's status pill reads its on-chain status, else its loading or error state", () => {
  const open = { onchain: { status: "Open" } }
  assert.equal(por.statusText(open), "Open")
  assert.equal(por.statusTone(open), "ok")
  assert.equal(por.statusTone({ onchain: { status: "Locked" } }), "warn")
  assert.equal(por.statusTone({ onchain: { status: "Settled" } }), "muted")
  assert.equal(por.statusText({ onchain: null, loading: true }), "Loading…")
  assert.equal(por.statusText({ onchain: null, loading: false, error: "Account not found" }), "Error")
  assert.equal(por.statusText({ onchain: null, loading: false, error: null }), "—")
  assert.equal(por.statusTone({ onchain: null }), "muted")
})

test("a pool covers its prize within half a cent, and is unknown until both are read", () => {
  assert.equal(por.poolCovers({ onchain: { prizesUsd: 100 }, prizePoolUsd: 99.996 }), true)
  assert.equal(por.poolCovers({ onchain: { prizesUsd: 100 }, prizePoolUsd: 99.99 }), false)
  assert.equal(por.poolCovers({ onchain: null, prizePoolUsd: 100 }), null)
  assert.equal(por.poolCovers({ onchain: { prizesUsd: 100 }, prizePoolUsd: null }), null)
})

test("totals count open and locked contests only", () => {
  const rows = [
    { onchain: { status: "Open", prizesLamports: 100_000_000n }, prizePoolLamports: 100_000_000n },
    { onchain: { status: "Locked", prizesLamports: 50_000_000n }, prizePoolLamports: 40_000_000n },
    { onchain: { status: "Settled", prizesLamports: 70_000_000n }, prizePoolLamports: 70_000_000n },
    { onchain: null, prizePoolLamports: 0n }
  ]
  assert.deepEqual(por.totals(rows), { reservesUsd: 140, obligationsUsd: 150, bannerError: null })
})

test("no decoded contest at all is a banner error; no contests at all is not", () => {
  assert.match(por.totals([ { onchain: null } ]).bannerError, /RPC may be unavailable/)
  assert.deepEqual(por.totals([]), { reservesUsd: 0, obligationsUsd: 0, bannerError: null })
})

test("the solvency label and its tone", () => {
  assert.equal(por.solvencyLabel({ loading: true }), "Checking…")
  assert.equal(por.solvencyLabel({ loading: false, error: "x" }), "Error")
  assert.equal(por.solvencyLabel({ loading: false, error: null, reservesUsd: null, obligationsUsd: 1 }), "Unknown")
  assert.equal(por.solvencyLabel({ loading: false, error: null, reservesUsd: 99.996, obligationsUsd: 100 }), "Solvent")
  assert.equal(por.solvencyLabel({ loading: false, error: null, reservesUsd: 99, obligationsUsd: 100 }), "Undercollateralized")
  assert.equal(por.solvencyTone("Solvent"), "ok")
  assert.equal(por.solvencyTone("Undercollateralized"), "warn")
  assert.equal(por.solvencyTone("Checking…"), "muted")
})
