import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { sendBlocked } = await loadTurfModule("send_gate")
const after = { count: 12, needsEarly: false, early: false }
const before = { count: 12, needsEarly: true, early: false }

test("nobody to send to blocks the send whatever is typed", () => {
  assert.equal(sendBlocked({ count: 0, typed: "0", needsEarly: false, early: true }), true)
})

test("only the exact recipient count unblocks it", () => {
  assert.equal(sendBlocked({ ...after, typed: "" }), true)
  assert.equal(sendBlocked({ ...after, typed: "13" }), true)
  assert.equal(sendBlocked({ ...after, typed: "012" }), true)
  assert.equal(sendBlocked({ ...after, typed: "12" }), false)
  assert.equal(sendBlocked({ ...after, typed: " 12 " }), false)
})

test("before the drop it also needs Send early", () => {
  assert.equal(sendBlocked({ ...before, typed: "12" }), true)
  assert.equal(sendBlocked({ ...before, typed: "12", early: true }), false)
  assert.equal(sendBlocked({ ...before, typed: "11", early: true }), true)
})
