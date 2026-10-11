import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { emailChanged } = await loadTurfModule("email_change_notice")

test("the address on the account is no change", () => {
  assert.equal(emailChanged("fan@example.com", "fan@example.com"), false)
})

test("case alone is no change", () => {
  assert.equal(emailChanged("fan@example.com", "Fan@Example.COM"), false)
})

test("another address is a change, and so is clearing the field", () => {
  assert.equal(emailChanged("fan@example.com", "fan@example.org"), true)
  assert.equal(emailChanged("fan@example.com", ""), true)
})

test("a missing value reads as empty", () => {
  assert.equal(emailChanged("", null), false)
  assert.equal(emailChanged(undefined, ""), false)
})
