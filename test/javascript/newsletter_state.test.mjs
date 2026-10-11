import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { subscribedFrom } = await loadTurfModule("newsletter_state")

test("the event's detail says whether the player is subscribed", () => {
  assert.equal(subscribedFrom({ subscribed: true }), true)
  assert.equal(subscribedFrom({ subscribed: false }), false)
})

test("a detail without the flag, or none at all, reads unsubscribed", () => {
  assert.equal(subscribedFrom({}), false)
  assert.equal(subscribedFrom(null), false)
  assert.equal(subscribedFrom(undefined), false)
})
