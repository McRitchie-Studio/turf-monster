import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { solPrice, fmtSol, fmtUsd, readouts } = await loadTurfModule("cost_calculator")

test("the typed price is a number, and an empty field prices at zero", () => {
  assert.equal(solPrice("165"), 165)
  assert.equal(solPrice("172.5"), 172.5)
  assert.equal(solPrice(""), 0)
  assert.equal(solPrice("abc"), 0)
})

test("SOL reads to three places and dollars round to whole, grouped", () => {
  assert.equal(fmtSol(1.23456), "1.235")
  assert.equal(fmtUsd(1234.5), "$1,235")
  assert.equal(fmtUsd(0), "$0")
})

test("each readout is priced from the measured lamports", () => {
  const out = readouts({ permLamports: 2_000_000_000, floatLamports: 5_000_000_000 }, 165)
  assert.deepEqual(out, {
    floatSol: "5.000",
    floatUsd: "$825",
    permSol: "~2.000 SOL",
    permUsd: "~$330",
    bufferSol: "~3.000 SOL",
    bufferUsd: "~$495",
    floatSolApprox: "~5.000 SOL"
  })
})

test("the lamport figures do not move with the price; the dollar figures do", () => {
  const cheap = readouts({ permLamports: 1e9, floatLamports: 3e9 }, 10)
  const dear = readouts({ permLamports: 1e9, floatLamports: 3e9 }, 1000)
  assert.equal(cheap.permSol, dear.permSol)
  assert.equal(cheap.permUsd, "~$10")
  assert.equal(dear.permUsd, "~$1,000")
})
