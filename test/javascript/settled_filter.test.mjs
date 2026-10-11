import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { toggleLook } = await loadTurfModule("settled_filter")

test("off, the toggle is an outline button offering to show", () => {
  assert.deepEqual(toggleLook(false), { className: "btn btn-outline", text: "Show Settled", pressed: "false" })
})

test("on, the toggle is filled and offers to hide", () => {
  assert.deepEqual(toggleLook(true), { className: "btn btn-secondary", text: "Hide Settled", pressed: "true" })
})
