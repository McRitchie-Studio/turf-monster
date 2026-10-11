import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { COPIED_MS, copyButtonClasses, closesPopover } = await loadTurfModule("referral_share")

test("Copied! holds for 1.5 seconds", () => {
  assert.equal(COPIED_MS, 1500)
})

test("the button turns secondary while copied and back to primary", () => {
  assert.deepEqual(copyButtonClasses(true), { add: "btn-secondary", remove: "btn-primary" })
  assert.deepEqual(copyButtonClasses(false), { add: "btn-primary", remove: "btn-secondary" })
})

test("a click outside an open popover closes it", () => {
  assert.equal(closesPopover({ open: true, insidePopover: false, onToggle: false }), true)
})

test("a click inside the popover, on its toggle, or with it closed does not", () => {
  assert.equal(closesPopover({ open: true, insidePopover: true, onToggle: false }), false)
  assert.equal(closesPopover({ open: true, insidePopover: false, onToggle: true }), false)
  assert.equal(closesPopover({ open: false, insidePopover: false, onToggle: false }), false)
})
