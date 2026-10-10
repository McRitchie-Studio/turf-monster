import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { toggled } = await loadTurfModule("accordion")

test("a press opens a closed section", () => {
  assert.equal(toggled(null, "picks"), "picks")
})

test("a press on the open section closes it", () => {
  assert.equal(toggled("picks", "picks"), null)
})

test("a press on another section opens that one alone", () => {
  assert.equal(toggled("picks", "scoring"), "scoring")
})
