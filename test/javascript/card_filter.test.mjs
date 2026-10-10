import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { cardVisible, countLabel } = await loadTurfModule("card_filter")

const allen = { text: "josh allen buffalo bills", values: { position: "QB" } }

test("no query and every filter at all shows the card", () => {
  assert.equal(cardVisible(allen, "", { position: "all" }), true)
  assert.equal(cardVisible(allen, "", {}), true)
})

test("the query is trimmed and matched case-blind against the card's text", () => {
  assert.equal(cardVisible(allen, "  ALLEN ", {}), true)
  assert.equal(cardVisible(allen, "Bills", {}), true)
  assert.equal(cardVisible(allen, "mahomes", {}), false)
})

test("a filter value must equal the card's value exactly", () => {
  assert.equal(cardVisible(allen, "", { position: "QB" }), true)
  assert.equal(cardVisible(allen, "", { position: "qb" }), false)
  assert.equal(cardVisible(allen, "", { position: "WR" }), false)
})

test("a card with no value for a set filter is hidden", () => {
  assert.equal(cardVisible({ text: "x", values: {} }, "", { league: "nfl" }), false)
})

test("search and filters must both pass", () => {
  assert.equal(cardVisible(allen, "allen", { position: "WR" }), false)
  assert.equal(cardVisible(allen, "cook", { position: "QB" }), false)
})

test("the count line names its noun", () => {
  assert.equal(countLabel(3, "players"), "3 players")
  assert.equal(countLabel(0, "teams"), "0 teams")
})
