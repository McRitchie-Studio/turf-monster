import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const scoring = await loadTurfModule("scoring")
const game = {
  slug: "usa-mex", homeScore: null, awayScore: null, status: "scheduled",
  homeSlug: "usa", awaySlug: "mex", goals: []
}

test("the scoreline shows a dash until a side has a score", () => {
  assert.equal(scoring.scoreLine(game), "– – –")
  assert.equal(scoring.scoreLine({ ...game, homeScore: 2, awayScore: 0 }), "2 – 0")
})

test("the status reads Scheduled, LIVE, then FINAL", () => {
  assert.equal(scoring.statusLabel(game), "Scheduled")
  assert.equal(scoring.statusLabel({ ...game, status: "in_progress" }), "LIVE")
  assert.equal(scoring.statusLabel({ ...game, status: "completed" }), "FINAL")
})

test("only a completed game is done", () => {
  assert.equal(scoring.done(game), false)
  assert.equal(scoring.done({ ...game, status: "completed" }), true)
  assert.equal(scoring.completeLabel(game), "Mark Final")
  assert.equal(scoring.completeLabel({ ...game, status: "completed" }), "Final ✓")
})

test("the minute is a number, or empty when the field is", () => {
  assert.equal(scoring.minuteValue("45"), 45)
  assert.equal(scoring.minuteValue("90.5"), 90.5)
  assert.equal(scoring.minuteValue(""), "")
})

test("a goal posts the scoring side's team and the minute", () => {
  assert.deepEqual(scoring.addGoalRequest(game, "home", 12), {
    url: "/admin/games/usa-mex/goals", method: "POST", body: { team_slug: "usa", minute: 12 }
  })
  assert.deepEqual(scoring.addGoalRequest(game, "away", "").body, { team_slug: "mex", minute: "" })
})

test("removing a goal and marking final send no body", () => {
  assert.deepEqual(scoring.removeGoalRequest(game, 7), { url: "/admin/games/usa-mex/goals/7", method: "DELETE", body: null })
  assert.deepEqual(scoring.completeRequest(game), { url: "/admin/games/usa-mex/complete", method: "POST", body: null })
})

test("a success takes the server's score, status and goals, and keeps the rest", () => {
  const goals = [ { id: 7, teamSlug: "usa", teamEmoji: "🇺🇸", minute: 12 } ]
  const next = scoring.applyResponse(game, {
    success: true, game: { slug: "renamed", homeScore: 1, awayScore: 0, status: "in_progress", goals }
  })
  assert.deepEqual(next, { ...game, homeScore: 1, awayScore: 0, status: "in_progress", goals })
})

test("a failure throws the server's error, or a default", () => {
  assert.throws(() => scoring.applyResponse(game, { success: false, error: "Goal not found" }), /Goal not found/)
  assert.throws(() => scoring.applyResponse(game, { success: false }), /Request failed/)
})

test("the toolbar shows a card that matches the query and is not hidden as finished", () => {
  const card = { search: "united states mexico usa mex", query: "", hideDone: false, done: false }
  assert.equal(scoring.cardVisible(card), true)
  assert.equal(scoring.cardVisible({ ...card, query: "MEX" }), true)
  assert.equal(scoring.cardVisible({ ...card, query: "brazil" }), false)
  assert.equal(scoring.cardVisible({ ...card, done: true }), true)
  assert.equal(scoring.cardVisible({ ...card, done: true, hideDone: true }), false)
  assert.equal(scoring.cardVisible({ ...card, hideDone: true }), true)
})
