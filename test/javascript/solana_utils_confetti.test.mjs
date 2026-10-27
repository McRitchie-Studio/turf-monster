// [unit] solana_utils.js's badge celebration fires through studio-engine's
// studio/studio_confetti module (0.115.1), imported by its importmap name, not
// through the deprecated window.confetti read in this file. It also proves the
// node:test lane resolves an importmap module that imports another by name
// (test/javascript/support/register.mjs).
import { test } from "node:test"
import assert from "node:assert/strict"

const bursts = []
globalThis.window = {
  innerWidth: 1000,
  innerHeight: 800,
  addEventListener() {},
  dispatchEvent() { return true },
  sessionStorage: { getItem() { return null }, setItem() {}, removeItem() {} },
  // What the vendored canvas-confetti defines; the module reads it per call.
  confetti(options) { bursts.push(options); return null }
}
globalThis.document = {
  documentElement: {},
  addEventListener() {},
  querySelector(selector) {
    if (selector !== "[data-free-entry-badge]") return null
    return { getBoundingClientRect: () => ({ left: 900, top: 20, width: 20, height: 20 }) }
  },
  querySelectorAll() { return [] }
}
globalThis.getComputedStyle = () => ({ getPropertyValue: (name) => (name === "--z-alert" ? "250" : "") })

const utils = await import("solana_utils")
const studioConfetti = await import("studio/studio_confetti")

test("fireConfettiFromBadge bursts from the badge through the module, at the --z-alert tier", async () => {
  bursts.length = 0
  utils.fireConfettiFromBadge()
  await new Promise((resolve) => setTimeout(resolve, 200))

  assert.equal(bursts.length, 2, "a burst and its follow-up shell")
  assert.deepEqual(bursts[0].origin, { x: 0.91, y: 0.0375 })
  assert.equal(bursts[0].zIndex, 250)
})

test("the module's confetti() is the one solana_utils calls: with the library absent it is a no-op", async () => {
  const library = window.confetti
  delete window.confetti
  try {
    assert.equal(studioConfetti.confetti({}), null)
    assert.doesNotThrow(() => utils.fireConfettiFromBadge())
    await new Promise((resolve) => setTimeout(resolve, 200))
  } finally {
    window.confetti = library
  }
})
