import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { POLL_MS, pollUrl, freshList } = await loadTurfModule("leaderboard_poll")

test("the page asks every ninety seconds, naming the version it holds", () => {
  assert.equal(POLL_MS, 90000)
  assert.equal(pollUrl("wc-week-1", 1760000000), "/c/wc-week-1/leaderboard_poll?version=1760000000")
})

test("a changed answer with markup is swapped in, with its new version", () => {
  assert.deepEqual(freshList({ changed: true, html: "<div>", version: 7 }), { html: "<div>", version: 7 })
})

test("an unchanged answer, or one with no markup, swaps nothing", () => {
  assert.equal(freshList({ changed: false }), null)
  assert.equal(freshList({ changed: true, html: "" }), null)
  assert.equal(freshList(null), null)
})
