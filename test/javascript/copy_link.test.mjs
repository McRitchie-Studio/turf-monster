import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { COPIED_MS, copyLook } = await loadTurfModule("copy_link")

test("the button says Copied for a second and a half", () => {
  assert.equal(COPIED_MS, 1500)
})

test("copied, the button turns secondary; idle, primary", () => {
  assert.deepEqual(copyLook(true), { add: "btn-secondary", remove: "btn-primary" })
  assert.deepEqual(copyLook(false), { add: "btn-primary", remove: "btn-secondary" })
})
