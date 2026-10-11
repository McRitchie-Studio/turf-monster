import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { layout, gridRow, pillLayout, RESIZE_DEBOUNCE_MS } = await loadTurfModule("leaderboard")

test("the column's width picks the layout", () => {
  assert.deepEqual(layout(0), { wide: false, mid: false, dkFull: false })
  assert.deepEqual(layout(449), { wide: false, mid: false, dkFull: false })
  assert.deepEqual(layout(450), { wide: true, mid: true, dkFull: false })
  assert.deepEqual(layout(599), { wide: true, mid: true, dkFull: false })
  assert.deepEqual(layout(600), { wide: true, mid: true, dkFull: true })
  assert.equal(RESIZE_DEBOUNCE_MS, 100)
})

test("a narrow row is the grid once the column is wide or the row is pressed open", () => {
  assert.equal(gridRow({ open: false, wide: false }), false)
  assert.equal(gridRow({ open: true, wide: false }), true)
  assert.equal(gridRow({ open: false, wide: true }), true)
})

test("in the fan each pill is 5rem, overlapped, stacked left to right", () => {
  const first = pillLayout({ index: 0, count: 6, open: false, wide: false, mid: false })
  assert.deepEqual(first.classes, { "px-2": false, "px-1": true, "justify-between": true, "justify-center": false })
  assert.deepEqual(first.style, { width: "5rem", marginLeft: null, position: "relative", zIndex: "1" })

  const third = pillLayout({ index: 2, count: 6, open: false, wide: false, mid: false })
  assert.deepEqual(third.style, { width: "5rem", marginLeft: "calc((100% - 30rem) / 5)", position: "relative", zIndex: "3" })
})

test("the last pill centres in the fan and spreads in the grid", () => {
  const fan = pillLayout({ index: 5, count: 6, open: false, wide: false, mid: false })
  assert.equal(fan.classes["justify-center"], true)
  assert.equal(fan.classes["justify-between"], false)

  const grid = pillLayout({ index: 5, count: 6, open: true, wide: false, mid: false })
  assert.equal(grid.classes["justify-center"], false)
  assert.equal(grid.classes["justify-between"], true)
})

test("in the grid a pill takes no width, margin or stacking of its own", () => {
  const opened = pillLayout({ index: 3, count: 6, open: true, wide: false, mid: false })
  assert.deepEqual(opened.style, { width: null, marginLeft: null, position: null, zIndex: null })
  assert.deepEqual(opened.classes, { "px-2": true, "px-1": false, "justify-between": true, "justify-center": false })

  const wide = pillLayout({ index: 1, count: 6, open: false, wide: true, mid: true })
  assert.deepEqual(wide.style, { width: null, marginLeft: null, position: null, zIndex: null })
  assert.equal(wide.classes["px-2"], true)
})

test("a short row of picks still fans to fill the column", () => {
  const second = pillLayout({ index: 1, count: 3, open: false, wide: false, mid: false })
  assert.equal(second.style.marginLeft, "calc((100% - 15rem) / 2)")
})
