import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { submitState, IDLE, THROTTLED_STATUS } = await loadTurfModule("submit_busy")

test("a submit that starts is busy and clears the last refusal", () => {
  assert.deepEqual(submitState("start"), { busy: true, throttled: false })
})

test("a submit that ends with a page is idle and not throttled", () => {
  assert.deepEqual(submitState("end", 200), { busy: false, throttled: false })
  assert.deepEqual(submitState("end", 422), { busy: false, throttled: false })
})

test("only a 429 is throttled", () => {
  assert.equal(THROTTLED_STATUS, 429)
  assert.deepEqual(submitState("end", 429), { busy: false, throttled: true })
})

test("a submit that ends with no response is idle", () => {
  assert.deepEqual(submitState("end", undefined), { busy: false, throttled: false })
})

test("a form starts idle", () => {
  assert.deepEqual(IDLE, { busy: false, throttled: false })
})
