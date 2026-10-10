import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { splitTarget, request } = await loadTurfModule("dev_score_tools")
const target = "ari-gb-week-6|gb"

test("the picker's value splits into its game and team", () => {
  assert.deepEqual(splitTarget(target), { game_slug: "ari-gb-week-6", team_slug: "gb" })
})

test("a score posts the game, the team and the scoring type", () => {
  assert.deepEqual(request("record", target, "touchdown"), {
    path: "/dev/live_scores/record",
    body: { game_slug: "ari-gb-week-6", team_slug: "gb", scoring_type: "touchdown" }
  })
})

test("a play posts the game, the team and the kind", () => {
  assert.deepEqual(request("recordPlay", target, "timeout"), {
    path: "/dev/live_scores/record_play",
    body: { game_slug: "ari-gb-week-6", team_slug: "gb", kind: "timeout" }
  })
})

test("conclude and clear post the game alone", () => {
  assert.deepEqual(request("conclude", target), { path: "/dev/live_scores/conclude_game", body: { game_slug: "ari-gb-week-6" } })
  assert.deepEqual(request("clear", target), { path: "/dev/live_scores/clear_game", body: { game_slug: "ari-gb-week-6" } })
})

test("an unknown tool is refused", () => {
  assert.throws(() => request("delete", target), /unknown dev score tool/)
})
