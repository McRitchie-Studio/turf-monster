import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { dropTemporary, isStrictDocument, stripScripts } = await loadTurfModule("signing_document")

test("only the signing-csp marker reading strict makes a strict document", () => {
  assert.equal(isStrictDocument({ content: "strict" }), true)
  assert.equal(isStrictDocument({ content: "" }), false)
  assert.equal(isStrictDocument(null), false)
})

test("every script under the root is removed", () => {
  const removed = []
  const script = (name) => ({ remove: () => removed.push(name) })
  const root = { querySelectorAll: (selector) => (selector === "script" ? [ script("a"), script("b") ] : []) }

  assert.equal(stripScripts(root), 2)
  assert.deepEqual(removed, [ "a", "b" ])
  assert.equal(stripScripts(null), 0)
})

test("every temporary element under the root is dropped", () => {
  const removed = []
  const element = (name) => ({ remove: () => removed.push(name) })
  const root = { querySelectorAll: (selector) => (selector === "[data-turbo-temporary]" ? [ element("reveal") ] : []) }

  assert.equal(dropTemporary(root), 1)
  assert.deepEqual(removed, [ "reveal" ])
  assert.equal(dropTemporary(null), 0)
})
