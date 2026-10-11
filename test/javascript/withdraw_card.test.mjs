import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { openAtStart, canSubmit, toggleLabel } = await loadTurfModule("withdraw_card")

test("the card opens itself at #cash-out", () => {
  assert.equal(openAtStart({ hash: "#cash-out", frozen: false }), true)
})

test("it stays closed at any other hash, or when the account is frozen", () => {
  assert.equal(openAtStart({ hash: "", frozen: false }), false)
  assert.equal(openAtStart({ hash: "#history", frozen: false }), false)
  assert.equal(openAtStart({ hash: "#cash-out", frozen: true }), false)
})

test("the submit waits for an amount and a destination", () => {
  assert.equal(canSubmit("", ""), false)
  assert.equal(canSubmit("25", ""), false)
  assert.equal(canSubmit("", "PayPal @fan"), false)
  assert.equal(canSubmit("25", "PayPal @fan"), true)
})

test("an amount typed as 0 is still an amount: the server refuses it", () => {
  assert.equal(canSubmit("0", "PayPal @fan"), true)
})

test("the toggle says Withdraw closed and Cancel open", () => {
  assert.equal(toggleLabel(false), "Withdraw")
  assert.equal(toggleLabel(true), "Cancel")
})
