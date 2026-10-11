import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { canScrollRight, MASK } = await loadTurfModule("contest_rail")

test("a rail wider than its viewport has more to the right", () => {
  assert.equal(canScrollRight({ scrollWidth: 2000, clientWidth: 1000, scrollLeft: 0 }), true)
})

test("a rail scrolled to its end, or one that fits, has nothing more", () => {
  assert.equal(canScrollRight({ scrollWidth: 2000, clientWidth: 1000, scrollLeft: 1000 }), false)
  assert.equal(canScrollRight({ scrollWidth: 800, clientWidth: 1000, scrollLeft: 0 }), false)
})

test("a sub-pixel remainder at the end counts as the end", () => {
  assert.equal(canScrollRight({ scrollWidth: 2000, clientWidth: 1000, scrollLeft: 999.5 }), false)
  assert.equal(canScrollRight({ scrollWidth: 2000, clientWidth: 1000, scrollLeft: 998 }), true)
})

test("the fade starts 85% of the way across", () => {
  assert.equal(MASK, "linear-gradient(to right, black 85%, transparent)")
})
