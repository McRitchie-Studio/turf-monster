import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { revealState } = await loadTurfModule("reveal")

test("closed: the trigger shows and the region hides", () => {
  assert.deepEqual(revealState(false), { triggerHidden: false, regionHidden: true })
})

test("open: the region shows and the trigger gives way", () => {
  assert.deepEqual(revealState(true), { triggerHidden: true, regionHidden: false })
})
