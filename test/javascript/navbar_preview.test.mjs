import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { previewState, SCROLLED_CLASSES, UNSCROLLED_CLASSES } = await loadTurfModule("navbar_preview")

test("the label and the frame width name the slider's value in pixels", () => {
  const state = previewState("412", false)
  assert.equal(state.label, "412px")
  assert.equal(state.width, "412px")
})

test("an unscrolled preview has --nav-p 0 and the muted button", () => {
  const state = previewState(390, false)
  assert.equal(state.navP, "0")
  assert.deepEqual(state.add, UNSCROLLED_CLASSES)
  assert.deepEqual(state.remove, SCROLLED_CLASSES)
})

test("a scrolled preview has --nav-p 1 and the primary button", () => {
  const state = previewState(390, true)
  assert.equal(state.navP, "1")
  assert.deepEqual(state.add, [ "bg-primary", "text-white" ])
  assert.deepEqual(state.remove, [ "bg-surface-alt", "text-secondary", "hover:text-heading" ])
})
