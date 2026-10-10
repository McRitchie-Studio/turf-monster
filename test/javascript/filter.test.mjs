import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { matches, visibleCount } = await loadTurfModule("filter")

test("an empty query shows every item", () => {
  assert.equal(matches("users", ""), true)
  assert.equal(visibleCount([ "users", "contests" ], ""), 2)
})

test("an item shows when its text contains the lowercased query", () => {
  assert.equal(matches("contest_entries", "entr"), true)
  assert.equal(matches("contest_entries", "ENTR"), true)
  assert.equal(matches("contest_entries", "users"), false)
})

test("the query is not trimmed and the item's text is not lowercased", () => {
  assert.equal(matches("users", "users "), false)
  assert.equal(matches("Users", "users"), false)
})

test("the visible count is what the empty state reads", () => {
  assert.equal(visibleCount([ "users", "contests", "contest_entries" ], "contest"), 2)
  assert.equal(visibleCount([ "users", "contests" ], "zzz"), 0)
})
