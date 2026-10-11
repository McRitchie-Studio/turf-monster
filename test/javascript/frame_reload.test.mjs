import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { reloadPlan } = await loadTurfModule("frame_reload")

test("a frame with a src reloads it", () => {
  assert.deepEqual(reloadPlan("/account/api_keys", "/account/api_keys"), { reload: true })
})

test("a frame rendered inline is given the fallback as its src", () => {
  assert.deepEqual(reloadPlan(null, "/account/api_keys"), { src: "/account/api_keys" })
  assert.deepEqual(reloadPlan("", "/account/api_keys"), { src: "/account/api_keys" })
})
