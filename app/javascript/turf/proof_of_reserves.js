// The rules behind the proof-of-reserves controller: decoding a Contest
// account, and judging the vault's solvency from what the chain returned. No
// DOM, no network.

export const STATUS_NAMES = [ "Open", "Locked", "Settled", "Cancelled" ]
export const USDC_DECIMALS = 6
// Half a USDC cent of slack on the solvency check (covers Borsh-to-float rounding).
export const SOLVENCY_FLOAT_SLACK = 0.005

export function lamportsToUsd(big) {
  return Number(big) / Math.pow(10, USDC_DECIMALS)
}

function readU64LE(view, offset) {
  const lo = BigInt(view.getUint32(offset, true))
  const hi = BigInt(view.getUint32(offset + 4, true))
  return (hi << 32n) | lo
}

// Layout after the 8-byte Anchor discriminator, from the turf-vault Contest
// struct (v0.18, config/turf_vault.idl.json):
//   contest_id [u8;32] | admin pk(32) | creator pk(32) | season_id u32
//   prize_pool u64 | entry_fee_by_currency [u64;16] | entry_fees [u64;16]
//   max_entries u32 | current_entries u32 | status u8 (ContestStatus enum)
//   payout_amounts Vec<u64> (u32 len + len*u64) | bump u8
//   lock_timestamp i64 | conclusion_timestamp i64 | _reserved [u8;16]
// USDC is currency index 0, so the entry fee reads slot [0]. entry_fees are
// collected fees, operator revenue, not a pool obligation.
export function decodeContest(data) {
  const offset = data.byteOffset || 0
  const length = data.byteLength != null ? data.byteLength : data.length
  const view = new DataView(data.buffer, offset, length)
  let o = 8 + 32 + 32 + 32
  const seasonId = view.getUint32(o, true); o += 4
  const prizePool = readU64LE(view, o); o += 8
  const entryFee0 = readU64LE(view, o); o += 8 * 16
  o += 8 * 16
  const maxEntries = view.getUint32(o, true); o += 4
  const currentEntries = view.getUint32(o, true); o += 4
  const statusByte = view.getUint8(o); o += 1
  const payoutLen = view.getUint32(o, true); o += 4
  const payoutAmounts = []
  for (let i = 0; i < payoutLen; i++) {
    payoutAmounts.push(readU64LE(view, o))
    o += 8
  }
  return {
    // The guaranteed prize, in BigInt lamports for the solvency sum: what the
    // prize-pool token account must hold.
    prizesLamports: prizePool,
    maxEntries,
    currentEntries,
    status: STATUS_NAMES[statusByte] || "Unknown",
    prizesUsd: lamportsToUsd(prizePool),
    entryFeeUsd: lamportsToUsd(entryFee0),
    payoutAmountsUsd: payoutAmounts.map(lamportsToUsd),
    seasonId
  }
}

export function fmtUsd(n) {
  if (n === null || n === undefined) return "—"
  return "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

export function ordinal(n) {
  const s = [ "th", "st", "nd", "rd" ]
  const v = n % 100
  return n + (s[(v - 20) % 10] || s[v] || s[0])
}

// A contest row's state: { onchain, prizePoolUsd, error, loading }.

export function statusTone(row) {
  if (!row.onchain) return "muted"
  if (row.onchain.status === "Open") return "ok"
  if (row.onchain.status === "Locked") return "warn"
  return "muted"
}

export function statusText(row) {
  if (row.onchain) return row.onchain.status
  if (row.loading) return "Loading…"
  return row.error ? "Error" : "—"
}

// Whether the row's on-chain prize-pool balance covers its guaranteed prize;
// null until both are known.
export function poolCovers(row) {
  if (!row.onchain || row.prizePoolUsd === null) return null
  return row.prizePoolUsd + SOLVENCY_FLOAT_SLACK >= row.onchain.prizesUsd
}

// Reserves and obligations across the open and locked contests, and the
// banner's error when no contest decoded at all (the RPC is likely down).
export function totals(rows) {
  let reservesLamports = 0n
  let obligationsLamports = 0n
  rows.forEach((row) => {
    if (!row.onchain || row.onchain.status === "Settled" || row.onchain.status === "Cancelled") return
    reservesLamports += row.prizePoolLamports || 0n
    obligationsLamports += row.onchain.prizesLamports
  })
  const decodedNone = rows.length > 0 && !rows.some((row) => row.onchain)
  return {
    reservesUsd: lamportsToUsd(reservesLamports),
    obligationsUsd: lamportsToUsd(obligationsLamports),
    bannerError: decodedNone ? "Couldn't read any contest from chain — the RPC may be unavailable." : null
  }
}

// The banner: { loading, error, reservesUsd, obligationsUsd }.
export function solvencyLabel(banner) {
  if (banner.loading) return "Checking…"
  if (banner.error) return "Error"
  if (banner.reservesUsd === null || banner.obligationsUsd === null) return "Unknown"
  return banner.reservesUsd + SOLVENCY_FLOAT_SLACK >= banner.obligationsUsd ? "Solvent" : "Undercollateralized"
}

export function solvencyTone(label) {
  if (label === "Solvent") return "ok"
  if (label === "Undercollateralized") return "warn"
  return "muted"
}
