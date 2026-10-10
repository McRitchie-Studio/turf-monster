import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { tipState, COPIED_MS } = await loadTurfModule("swatch_copy")

test("a resting swatch hides its tip", () => {
  assert.deepEqual(tipState({ hex: "#00338D", hovered: false, copied: null }), { shown: false, text: "#00338D" })
})

test("a hovered swatch shows its hex", () => {
  assert.deepEqual(tipState({ hex: "#00338D", hovered: true, copied: null }), { shown: true, text: "#00338D" })
})

test("the swatch just copied says so, hovered or not", () => {
  assert.deepEqual(tipState({ hex: "#00338D", hovered: false, copied: "#00338D" }), { shown: true, text: "Copied!" })
  assert.deepEqual(tipState({ hex: "#00338D", hovered: true, copied: "#00338D" }), { shown: true, text: "Copied!" })
})

test("copying another swatch leaves this one at rest", () => {
  assert.deepEqual(tipState({ hex: "#00338D", hovered: false, copied: "#C60C30" }), { shown: false, text: "#00338D" })
})

test("Copied! holds for 1.1 seconds", () => {
  assert.equal(COPIED_MS, 1100)
})
