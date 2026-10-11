import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { arrivalScroll, SCROLL_DELAY_MS } = await loadTurfModule("arrival_scroll")

test("?scroll=<px> scrolls to that offset", () => {
  assert.deepEqual(arrivalScroll("?scroll=640"), { top: 640 })
  assert.equal(SCROLL_DELAY_MS, 200)
})

test("a zero, negative or unreadable offset does not scroll by offset", () => {
  assert.equal(arrivalScroll("?scroll=0"), null)
  assert.equal(arrivalScroll("?scroll=-5"), null)
  assert.equal(arrivalScroll("?scroll=abc"), null)
})

test("adding or editing an entry brings the board into view", () => {
  assert.deepEqual(arrivalScroll("?add_entry=true"), { board: true })
  assert.deepEqual(arrivalScroll("?edit_entry=e-1"), { board: true })
  assert.equal(arrivalScroll("?add_entry=1"), null)
})

test("an offset wins over the board", () => {
  assert.deepEqual(arrivalScroll("?scroll=10&add_entry=true"), { top: 10 })
})

test("a plain visit stays put", () => {
  assert.equal(arrivalScroll(""), null)
})
