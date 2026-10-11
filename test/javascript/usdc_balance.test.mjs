import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { balanceText } = await loadTurfModule("usdc_balance")

test("a balance is shown to the cent", () => {
  assert.equal(balanceText({ balance: 12.5 }), "12.50")
  assert.equal(balanceText({ balance: "7" }), "7.00")
  assert.equal(balanceText({ balance: 0 }), "0.00")
})

test("a null balance, or no answer, keeps the figure on screen", () => {
  assert.equal(balanceText({ balance: null }), null)
  assert.equal(balanceText({ error: "Not logged in" }), null)
  assert.equal(balanceText(null), null)
})
