import { test } from "node:test"
import assert from "node:assert/strict"
import { loadTurfModule } from "./support/load.mjs"

const { carryNonce, documentNonce } = await loadTurfModule("csp_nonce")

function script(nonce) {
  const attributes = nonce === undefined ? {} : { nonce }
  return { attributes, setAttribute(name, value) { this.attributes[name] = value } }
}

function root(scripts) {
  return { querySelectorAll: (selector) => (selector === "script" ? scripts : []) }
}

test("the document's nonce is the csp-nonce meta's content", () => {
  assert.equal(documentNonce({ content: "abc" }), "abc")
  assert.equal(documentNonce({ content: "" }), null)
  assert.equal(documentNonce(null), null)
})

test("every incoming script takes the document's nonce, whatever it carried", () => {
  const scripts = [ script("from-the-new-request"), script(""), script() ]

  assert.equal(carryNonce(root(scripts), "document-nonce"), 3)
  assert.deepEqual(scripts.map((s) => s.attributes.nonce), [ "document-nonce", "document-nonce", "document-nonce" ])
})

test("no nonce or no root changes nothing", () => {
  const scripts = [ script("kept") ]

  assert.equal(carryNonce(root(scripts), null), 0)
  assert.equal(carryNonce(null, "document-nonce"), 0)
  assert.equal(scripts[0].attributes.nonce, "kept")
})
